# dblite

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
  { src = 'https://github.com/aaronshahriari/dblite' },
})

require('dblite').setup()
```

If the hook wasn't in place on first install, run `:DbliteBuild` manually.

### lazy.nvim

The plugin ships a `build.lua` that lazy.nvim picks up automatically, so no `build =` key is needed. The binary is downloaded (or rebuilt) on every install and update.

```lua
{
  'aaronshahriari/dblite',
  config = function()
    require('dblite').setup()
  end,
}
```

### vim-plug

```vim
Plug 'aaronshahriari/dblite', { 'do': ':DbliteBuild' }
```

### packer.nvim

```lua
use { 'aaronshahriari/dblite', run = ':DbliteBuild' }
```

### Manual

```sh
git clone https://github.com/aaronshahriari/dblite
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

Open any buffer, set an active connection with `:DbliteUseConn` (or via the panel), then run `:DbliteRun`. Results open in a paginated split.

| Key | Action |
|---|---|
| `L` | Next page |
| `H` | Previous page |
| `<C-c>` | Cancel in-flight query |

Trailing semicolons are stripped automatically — write SQL however feels natural.

## API

All functionality is accessible programmatically:

```lua
local db = require('dblite')

db.execute()         -- run the current buffer as a SQL query
db.toggle_panel()    -- open the connections panel (or close if already open)
db.open_panel()      -- open the panel
db.close_panel()     -- close the panel
db.is_panel_open()   -- returns true/false
```

Example keymap setup:

```lua
local db = require('dblite')
vim.keymap.set('n', '<leader>dr', db.execute,      { desc = 'dblite: run query' })
vim.keymap.set('n', '<leader>dp', db.toggle_panel, { desc = 'dblite: toggle panel' })
```

## Configuration

```lua
require('dblite').setup({
  split_dir     = 'horizontal', -- 'vertical' | 'horizontal' | 'tab'
  split_size    = { width = 80, height = 20 },
  page_size     = 100,
  max_rows      = 10000,
  max_col_width = 50,
  panel = {
    width = 30,  -- side panel width in columns
  },
  keymaps = {
    dbout = { next = 'L', prev = 'H', cancel = '<C-c>' },
    panel = { select = '<CR>', edit = 'cw', close = 'q' },
  },
})
```

## Todo
- Integrated panel
  - connections
    - check mark next to currently connected
  - queries per connection
    - ctrl-* open in splits etc
  - help menu (toggle via config)
- Dbout
  - better visual when running the query
  - keybind to pull into its own buffer (table, json, csv)
    - when bumping output into a new window allow for json output and showing the full column data
- blink autocomplete for current connection
