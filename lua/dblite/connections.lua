local M = {}

local function storage_path()
  return vim.fn.stdpath("data") .. "/dblite/connections.json"
end

local function load()
  local p = storage_path()
  local f = io.open(p, "r")
  if not f then return {} end
  local raw = f:read("*a")
  f:close()
  if raw == "" then return {} end
  local ok, data = pcall(vim.json.decode, raw)
  return (ok and type(data) == "table") and data or {}
end

local function save(conns)
  local p = storage_path()
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  local f = assert(io.open(p, "w"), "dblite: cannot write to " .. p)
  f:write(vim.json.encode(conns))
  f:close()
  vim.fn.system({ "chmod", "600", p })
end

local function gen_id()
  return string.format("%d_%04d", os.time(), math.random(1000, 9999))
end

-- Returns all saved connections as a list.
function M.list()
  return load()
end

-- Returns the connection with the given id, or nil.
function M.get(id)
  for _, c in ipairs(load()) do
    if c.id == id then return c end
  end
end

-- Returns the connection with the given name, or nil.
function M.get_by_name(name)
  for _, c in ipairs(load()) do
    if c.name == name then return c end
  end
end

-- Saves a new connection. Required fields: name, host, user, service.
-- port defaults to 1521 if omitted. Returns the saved connection (with generated id).
function M.add(conn)
  assert(type(conn.name) == "string" and conn.name ~= "", "dblite: name is required")
  assert(type(conn.host) == "string" and conn.host ~= "", "dblite: host is required")
  assert(type(conn.user) == "string" and conn.user ~= "", "dblite: user is required")
  assert(type(conn.service) == "string" and conn.service ~= "", "dblite: service is required")

  local conns = load()
  for _, c in ipairs(conns) do
    if c.name == conn.name then
      error("dblite: connection '" .. conn.name .. "' already exists")
    end
  end

  local entry = {
    id       = gen_id(),
    name     = conn.name,
    host     = conn.host,
    port     = tonumber(conn.port) or 1521,
    service  = conn.service,
    user     = conn.user,
    password = conn.password or "",
  }
  table.insert(conns, entry)
  save(conns)
  return entry
end

-- Updates fields on the connection identified by id.
-- Returns the updated connection.
function M.update(id, fields)
  local conns = load()
  for i, c in ipairs(conns) do
    if c.id == id then
      for k, v in pairs(fields) do c[k] = v end
      if c.port then c.port = tonumber(c.port) or 1521 end
      conns[i] = c
      save(conns)
      return c
    end
  end
  error("dblite: connection not found: " .. id)
end

-- Deletes the connection with the given id.
function M.delete(id)
  local conns = load()
  for i, c in ipairs(conns) do
    if c.id == id then
      table.remove(conns, i)
      save(conns)
      return
    end
  end
  error("dblite: connection not found: " .. id)
end

-- Parses an Oracle URI into connection fields.
-- Accepts: oracle://user[:password]@host[:port]/service
-- Returns fields table on success, or nil + error string on failure.
function M.parse_uri(uri)
  local rest = uri:match("^oracle://(.+)$")
  if not rest then
    return nil, "URI must start with oracle://"
  end

  local at = rest:find("@")
  if not at then
    return nil, "URI must contain @ separator (oracle://user:pass@host/service)"
  end
  local userinfo = rest:sub(1, at - 1)
  local hostinfo  = rest:sub(at + 1)

  local user, password
  local uc = userinfo:find(":")
  if uc then
    user     = userinfo:sub(1, uc - 1)
    password = userinfo:sub(uc + 1)
  else
    user     = userinfo
    password = ""
  end

  local slash = hostinfo:find("/")
  if not slash then
    return nil, "URI must contain /service after the host"
  end
  local hostport = hostinfo:sub(1, slash - 1)
  local service  = hostinfo:sub(slash + 1)

  local host, port
  local hc = hostport:find(":")
  if hc then
    host = hostport:sub(1, hc - 1)
    port = tonumber(hostport:sub(hc + 1)) or 1521
  else
    host = hostport
    port = 1521
  end

  if user    == "" then return nil, "URI is missing user" end
  if host    == "" then return nil, "URI is missing host" end
  if service == "" then return nil, "URI is missing service" end

  return { host = host, port = port, service = service, user = user, password = password }
end

-- Returns the JDBC URL for a connection table.
function M.jdbc_url(conn)
  return string.format(
    "jdbc:oracle:thin:@%s:%d/%s",
    conn.host,
    tonumber(conn.port) or 1521,
    conn.service
  )
end

return M
