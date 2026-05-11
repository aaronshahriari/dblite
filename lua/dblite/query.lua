local M = {}

-- Try to detect the statement under the cursor via treesitter.
-- Returns sr, sc, er, ec (0-indexed), text — or nil on failure.
local function try_treesitter(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "sql")
  if not ok or not parser then return nil end

  local trees = parser:parse()
  if not trees or not trees[1] then return nil end

  local root  = trees[1]:root()
  local row   = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed

  -- Each direct child of root is one SQL statement
  for child in root:iter_children() do
    if child:is_named() then
      local sr, sc, er, ec = child:range()
      if sr <= row and row <= er then
        local tok, text = pcall(vim.treesitter.get_node_text, child, bufnr)
        if tok then return sr, sc, er, ec, text end
      end
    end
  end

  return nil
end

-- Fallback: find statement bounds via blank-line / semicolon separators.
local function fallback(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed
  local lines  = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local n      = #lines

  -- lines[row+1] is the text for 0-indexed row
  local function blank(row)    return (lines[row + 1] or ""):match("^%s*$") ~= nil end
  local function has_semi(row) return (lines[row + 1] or ""):match(";%s*$") ~= nil end

  -- Walk up until a blank line or a line ending with ; (both are statement boundaries)
  local start_row = cursor
  while start_row > 0 and not blank(start_row - 1) and not has_semi(start_row - 1) do
    start_row = start_row - 1
  end

  -- Walk down until the current line ends with ; or the next line is blank
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

  local sr, sc, er, ec, text = try_treesitter(bufnr)
  if sr then return sr, sc, er, ec, text end
  return fallback(bufnr)
end

return M
