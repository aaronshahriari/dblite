# dblite.nvim

Query **Oracle** and **SQL Server** from Neovim. Write SQL in any buffer, run it, and get paginated results in a split — with named connections, typed bind parameters, result history, exports, and context-aware SQL completion.

The database work runs in a native binary (GraalVM), so there's **no JVM at runtime** — it's downloaded pre-built on install, falling back to a source build only if no binary matches your platform.

<!-- Add a screenshot or gif of the result split here — it's the single biggest thing for a Reddit post. -->

## Features

- **Run from any buffer** — the whole buffer, or just the statement under the cursor (treesitter-aware).
- **Paginated result split** with column-type annotations, query timing, and a per-session result history you can page back through.
- **Named connections** with `$ENV_VAR` password references, stored at `chmod 600`.
- **Typed bind parameters** from a `dblite.binds.json` file — numbers, quoted strings, and raw SQL expressions.
- **Export** the entire result set (not just the current page) to CSV or JSON.
- **Inspect** any page untruncated as JSON, table, or CSV.
- **SQL autocomplete** via [blink.cmp](https://github.com/Saghen/blink.cmp) — tables, columns, and bind names from the live schema.
- **Connection UI** — a built-in side panel, or an opt-in [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) picker.

## Requirements

- Neovim 0.11+
- Optional: [`jq`](https://jqlang.github.io/jq/) (prettier JSON), [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (picker), [blink.cmp](https://github.com/Saghen/blink.cmp) (completion)
- Only if building from source (no prebuilt binary for your platform): GraalVM `native-image`

## Installation

The binary is fetched automatically on install and update.

**vim.pack (Neovim 0.11+)** — register the `PackChanged` hook **before** `vim.pack.add()`:

```lua
vim.api.nvim_create_autocmd('PackChanged', {
  callback = function(ev)
    local name, kind = ev.data.spec.name, ev.data.kind
    if name == 'dblite' and (kind == 'install' or kind == 'update') then
      require('dblite.download').download_or_build()
    end
  end,
})

vim.pack.add({ { src = 'https://github.com/aaronshahriari/dblite.nvim' } })
require('dblite').setup()
```

If the hook wasn't in place on first install, run `:DbliteBuild` manually.

**lazy.nvim** — the bundled `build.lua` is picked up automatically, so no `build =` key is needed:

```lua
{ 'aaronshahriari/dblite.nvim', config = function() require('dblite').setup() end }
```

<details>
<summary>Other plugin managers</summary>

```vim
" vim-plug
Plug 'aaronshahriari/dblite.nvim', { 'do': ':DbliteBuild' }
```

```lua
-- packer.nvim
use { 'aaronshahriari/dblite.nvim', run = ':DbliteBuild' }
```

```sh
# Manual
git clone https://github.com/aaronshahriari/dblite.nvim
```

For a manual install, add the directory to `runtimepath`, call `require('dblite').setup()`, and run `:DbliteBuild`.

</details>

## Quick start

```vim
:DbliteAddConn oracle://system:oracle@localhost:1521/XEPDB1   " add a connection
:DbliteUseConn XEPDB1                                          " make it active
```

Then write SQL in any buffer and run it:

```vim
:Dblite run       " run the whole buffer
:Dblite run at    " run the statement under the cursor
```

Results open in the **dbout** split. Page with `L`/`H`, walk history with `[`/`]`, hover `K` to see the executed SQL.

## Connections

Connections live at `~/.local/share/nvim/dblite/connections.json` (`chmod 600`). Passwords can be stored as `$ENV_VAR` references and are expanded from the environment at query time.

| Command | Description |
|---|---|
| `:DbliteAddConn [uri]` | Add a connection (URI, or prompts field-by-field) |
| `:DbliteListConns` | List connections; active one marked `*` |
| `:DbliteUseConn <name>` | Set the active connection |
| `:DbliteEditConn <name>` | Edit a saved connection |
| `:DbliteDeleteConn <name>` | Delete a connection |
| `:Dblite conn file` | Open the raw connections JSON |
| `:DbliteConnPicker` | Pick a connection with a telescope picker |

Name arguments support tab-completion.

**URI formats** — port defaults to `1521` (Oracle) / `1433` (SQL Server) when omitted:

```
oracle://user[:password]@host[:port]/service
sqlserver://user[:password]@host[:port]/database
```

SQL Server connections use `encrypt=true;trustServerCertificate=true` for broad compatibility with local dev and Azure SQL.

## Running queries

| Command | Description |
|---|---|
| `:Dblite run` | Run the entire buffer |
| `:Dblite run at` | Run the statement under the cursor (treesitter-aware) |
| `:Dblite toggle dbout` | Show/hide the result window (query keeps running if in-flight) |
| `:Dblite inspect [json\|table\|csv]` | Open the current page untruncated in a scratch window |
| `:Dblite export <csv\|json> [path]` | Write the **entire** result set to a file |

Trailing semicolons are stripped automatically. The legacy `:DbliteRun`, `:DbliteRunAt`, and `:DbliteToggleOut` commands remain as aliases. Running from a different tab moves the dbout split to that tab.

**dbout keymaps:**

| Key | Action | Key | Action |
|---|---|---|---|
| `L` / `H` | Next / previous page | `[` / `]` | Previous / next result in history |
| `K` | Hover the query that produced this result | `d` | Toggle column type annotations |
| `gi` | Inspect current page (untruncated) | `<leader>l` | Toggle dbout fullscreen |
| `<C-c>` | Cancel in-flight query | | |

`<C-c>` also cancels from any buffer while a query runs — dblite sets it globally for the duration and restores your mapping afterward.

## More

<details>
<summary><b>Bind parameters</b></summary>

Bind params come from a `dblite.binds.json` file in the current working directory. Create/edit it with `:Dblite binds` or `<leader>b`; it's re-read on every query. When you run a query with missing params, the file opens so you can fill them in, then re-run.

```json
{
  "status": "pending",
  "user_id": 42,
  "name": "O'Brien",
  "dt": "~SYSDATE"
}
```

Values are typed and formatted for SQL automatically:

| JSON / prefix | SQL output |
|---|---|
| JSON number | verbatim — `42` → `42` |
| String | auto-quoted, single-quotes escaped — `"O'Brien"` → `'O''Brien'` |
| String starting with `~` | raw SQL expression — `"~SYSDATE"` → `SYSDATE` |

The binds window is a vertical split by default; set `binds_split.style = 'float'` for a centered float. Add `"binds_file"` to `style.dbout.sections` to show a `binds` badge when the file exists in the cwd.

</details>

<details>
<summary><b>Exporting results</b></summary>

`:Dblite export csv|json` (or `:DbliteExport`) writes the **full** result set — every row, not just the current page — to a file:

```
:Dblite export csv ~/exports/jobs.csv
:Dblite export json ./out/jobs.json
:DbliteExport csv                       " omit the path to be prompted (with completion)
```

`~`, env vars, and relative paths are expanded, and missing parent directories are created. CSV is RFC-4180 escaped; JSON is pretty-printed via `jq` when available (compact fallback otherwise).

</details>

<details>
<summary><b>Result history</b></summary>

Every successful query is saved to a history ring. Page past results with `[` / `]` — the status line shows `◀ 2/5 ▶` when multiple entries exist. Press `K` to hover the executed SQL (bind params already substituted), SQL-highlighted, auto-dismissing on cursor move.

Size is controlled by `max_history` (default `20`; `0` = unlimited).

</details>

<details>
<summary><b>Column types</b></summary>

Press `d` in the dbout buffer to toggle database type annotations in the header:

```
EMPLOYEE_ID [NUMBER] | FIRST_NAME [VARCHAR2] | HIRE_DATE [DATE]
```

Show them by default with `show_column_types = true`. Annotations use the `DbliteColumnType` highlight (links to `Comment`); override via `style.dbout.column_type_hl`.

</details>

<details>
<summary><b>Inspect</b></summary>

`gi` (or `:Dblite inspect`) opens the current page in a scratch window with no truncation. Tab-complete the format:

| Format | Description |
|---|---|
| `json` | Pretty-printed via `jq` (raw fallback) |
| `table` | Same layout as dbout, widths fit content |
| `csv` | RFC-4180 escaped |

Opens per `json_view` (default `"tab"`); `q` closes. In `json`, cell values that are themselves serialized JSON are decoded and nested inline instead of shown as an escaped blob — set `inspect_expand_json = false` to keep raw strings.

</details>

<details>
<summary><b>Autocomplete (blink.cmp)</b></summary>

Add the source to your blink config:

```lua
sources = {
  providers = { dblite = { module = 'dblite.blink', name = 'dblite' } },
  default = { 'lsp', 'path', 'snippets', 'buffer', 'dblite' },
}
```

| Context | Completions |
|---|---|
| Any SQL buffer | SQL keywords + table names |
| After `FROM` / `JOIN` / `INTO` / `UPDATE` | table names first |
| After `table.` | that table's columns |
| After `:` | existing `dblite.binds.json` keys + columns as bind suggestions |
| Inside `dblite.binds.json` | dotted column keys like `orders.id` |

Schema is fetched once per connection switch in the background, then served from cache. It uses whatever connection `:DbliteUseConn` set — no extra config.

</details>

<details>
<summary><b>Connections panel & telescope picker</b></summary>

`:DblitePanel` toggles a side panel of saved connections (active one marked `✓`):

| Key | Action |
|---|---|
| `<CR>` | Activate the connection under the cursor |
| `cw` | Edit it |
| `q` | Close the panel |

Prefer a fuzzy picker? Set `connection_picker = "telescope"` (requires telescope.nvim, **off by default**). Then `:DblitePanel` opens the picker instead; the active connection is marked `●` and the preview pane masks the password. `:DbliteConnPicker` always opens the picker regardless of the setting, so you can bind it directly:

```lua
require('dblite').setup({
  connection_picker = 'telescope',
  telescope_picker = {
    preview       = true, -- show the details preview pane
    width         = 0.4,  -- fraction of editor (<= 1) or absolute columns (> 1)
    height        = 0.4,
    preview_width = 0.5,  -- preview width as a fraction of the picker
  },
})
vim.keymap.set('n', '<leader>dc', '<cmd>DbliteConnPicker<cr>', { desc = 'dblite: pick connection' })
```

</details>

## API

Everything is callable from Lua — handy for custom keymaps:

```lua
local db = require('dblite')
db.execute()               -- run the current buffer
db.execute_at_cursor()     -- run the statement under the cursor
db.toggle_dbout()          -- show/hide the result window
db.inspect(format)         -- 'json' | 'table' | 'csv'
db.toggle_binds()          -- toggle the dblite.binds.json split
db.toggle_panel()          -- toggle the connections panel
db.get_active_conn()       -- active connection object, or nil
db.get_flat_binds()        -- flattened dblite.binds.json as a table
```

<details>
<summary>Full API surface</summary>

```lua
db.open_binds()            -- open/focus the binds split (does not close)
db.edit_binds()            -- alias for toggle_binds()
db.edit_connections_file() -- open connections JSON for direct editing
db.open_panel()            -- open the panel
db.close_panel()           -- close the panel
db.is_panel_open()         -- true/false
```

</details>

## Configuration

`setup()` takes no options if you're happy with the defaults. Common ones:

```lua
require('dblite').setup({
  split_dir         = 'horizontal', -- 'vertical' | 'horizontal' | 'tab'
  page_size         = 100,          -- rows per page
  max_rows          = 10000,        -- hard cap on rows returned
  max_col_width     = 50,           -- truncate wider cells; 0 = no limit
  max_history       = 20,           -- results kept in history; 0 = unlimited
  show_column_types = false,        -- show [TYPE] headers by default
  connection_picker = 'panel',      -- 'panel' | 'telescope'
})
```

<details>
<summary>All options & defaults</summary>

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
  inspect_expand_json = true,     -- json inspect: decode cell values that are themselves JSON strings
  panel = {
    width = 30,                   -- side panel width in columns
  },
  connection_picker = 'panel',    -- 'panel' | 'telescope' (requires telescope.nvim)
  telescope_picker = {
    preview       = true,         -- show the connection-details preview (password masked)
    width         = 0.4,          -- fraction of editor (<= 1) or absolute columns (> 1)
    height        = 0.4,
    preview_width = 0.5,          -- preview pane width as a fraction of the picker
  },
  binds_split = {
    style        = 'split',       -- 'split' | 'float'
    split_dir    = 'vertical',    -- 'vertical' | 'horizontal' (split only)
    width        = 40,            -- columns for vertical split. 0 = let nvim decide.
    height       = 20,            -- rows for horizontal split. 0 = let nvim decide.
    float_width  = 0,             -- float width in columns.  0 = 70% of editor width.
    float_height = 0,             -- float height in rows.    0 = 60% of editor lines.
  },
  style = {
    dbout = {
      cursorline = false,         -- highlight the line under the cursor
      column_type_hl = 'DbliteColumnType',
      -- Status line sections. Each entry: { "item", sep = "…", hl = "HlGroup" }
      -- Available items: "history" | "pagination" | "query_time" | "connection" | "binds_file"
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
      next = 'L', prev = 'H', cancel = '<C-c>', inspect = 'gi',
      history_prev = '[', history_next = ']', hover_query = 'K', toggle_types = 'd',
    },
    editor = {
      binds      = '<leader>b',   -- toggle dblite.binds.json split
      fullscreen = '<leader>l',   -- toggle dbout fullscreen
    },
    panel = { select = '<CR>', edit = 'cw', close = 'q' },
  },
})
```

</details>

Full reference is also available in `:help dblite`.

## Roadmap

- MySQL support

## License

_No license has been chosen yet._
