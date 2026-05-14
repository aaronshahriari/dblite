local function resolve_binary()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    local plugin_root = src:sub(2):gsub("/lua/dblite/config%.lua$", "")
    local candidate = plugin_root .. "/bin/dblite"
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
  end
  return "dblite"  -- fallback: binary must be on PATH
end

local M = {
  binary = resolve_binary(),
  max_rows = 10000,
  split_dir = "horizontal", -- "vertical" | "horizontal" | "tab"
  split_size = {
    width = 80,   -- columns; used when split_dir = "vertical". 0 = let nvim decide.
    height = 20,  -- rows;    used when split_dir = "horizontal". 0 = let nvim decide.
  },
  filetype = "", -- buffer filetype for results. "" disables highlighting (fastest for huge results).
  page_size = 100,    -- rows per page in the result buffer
  max_col_width = 50, -- truncate cell values wider than this; 0 = no limit
  panel = {
    width = 30,  -- columns for the side panel
  },
  flash_timeout  = 2000,  -- ms to hold the query highlight before auto-clearing (0 = wait for results)
  json_view      = "tab",  -- where to open the inspector: "tab" | "vertical" | "horizontal" | "float"
  inspect_format = "json", -- default inspect format: "json" | "table" | "csv"
  style = {
    dbout = {
      cursorline = false, -- highlight the line under the cursor in dbout
      -- Each section: { "item", sep = "separator_before", hl = "HlGroup" }
      -- Items: "pagination" | "query_time" | "connection"
      -- sep defaults to "  ·  " for non-first visible items
      sections = {
        { "pagination" },
        { "query_time", sep = "  —  " },
        { "connection", sep = "  ·  " },
      },
    },
  },
  keymaps = {
    dbout = {  -- keymaps active inside the result/output buffer
      next    = "L",       -- next page (set to "" or false to disable)
      prev    = "H",       -- prev page
      cancel  = "<C-c>",  -- kill in-flight query
      inspect = "gi",      -- open inspector for current page
    },
    editor = {
      binds = "<leader>db",  -- open bind parameter editor
    },
    panel = {    -- keymaps active inside the connections panel
      select = "<CR>", -- activate connection under cursor
      edit   = "cw",   -- edit connection under cursor
      close  = "q",    -- close panel
    },
  },
}

return M
