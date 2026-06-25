# dblite.nvim

A Neovim plugin for querying Oracle databases. Write SQL in any buffer, run it, and get paginated results in a split. Manages named connections with env-var support for credentials.

On install, dblite downloads a pre-built native binary from GitHub Releases. If no binary matches your platform it falls back to building from source (requires GraalVM `native-image`).

## Installation

### vim.pack (Neovim 0.11+)

Register the `PackChanged` hook **before** `vim.pack.add()` so the binary is fetched automatically on install and update:

```lua
vim.api.nvim_create_autocmd('PackChanged', {
  callback = function(ev)
    local name, kind = ev.data.spec.name, ev.data.kind
    if name == 'dblite' and (kind == 'install' or kind == 'update') then
      require('dblite.download').download_or_build()
    end
  end,
})

vim.pack.add({
  { src = 'https://github.com/aaronshahriari/dblite.nvim' },
})

require('dblite').setup()
```

If the hook wasn't in place on first install, run `:DbliteBuild` manually.

### lazy.nvim

The plugin ships a `build.lua` that lazy.nvim picks up automatically, so no `build =` key is needed. The binary is downloaded (or rebuilt) on every install and update.

```lua
{
  'aaronshahriari/dblite.nvim',
  config = function()
    require('dblite').setup()
  end,
}
```

### vim-plug

```vim
Plug 'aaronshahriari/dblite.nvim', { 'do': ':DbliteBuild' }
```

### packer.nvim

```lua
use { 'aaronshahriari/dblite.nvim', run = ':DbliteBuild' }
```

### Manual

```sh
git clone https://github.com/aaronshahriari/dblite.nvim
```

Add the directory to `runtimepath`, call `require('dblite').setup()`, and run `:DbliteBuild`.

## Connections

Connections are stored at `~/.local/share/nvim/dblite/connections.json` (chmod 600). Passwords can be stored as `$ENV_VAR` references and are expanded from the shell environment at query time.

Supported database types: **Oracle** and **SQL Server**.

| Command | Description |
|---|---|
| `:DbliteAddConn [uri]` | Add a connection. Accepts a URI or prompts field-by-field. |
| `:DbliteListConns` | List all connections. Active connection is marked `*`. |
| `:DbliteUseConn <name>` | Set the active connection for queries. |
| `:DbliteEditConn <name>` | Edit a saved connection. |
| `:DbliteDeleteConn <name>` | Delete a connection. |
| `:Dblite conn file` | Open the raw connections JSON for direct editing. |
| `:DbliteConnPicker` (or `:Dblite conn pick`) | Pick a connection with a [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) picker. |

All commands that accept a name support tab-completion.

### URI formats

```
oracle://user[:password]@host[:port]/service
sqlserver://user[:password]@host[:port]/database
```

Examples:

```
:DbliteAddConn oracle://system:oracle@localhost:1521/XEPDB1
:DbliteAddConn sqlserver://sa:secret@localhost:1433/MyDatabase
```

Port defaults to `1521` for Oracle and `1433` for SQL Server when omitted. SQL Server connections use `encrypt=true;trustServerCertificate=true` for broad compatibility with local dev and Azure SQL.

## Connections Panel

`:DblitePanel` toggles a side panel listing all saved connections.

| Key | Action |
|---|---|
| `<CR>` | Activate the connection under the cursor |
| `cw` | Edit the connection under the cursor |
| `q` | Close the panel |

The active connection is marked with `✓`. Switching connections from the panel takes effect immediately for the next query.

### Telescope picker (opt-in)

If you prefer a fuzzy picker over the side panel, set `connection_picker = "telescope"`. This requires [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) and is **off by default** — existing setups are unaffected.

```lua
require("dblite").setup({
  connection_picker = "telescope", -- "panel" (default) | "telescope"
})
```

When enabled, `:DblitePanel` (and `:Dblite toggle panel`) open the telescope picker instead of the side panel. The list on the left highlights the currently active connection with a `●`, so if you're already connected and open the picker again you can see at a glance that you're still on it — re-selecting it is a no-op that just confirms `already using '<name>'`. The right pane previews the selected connection's details with the **password masked**.

The picker is compact by default and fully sizeable:

```lua
require("dblite").setup({
  connection_picker = "telescope",
  telescope_picker = {
    preview       = true, -- show the details preview pane (default true)
    width         = 0.4,  -- picker width:  fraction of editor (<= 1) or absolute columns (> 1)
    height        = 0.4,  -- picker height: fraction of editor (<= 1) or absolute rows (> 1)
    preview_width = 0.5,  -- preview pane width as a fraction of the picker
  },
})
```

`:DbliteConnPicker` always opens the telescope picker regardless of the `connection_picker` setting, so you can bind it directly:

```lua
vim.keymap.set("n", "<leader>dc", "<cmd>DbliteConnPicker<cr>", { desc = "dblite: pick connection" })
```

## Running Queries

Open any buffer, set an active connection with `:DbliteUseConn` (or via the panel), then run a query:

| Command | Description |
|---|---|
| `:Dblite run` | Run the entire buffer as a SQL query |
| `:Dblite run at` | Run the statement under the cursor (treesitter-aware) |
| `:Dblite toggle dbout` | Show/hide the result window (query keeps running if in-flight) |
| `:Dblite inspect [json\|table\|csv]` | Open the current page in a scratch window, untruncated |

The legacy `:DbliteRun`, `:DbliteRunAt`, and `:DbliteToggleOut` commands are kept as aliases.

Trailing semicolons are stripped automatically — write SQL however feels natural.

Running a query from any tab moves the dbout split to that tab. If the result window was open in another tab it is closed there first.

### Dbout keymaps

| Key | Action |
|---|---|
| `L` | Next page |
| `H` | Previous page |
| `[` | Previous result in history |
| `]` | Next result in history |
| `K` | Hover — show the query that produced the current result |
| `d` | Toggle column type annotations (`COL [VARCHAR2]`) |
| `<leader>l` | Toggle dbout fullscreen (opens in a new tab, closes to return) |
| `<C-c>` | Cancel in-flight query |
| `gi` | Inspect current page (full untruncated output) |

`<C-c>` also works from any buffer while a query is running — dblite temporarily sets it globally and restores your original mapping when the query finishes.

### Result History

Every successful query is saved to a history ring. Navigate past results with `[` and `]` — the status line shows `◀ 2/5 ▶` when multiple entries exist. Press `K` to hover the executed SQL (with bind parameters already substituted). The float uses SQL syntax highlighting and auto-dismisses when the cursor moves.

History size is controlled by `max_history` (default `20`). Set to `0` for unlimited.

### Column Types

Press `d` in the dbout buffer to toggle column type annotations. When enabled, headers show the database type next to each column name:

```
EMPLOYEE_ID [NUMBER] | FIRST_NAME [VARCHAR2] | HIRE_DATE [DATE]
--------------------+-----------------------+------------------
```

Type annotations are highlighted with `DbliteColumnType` (links to `Comment` by default). Override it with `vim.api.nvim_set_hl()` or set a custom group via `style.dbout.column_type_hl`:

```lua
require('dblite').setup({
  show_column_types = true,  -- show types by default (toggle with d)
  style = {
    dbout = {
      column_type_hl = 'Comment',  -- highlight group for [TYPE] annotations
    },
  },
})
```

### Inspect

`gi` (or `:Dblite inspect`) opens the current result page in a scratch window with no column truncation. Three formats are available — tab-complete `:Dblite inspect <tab>` to pick one:

| Format | Description |
|---|---|
| `json` | Pretty-printed JSON via `jq` (falls back to raw if `jq` is not on PATH) |
| `table` | Same layout as dbout, widths fit actual content |
| `csv` | RFC-4180 escaped, ready to paste |

The scratch window opens according to `json_view` (default `"tab"`). Press `q` to close it.

In `json` format, cell values that are themselves serialized JSON (e.g. a `JOB_RESULT` column holding `"{\"Count\": 1095521}"`) are decoded and nested inline instead of shown as one escaped blob, so the output reads cleanly. Set `inspect_expand_json = false` to keep the raw string values.

### Bind Parameters

Bind params use a `dblite.binds.json` file in the current working directory. Create one with `:Dblite binds` or `<leader>b`.

#### File format

```json
{
  "status": "pending",
  "user_id": 42,
  "name": "O'Brien",
  "dt": "~SYSDATE"
}
```

Values are typed — dblite formats them for SQL automatically:

| JSON / prefix | SQL output | Notes |
|---|---|---|
| JSON number | verbatim | `42` → `42` |
| String | auto SQL-quoted, single-quotes escaped | `"O'Brien"` → `'O''Brien'` |
| String starting with `~` | raw SQL expression (strip `~`) | `"~SYSDATE"` → `SYSDATE` |

#### Workflow

- **Run a query** — if all params are in `dblite.binds.json`, query runs immediately. If any are missing, the file opens so you can add them; re-run after saving.
- **Edit binds** — `<leader>b` or `:Dblite binds` opens `dblite.binds.json` in a floating window. `:w` saves, `q` closes.
- **Change values** — edit `dblite.binds.json` directly; the file is re-read on every query execution.

#### Split or float

The binds window opens as a vertical split by default. Set `style = 'float'` to get a centered floating window instead:

```lua
require('dblite').setup({
  binds_split = {
    style        = 'float',  -- 'split' (default) | 'float'
    float_width  = 80,       -- float width in columns  (0 = 70% of editor width)
    float_height = 30,       -- float height in rows    (0 = 60% of editor lines)
  },
})
```

Split options (used when `style = 'split'`):

```lua
require('dblite').setup({
  binds_split = {
    split_dir = 'vertical',  -- 'vertical' | 'horizontal'
    width     = 50,          -- columns (vertical); 0 = let nvim decide
    height    = 20,          -- rows (horizontal); 0 = let nvim decide
  },
})
```

#### Status line indicator

Add `"binds_file"` to your `style.dbout.sections` to show a `binds` badge when `dblite.binds.json` exists in the cwd:

```lua
style = {
  dbout = {
    sections = {
      { "pagination" },
      { "query_time", sep = "  —  " },
      { "connection", sep = "  ·  " },
      { "binds_file", sep = "  ·  ", hl = "Comment" },
    },
  },
},
```

## Autocomplete (blink.cmp)

dblite ships a [blink.cmp](https://github.com/Saghen/blink.cmp) source that provides context-aware SQL completions. Add it to your blink config:

```lua
sources = {
  providers = {
    dblite = { module = 'dblite.blink', name = 'dblite' },
  },
  default = { 'lsp', 'path', 'snippets', 'buffer', 'dblite' },
},
```

### What gets completed

| Context | Items |
|---|---|
| General (any SQL buffer) | SQL keywords + table names |
| After `FROM` / `JOIN` / `INTO` / `UPDATE` | table names first |
| After `table.` | column names for that table |
| After `:` | existing `dblite.binds.json` keys + column names as bind param suggestions |
| Inside `dblite.binds.json` | dotted column keys like `orders.id`, `t2kb.date` |

Schema is fetched once per connection switch in the background — subsequent completions are instant from cache. No Java changes, no extra config — the source uses the active connection set by `:DbliteUseConn`.

### Bind param completions

Typing `:` in SQL suggests both existing keys from your `dblite.binds.json` and column names from the schema in dotted form (`t2kb.date`, `orders.order_id`). This lets you discover and reuse bind names without switching buffers.

Inside `dblite.binds.json`, the source suggests schema column names formatted as dotted keys that match the nested JSON structure dblite expects — e.g. `"t2kb.date"` maps to `{ "t2kb": { "date": ... } }` or a flat `{ "t2kb.date": ... }`.

## API

All functionality is accessible programmatically:

```lua
local db = require('dblite')

db.execute()              -- run the current buffer as a SQL query
db.execute_at_cursor()    -- run the statement under the cursor
db.toggle_dbout()         -- show/hide the result window
db.inspect(format)        -- open current page in scratch window ('json'|'table'|'csv')
db.toggle_binds()         -- toggle dblite.binds.json split open/closed
db.open_binds()           -- open/focus the binds split (does not close)
db.edit_binds()           -- alias for toggle_binds()
db.edit_connections_file() -- open connections JSON for direct editing
db.toggle_panel()         -- open/close the connections panel
db.open_panel()           -- open the panel
db.close_panel()          -- close the panel
db.is_panel_open()        -- returns true/false
db.get_active_conn()      -- returns the active connection object (or nil)
db.get_flat_binds()       -- returns flattened dblite.binds.json as a table
```

Example keymap setup:

```lua
local db = require('dblite')
vim.keymap.set('n', '<leader>dr', db.execute,                { desc = 'dblite: run query' })
vim.keymap.set('n', '<leader>de', db.execute_at_cursor,      { desc = 'dblite: run at cursor' })
vim.keymap.set('n', '<leader>dp', db.toggle_panel,           { desc = 'dblite: toggle panel' })
vim.keymap.set('n', '<leader>do', db.toggle_dbout,           { desc = 'dblite: toggle dbout' })
vim.keymap.set('n', '<leader>dc', db.edit_connections_file,  { desc = 'dblite: edit connections' })
```

Or bind it via setup with `keymaps.editor.connections`:

```lua
require('dblite').setup({
  keymaps = {
    editor = {
      connections = '<leader>dc',
    },
  },
})
```

## Configuration

```lua
require('dblite').setup({
  split_dir      = 'horizontal',  -- 'vertical' | 'horizontal' | 'tab'
  split_size     = { width = 80, height = 20 },
  page_size      = 100,           -- rows per page in the result buffer
  max_rows       = 10000,         -- hard cap on rows returned
  max_col_width  = 50,            -- truncate cells wider than this; 0 = no limit
  max_history    = 20,            -- past query results to keep; 0 = unlimited
  show_column_types = false,      -- show [TYPE] next to column headers by default
  filetype       = '',            -- filetype for the result buffer ('' = no highlighting)
  flash_timeout  = 2000,          -- ms to hold the query highlight; 0 = hold until results
  json_view      = 'tab',         -- where inspect opens: 'tab' | 'vertical' | 'horizontal' | 'float'
  inspect_format = 'json',        -- default inspect format: 'json' | 'table' | 'csv'
  inspect_expand_json = true,     -- json inspect: decode cell values that are themselves JSON strings so they nest cleanly
  panel = {
    width = 30,                   -- side panel width in columns
  },
  connection_picker = 'panel',    -- 'panel' (default) | 'telescope' (requires telescope.nvim)
  telescope_picker = {            -- sizing/behaviour when connection_picker = 'telescope'
    preview       = true,         -- show the connection-details preview (password masked)
    width         = 0.4,          -- fraction of editor (<= 1) or absolute columns (> 1)
    height        = 0.4,          -- fraction of editor (<= 1) or absolute rows (> 1)
    preview_width = 0.5,          -- preview pane width as a fraction of the picker
  },
  binds_split = {
    style        = 'split',    -- 'split' | 'float'
    split_dir    = 'vertical', -- 'vertical' | 'horizontal' (split only)
    width        = 40,         -- columns for vertical split. 0 = let nvim decide.
    height       = 20,         -- rows for horizontal split. 0 = let nvim decide.
    float_width  = 0,          -- float width in columns.  0 = 70% of editor width.
    float_height = 0,          -- float height in rows.    0 = 60% of editor lines.
  },
  style = {
    dbout = {
      cursorline = false,   -- highlight the line under the cursor
      -- Status line sections. Each entry: { "item", sep = "…", hl = "HlGroup" }
      -- Available items: "history" | "pagination" | "query_time" | "connection"
      -- sep   — separator printed before this item (default "  ·  ")
      -- hl    — highlight group applied to this item's text (optional)
      column_type_hl = 'DbliteColumnType',  -- highlight group for [TYPE] annotations
      sections = {
        { "history" },
        { "pagination", sep = "  " },
        { "query_time", sep = "  —  " },
        { "connection", sep = "  ·  " },
      },
    },
  },
  keymaps = {
    dbout = {
      next         = 'L',         -- next page
      prev         = 'H',         -- previous page
      cancel       = '<C-c>',     -- cancel in-flight query
      inspect      = 'gi',        -- open inspector for current page
      history_prev = '[',         -- previous query result in history
      history_next = ']',         -- next query result in history
      hover_query  = 'K',         -- hover to show the executed query
      toggle_types = 'd',         -- toggle column type annotations
    },
    editor = {
      binds      = '<leader>b',   -- toggle dblite.binds.json split
      fullscreen = '<leader>l',   -- toggle dbout fullscreen
    },
    panel = { select = '<CR>', edit = 'cw', close = 'q' },
  },
})
```

## Todo
- setup oracle bind parameters
  - allow for some keybind to open popup buffer to edit bind params for current connection
- Integrated panel
  - queries per connection
    - ctrl-* open in splits etc
  - help menu (toggle via config)
- blink autocomplete for current connection
