local M = {}

-- Try to detect the statement under the cursor via treesitter.
-- Uses get_node() at cursor and walks up to find the top-level statement
-- (direct child of root), which corresponds to one SQL statement.
local function try_treesitter(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local node = vim.treesitter.get_node({
    bufnr = bufnr,
    pos   = { cursor[1] - 1, cursor[2] },
  })
  if not node then return nil end

  -- Walk up until stmt is a direct child of root.
  -- Root has no parent; its children are the top-level statements.
  local stmt = node
  while stmt:parent() and stmt:parent():parent() do
    stmt = stmt:parent()
  end

  -- If stmt has no parent it IS the root — cursor on empty/whitespace-only file
  if not stmt:parent() then return nil end

  local sr, sc, er, ec = stmt:range()
  local ok, text = pcall(vim.treesitter.get_node_text, stmt, bufnr)
  if not ok or not text or text:match("^%s*$") then return nil end
  return sr, sc, er, ec, text
end

-- Fallback: find statement bounds via blank-line / semicolon separators.
local function fallback(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed
  local lines  = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local n      = #lines

  local function blank(row)    return (lines[row + 1] or ""):match("^%s*$") ~= nil end
  local function has_semi(row) return (lines[row + 1] or ""):match(";%s*$") ~= nil end

  local start_row = cursor
  while start_row > 0 and not blank(start_row - 1) and not has_semi(start_row - 1) do
    start_row = start_row - 1
  end

  local end_row = cursor
  while end_row < n - 1 and not has_semi(end_row) and not blank(end_row + 1) do
    end_row = end_row + 1
  end

  local text_lines = {}
  for i = start_row + 1, end_row + 1 do
    table.insert(text_lines, lines[i] or "")
  end
  local end_col = #(lines[end_row + 1] or "")
  return start_row, 0, end_row, end_col, table.concat(text_lines, "\n")
end

-- Returns sr, sc, er, ec (0-indexed), query_text for the statement at cursor.
-- Returns nil if the cursor is on a blank line.
function M.at_cursor(bufnr)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cur = vim.api.nvim_buf_get_lines(bufnr, cursor_line, cursor_line + 1, false)[1] or ""
  if cur:match("^%s*$") then return nil end

  local ts_ok, sr, sc, er, ec, text = pcall(try_treesitter, bufnr)
  if ts_ok and sr then return sr, sc, er, ec, text end
  return fallback(bufnr)
end

return M
