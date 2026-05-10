local M = {
  binary = "/home/aaronshahriari/personal/dblite/target/dblite",
  max_rows = 10000,
  split_dir = "horizontal", -- "vertical" | "horizontal" | "tab"
  split_size = {
    width = 80,   -- columns; used when split_dir = "vertical". 0 = let nvim decide.
    height = 20,  -- rows;    used when split_dir = "horizontal". 0 = let nvim decide.
  },
  filetype = "", -- buffer filetype for results. "" disables highlighting (fastest for huge results).
  page_size = 100,    -- rows per page in the result buffer
  max_col_width = 50, -- truncate cell values wider than this; 0 = no limit
  keymaps = {
    dbout = {  -- keymaps active inside the result/output buffer
      next = "L",       -- next page (set to "" or false to disable)
      prev = "H",       -- prev page
      cancel = "<C-c>", -- kill in-flight query
    },
    editor = {}, -- reserved: keymaps for the SQL editor buffer
    panel = {},  -- reserved: keymaps for a future side panel
  },
}

return M
