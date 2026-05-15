local M = {}
local connections = require("dblite.connections")
local config      = require("dblite.config")

local _cache = {}

local ORACLE_SQL = "SELECT table_name, column_name, data_type FROM user_tab_columns ORDER BY table_name, column_id"
local MSSQL_SQL  = [[
SELECT TABLE_NAME AS table_name, COLUMN_NAME AS column_name, DATA_TYPE AS data_type
FROM INFORMATION_SCHEMA.COLUMNS
ORDER BY TABLE_NAME, ORDINAL_POSITION]]

local function expand_env(s)
  if type(s) == "string" and s:sub(1, 1) == "$" then
    return vim.fn.getenv(s:sub(2)) or s
  end
  return s
end

local function parse(rows)
  local tables, seen, cols = {}, {}, {}
  for _, row in ipairs(rows) do
    -- Oracle returns uppercase column labels (TABLE_NAME); SQL Server aliases preserve case.
    local t = row.table_name or row.TABLE_NAME
    local c = row.column_name or row.COLUMN_NAME
    local d = row.data_type or row.DATA_TYPE
    if t then
      if not seen[t] then
        seen[t] = true
        table.insert(tables, t)
        cols[t] = {}
      end
      if c then table.insert(cols[t], { name = c, type = d or "" }) end
    end
  end
  return { tables = tables, columns = cols }
end

-- Calls callback(schema) with the schema for `conn`.
-- Caches per connection id; in-flight requests share one fetch.
-- callback receives nil on fetch failure.
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
      env   = {
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

-- Drop the cached schema for a connection (e.g. after schema changes).
function M.invalidate(conn_id)
  _cache[conn_id] = nil
end

-- Fire-and-forget prefetch: warms the cache in the background.
function M.prefetch(conn)
  M.get(conn, function() end)
end

return M
