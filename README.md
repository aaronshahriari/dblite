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

| Command | Description |
|---|---|
| `:DbliteAddConn [uri]` | Add a connection. Accepts `oracle://user:pass@host:port/service` or prompts field-by-field. |
| `:DbliteListConns` | List all connections. Active connection is marked `*`. |
| `:DbliteUseConn <name>` | Set the active connection for queries. |
| `:DbliteEditConn <name>` | Edit a saved connection. |
| `:DbliteDeleteConn <name>` | Delete a connection. |

All commands that accept a name support tab-completion.

## Connections Panel

`:DblitePanel` toggles a side panel listing all saved connections.

| Key | Action |
|---|---|
| `<CR>` | Activate the connection under the cursor |
| `cw` | Edit the connection under the cursor |
| `q` | Close the panel |

The active connection is marked with `✓`. Switching connections from the panel takes effect immediately for the next query.

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

### Dbout keymaps

| Key | Action |
|---|---|
| `L` | Next page |
| `H` | Previous page |
| `<C-c>` | Cancel in-flight query |
| `gi` | Inspect current page (full untruncated output) |

`<C-c>` also works from any buffer while a query is running — dblite temporarily sets it globally and restores your original mapping when the query finishes.

### Inspect

`gi` (or `:Dblite inspect`) opens the current result page in a scratch window with no column truncation. Three formats are available — tab-complete `:Dblite inspect <tab>` to pick one:

| Format | Description |
|---|---|
| `json` | Pretty-printed JSON via `jq` (falls back to raw if `jq` is not on PATH) |
| `table` | Same layout as dbout, widths fit actual content |
| `csv` | RFC-4180 escaped, ready to paste |

The scratch window opens according to `json_view` (default `"tab"`). Press `q` to close it.

### Bind Parameters

When a query contains `:param_name` tokens, a popup opens before execution. It behaves like a normal Neovim buffer — navigate freely, edit values in place.

| Action | Key / Command |
|---|---|
| Confirm and run | `:w`, `:wq`, or `<CR>` |
| Cancel | `<C-c>` or `:q` |

Values are substituted verbatim into the SQL — use SQL syntax directly:

| Type | Example |
|---|---|
| String | `'pending'` |
| Number | `42` |
| Expression | `SYSDATE` |
| Escaped quote | `'O''Brien'` |

Values are remembered for the session. Params already set skip the popup on subsequent runs. Use `<leader>db` or `:Dblite binds` to edit stored values at any time.

## API

All functionality is accessible programmatically:

```lua
local db = require('dblite')

db.execute()              -- run the current buffer as a SQL query
db.execute_at_cursor()    -- run the statement under the cursor
db.toggle_dbout()         -- show/hide the result window
db.inspect(format)        -- open current page in scratch window ('json'|'table'|'csv')
db.edit_binds()           -- open the bind parameter popup (view/edit session binds)
db.toggle_panel()         -- open/close the connections panel
db.open_panel()           -- open the panel
db.close_panel()          -- close the panel
db.is_panel_open()        -- returns true/false
```

Example keymap setup:

```lua
local db = require('dblite')
vim.keymap.set('n', '<leader>dr', db.execute,           { desc = 'dblite: run query' })
vim.keymap.set('n', '<leader>de', db.execute_at_cursor, { desc = 'dblite: run at cursor' })
vim.keymap.set('n', '<leader>dp', db.toggle_panel,      { desc = 'dblite: toggle panel' })
vim.keymap.set('n', '<leader>do', db.toggle_dbout,      { desc = 'dblite: toggle dbout' })
```

## Configuration

```lua
require('dblite').setup({
  split_dir      = 'horizontal',  -- 'vertical' | 'horizontal' | 'tab'
  split_size     = { width = 80, height = 20 },
  page_size      = 100,           -- rows per page in the result buffer
  max_rows       = 10000,         -- hard cap on rows returned
  max_col_width  = 50,            -- truncate cells wider than this; 0 = no limit
  filetype       = '',            -- filetype for the result buffer ('' = no highlighting)
  flash_timeout  = 2000,          -- ms to hold the query highlight; 0 = hold until results
  json_view      = 'tab',         -- where inspect opens: 'tab' | 'vertical' | 'horizontal' | 'float'
  inspect_format = 'json',        -- default inspect format: 'json' | 'table' | 'csv'
  panel = {
    width = 30,                   -- side panel width in columns
  },
  style = {
    dbout = {
      cursorline = false,   -- highlight the line under the cursor
      -- Status line sections. Each entry: { "item", sep = "…", hl = "HlGroup" }
      -- Available items: "pagination" | "query_time" | "connection"
      -- sep   — separator printed before this item (default "  ·  ")
      -- hl    — highlight group applied to this item's text (optional)
      sections = {
        { "pagination" },
        { "query_time", sep = "  —  " },
        { "connection", sep = "  ·  " },
      },
    },
  },
  keymaps = {
    dbout = {
      next    = 'L',              -- next page
      prev    = 'H',              -- previous page
      cancel  = '<C-c>',          -- cancel in-flight query
      inspect = 'gi',             -- open inspector for current page
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
