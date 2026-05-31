local M = {}
local connections = require("dblite.connections")
local config      = require("dblite.config")

local _cache = {}

-- Returns owner, table, column, type per row.
-- Oracle: all_tab_columns filtered to non-system schemas.
-- SQL Server: INFORMATION_SCHEMA.COLUMNS with schema as owner.
local ORACLE_SQL = [[
SELECT c.owner, c.table_name, c.column_name, c.data_type
FROM all_tab_columns c
JOIN all_users u ON u.username = c.owner
WHERE u.oracle_maintained = 'N'
AND c.table_name NOT LIKE 'BIN%'
ORDER BY c.owner, c.table_name, c.column_id]]

local MSSQL_SQL = [[
SELECT c.TABLE_SCHEMA AS owner, c.TABLE_NAME AS table_name,
       c.COLUMN_NAME AS column_name, c.DATA_TYPE AS data_type
FROM INFORMATION_SCHEMA.COLUMNS c
ORDER BY c.TABLE_SCHEMA, c.TABLE_NAME, c.ORDINAL_POSITION]]

local function expand_env(s)
  if type(s) == "string" and s:sub(1, 1) == "$" then
    return vim.fn.getenv(s:sub(2)) or s
  end
  return s
end

-- Builds:
--   owners       = ["OWNER1", ...]          unique, in appearance order
--   owner_tables = { OWNER1 = ["T1", ...] } tables per owner (no duplicates)
--   columns      = { ["OWNER.TABLE"] = [{name, type}] }
local function parse(rows)
  local owners_seen = {}
  local owners       = {}
  local owner_tables = {}
  local columns      = {}

  for _, row in ipairs(rows) do
    local o = row.owner      or row.OWNER
    local t = row.table_name or row.TABLE_NAME
    local c = row.column_name or row.COLUMN_NAME
    local d = row.data_type  or row.DATA_TYPE

    if o and t then
      if not owners_seen[o] then
        owners_seen[o] = true
        table.insert(owners, o)
        owner_tables[o] = {}
      end

      local fqn = o .. "." .. t
      if not columns[fqn] then
        columns[fqn] = {}
        table.insert(owner_tables[o], t)
      end

      if c then
        table.insert(columns[fqn], { name = c, type = d or "" })
      end
    end
  end

  return { owners = owners, owner_tables = owner_tables, columns = columns }
end

-- Calls callback(schema) — cached per connection, in-flight deduplication.
-- callback receives nil on failure.
function M.get(conn, callback)
  local id = conn.id
  local e  = _cache[id]
  if e and e.schema   then callback(e.schema); return end
  if e and e.fetching then table.insert(e.cbs, callback); return end

  _cache[id] = { fetching = true, cbs = { callback } }

  local sql = (conn.type == "sqlserver") and MSSQL_SQL or ORACLE_SQL
  vim.system(
    { config.binary },
    {
      stdin = sql,
      text  = true,
      env   = conn.auth == "kerberos"
        and { DB_URL = connections.jdbc_url(conn) }
        or  {
          DB_URL      = connections.jdbc_url(conn),
          DB_USER     = expand_env(conn.user),
          DB_PASSWORD = expand_env(conn.password or ""),
        },
    },
    function(result)
      vim.schedule(function()
        local entry = _cache[id]
        if not entry then return end
        local cbs = entry.cbs
        if result.code ~= 0 then
          _cache[id] = nil
          for _, cb in ipairs(cbs) do cb(nil) end
          return
        end
        local ok, data = pcall(vim.json.decode, result.stdout)
        if not ok or type(data) ~= "table" then
          _cache[id] = nil
          for _, cb in ipairs(cbs) do cb(nil) end
          return
        end
        local schema = parse(data.rows or {})
        _cache[id] = { schema = schema }
        for _, cb in ipairs(cbs) do cb(schema) end
      end)
    end)
end

function M.invalidate(conn_id) _cache[conn_id] = nil end
function M.prefetch(conn) M.get(conn, function() end) end

return M
