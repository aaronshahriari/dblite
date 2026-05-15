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
  Field   = 5,
  Variable = 6,
  Class   = 7,
  Keyword = 14,
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

  -- ── dblite.binds.json: suggest dotted column keys ─────────────────────
  if is_binds then
    if not conn then
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
      return
    end
    schema.get(conn, function(sch)
      local items = {}
      if sch then
        for _, tname in ipairs(sch.tables) do
          -- Dotted form: "orders.order_id" — matches flatten_binds output
          for _, col in ipairs(sch.columns[tname] or {}) do
            local key = tname:lower() .. "." .. col.name:lower()
            table.insert(items, {
              label       = key,
              kind        = KIND.Field,
              detail      = col.type,
              insertText  = key,
            })
          end
          -- Table name alone for nesting top-level keys
          table.insert(items, {
            label      = tname:lower(),
            kind       = KIND.Class,
            insertText = tname:lower(),
          })
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

    -- `:param` context — suggest existing bind keys and column names -------
    local after_colon = (ctx.trigger and ctx.trigger.character == ":")
                     or line:match(":[a-zA-Z_][a-zA-Z0-9_.]*$") ~= nil
    if after_colon then
      local items = {}
      local flat = db.get_flat_binds()
      for key, _ in pairs(flat) do
        table.insert(items, {
          label      = key,
          kind       = KIND.Variable,
          detail     = "bind",
          insertText = key,
        })
      end
      if sch then
        local seen_col = {}
        for _, tname in ipairs(sch.tables) do
          for _, col in ipairs(sch.columns[tname] or {}) do
            -- dotted form: t2kb.date
            local dotted = tname:lower() .. "." .. col.name:lower()
            if not seen_col[dotted] then
              seen_col[dotted] = true
              table.insert(items, { label = dotted, kind = KIND.Field, detail = col.type })
            end
            -- plain column name
            if not seen_col[col.name] then
              seen_col[col.name] = true
              table.insert(items, { label = col.name, kind = KIND.Field, detail = col.type })
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

    -- `table.` context — column completions for that table -----------------
    local after_dot = line:match("(%w+)%.$")
    if after_dot then
      local cols = sch.columns[after_dot:upper()] or sch.columns[after_dot]
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

    -- After FROM / JOIN / INTO / UPDATE — tables first ---------------------
    local after_kw = line:match("[Ff][Rr][Oo][Mm]%s+$")
                  or line:match("[Jj][Oo][Ii][Nn]%s+$")
                  or line:match("[Ii][Nn][Tt][Oo]%s+$")
                  or line:match("[Uu][Pp][Dd][Aa][Tt][Ee]%s+$")
    if after_kw then
      local items = {}
      for _, t in ipairs(sch.tables) do
        table.insert(items, { label = t, kind = KIND.Class })
      end
      vim.list_extend(items, kw_items)
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
      return
    end

    -- General context — keywords + tables ----------------------------------
    local items = vim.list_extend({}, kw_items)
    for _, t in ipairs(sch.tables) do
      table.insert(items, { label = t, kind = KIND.Class })
    end
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
  end)
end

return source
