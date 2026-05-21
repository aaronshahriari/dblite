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
  max_history = 20,        -- number of past query results kept in history; 0 = unlimited
  show_column_types = false, -- show [TYPE] next to column headers by default (toggle with d)
  panel = {
    width = 30,  -- columns for the side panel
  },
  binds_split = {
    style        = "split",    -- "split" | "float"
    split_dir    = "vertical", -- "vertical" | "horizontal" (split only)
    width        = 40,         -- columns for vertical split. 0 = let nvim decide.
    height       = 20,         -- rows for horizontal split. 0 = let nvim decide.
    float_width  = 0,          -- float width in columns.  0 = 70% of editor width.
    float_height = 0,          -- float height in rows.    0 = 60% of editor lines.
  },
  flash_timeout  = 2000,  -- ms to hold the query highlight before auto-clearing (0 = wait for results)
  json_view      = "tab",  -- where to open the inspector: "tab" | "vertical" | "horizontal" | "float"
  inspect_format = "json", -- default inspect format: "json" | "table" | "csv"
  style = {
    dbout = {
      cursorline = false, -- highlight the line under the cursor in dbout
      -- Each section: { "item", sep = "separator_before", hl = "HlGroup" }
      -- Items: "pagination" | "query_time" | "connection" | "binds_file"
      -- sep defaults to "  ·  " for non-first visible items
      sections = {
        { "history" },
        { "pagination", sep = "  " },
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
      inspect      = "gi",      -- open inspector for current page
      history_prev = "[",       -- previous query result in history
      history_next = "]",       -- next query result in history
      hover_query  = "K",       -- hover to show the executed query
      toggle_types = "d",       -- toggle column type annotations
    },
    editor = {
      binds      = "<leader>b",  -- open dblite.binds.json popup
      fullscreen = "<leader>l",  -- toggle dbout fullscreen
    },
    panel = {    -- keymaps active inside the connections panel
      select = "<CR>", -- activate connection under cursor
      edit   = "cw",   -- edit connection under cursor
      close  = "q",    -- close panel
    },
  },
}

return M
