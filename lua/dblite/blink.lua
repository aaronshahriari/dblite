-- blink.cmp source for dblite.nvim
-- Register in your blink.cmp config:
--
--   sources = {
--     providers = {
--       dblite = { module = 'dblite.blink', name = 'dblite' },
--     },
--     default = { 'lsp', 'path', 'snippets', 'buffer', 'dblite' },
--   }

local SQL_KEYWORDS = {
  "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "BETWEEN", "LIKE",
  "IS NULL", "IS NOT NULL", "ORDER BY", "GROUP BY", "HAVING",
  "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL OUTER JOIN", "ON", "AS",
  "DISTINCT", "UNION", "UNION ALL", "INSERT INTO", "VALUES", "UPDATE", "SET",
  "DELETE FROM", "CREATE TABLE", "DROP TABLE", "ALTER TABLE", "TRUNCATE",
  "COMMIT", "ROLLBACK", "BEGIN", "DECLARE",
  "ROWNUM", "SYSDATE", "SYSTIMESTAMP", "NVL", "NVL2", "DECODE", "DUAL",
  "CONNECT BY", "START WITH", "PRIOR", "LEVEL",
  "ISNULL", "CONVERT", "CAST", "GETDATE", "NEWID",
  "COALESCE", "NULLIF", "CASE", "WHEN", "THEN", "ELSE", "END",
  "COUNT", "SUM", "AVG", "MIN", "MAX",
}

local KIND = {
  Field    = 5,
  Variable = 6,
  Class    = 7,
  Module   = 9,   -- used for owners/schemas
  Keyword  = 14,
}

local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:get_trigger_characters()
  return { ".", " ", ":" }
end

function source:get_completions(ctx, callback)
  local db     = require("dblite")
  local schema = require("dblite.schema")
  local conn   = db.get_active_conn()
  local line   = ctx.line:sub(1, ctx.cursor[2])

  local bufname  = vim.api.nvim_buf_get_name(ctx.bufnr)
  local is_binds = bufname:match("dblite%.binds%.json$") ~= nil

  -- ── dblite.binds.json: suggest table.column dotted keys ──────────────
  if is_binds then
    if not conn then
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
      return
    end
    schema.get(conn, function(sch)
      local items = {}
      if sch then
        for _, owner in ipairs(sch.owners) do
          for _, tname in ipairs(sch.owner_tables[owner] or {}) do
            local fqn = owner .. "." .. tname
            for _, col in ipairs(sch.columns[fqn] or {}) do
              local key = tname:lower() .. "." .. col.name:lower()
              table.insert(items, {
                label      = key,
                kind       = KIND.Field,
                detail     = col.type,
                insertText = key,
              })
            end
            table.insert(items, {
              label      = tname:lower(),
              kind       = KIND.Class,
              detail     = owner,
              insertText = tname:lower(),
            })
          end
        end
      end
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
    end)
    return
  end

  -- ── SQL buffer ────────────────────────────────────────────────────────
  local kw_items = {}
  for _, kw in ipairs(SQL_KEYWORDS) do
    table.insert(kw_items, { label = kw, kind = KIND.Keyword, insertText = kw })
  end

  if not conn then
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = kw_items })
    return
  end

  schema.get(conn, function(sch)

    -- ── `:param` — existing bind keys + column suggestions ───────────────
    local after_colon = (ctx.trigger and ctx.trigger.character == ":")
                     or line:match(":[a-zA-Z_][a-zA-Z0-9_.]*$") ~= nil
    if after_colon then
      local items = {}
      local flat = db.get_flat_binds()
      for key, val in pairs(flat) do
        local detail
        if val == vim.NIL then
          detail = "null"
        elseif type(val) == "string" then
          detail = val:sub(1, 1) == "~" and val:sub(2) or ('"' .. val .. '"')
        else
          detail = tostring(val)
        end
        table.insert(items, { label = key, kind = KIND.Variable, detail = detail, insertText = key })
      end
      if sch then
        local seen_col = {}
        for _, owner in ipairs(sch.owners) do
          for _, tname in ipairs(sch.owner_tables[owner] or {}) do
            local fqn = owner .. "." .. tname
            for _, col in ipairs(sch.columns[fqn] or {}) do
              local dotted = tname:lower() .. "." .. col.name:lower()
              if not seen_col[dotted] then
                seen_col[dotted] = true
                table.insert(items, { label = dotted, kind = KIND.Field, detail = col.type })
              end
              if not seen_col[col.name] then
                seen_col[col.name] = true
                table.insert(items, { label = col.name, kind = KIND.Field, detail = col.type })
              end
            end
          end
        end
      end
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
      return
    end

    if not sch then
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = kw_items })
      return
    end

    -- ── owner.table. — column completions ────────────────────────────────
    local dot2_owner, dot2_table = line:match("([%w_]+)%.([%w_]+)%.$")
    if dot2_owner then
      local fqn  = dot2_owner:upper() .. "." .. dot2_table:upper()
      local cols = sch.columns[fqn]
      local items = {}
      if cols then
        for _, col in ipairs(cols) do
          table.insert(items, { label = col.name, kind = KIND.Field, detail = col.type })
        end
      end
      if #items == 0 then items = kw_items end
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
      return
    end

    -- ── owner. — table completions for that owner ─────────────────────────
    local after_dot = line:match("([%w_]+)%.$")
    if after_dot then
      local owner  = after_dot:upper()
      local tables = sch.owner_tables[owner]
      if tables then
        local items = {}
        for _, tname in ipairs(tables) do
          table.insert(items, { label = tname, kind = KIND.Class, detail = owner })
        end
        callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
        return
      end
      -- not a known owner — fall through to keyword/owner list
    end

    -- ── after FROM / JOIN / INTO / UPDATE — owner names first ────────────
    local after_kw = line:match("[Ff][Rr][Oo][Mm]%s+$")
                  or line:match("[Jj][Oo][Ii][Nn]%s+$")
                  or line:match("[Ii][Nn][Tt][Oo]%s+$")
                  or line:match("[Uu][Pp][Dd][Aa][Tt][Ee]%s+$")
    if after_kw then
      local items = {}
      for _, o in ipairs(sch.owners) do
        local n = sch.owner_tables[o] and #sch.owner_tables[o] or 0
        table.insert(items, { label = o, kind = KIND.Module, detail = n .. " tables" })
      end
      vim.list_extend(items, kw_items)
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
      return
    end

    -- ── general — owners + keywords ───────────────────────────────────────
    local items = vim.list_extend({}, kw_items)
    for _, o in ipairs(sch.owners) do
      local n = sch.owner_tables[o] and #sch.owner_tables[o] or 0
      table.insert(items, { label = o, kind = KIND.Module, detail = n .. " tables" })
    end
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
  end)
end

return source
