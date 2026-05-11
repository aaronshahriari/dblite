# dblite

A Neovim plugin for querying Oracle databases. Runs SQL from the current buffer, displays paginated results in a split, and manages named connections with env-var support for credentials.

On install, dblite downloads a pre-built native binary from GitHub Releases. If no release binary matches your platform, it falls back to building from source (requires GraalVM with `native-image`).

## Installation

### vim.pack (Neovim 0.11+)

Register the `PackChanged` hook **before** `vim.pack.add()` — it runs the download automatically on install and update:

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

If the hook wasn't in place when you first installed, run `:DbliteBuild` inside Neovim.

### lazy.nvim

```lua
{
  'aaronshahriari/dblite',
  build = function() require('dblite.download').download_or_build() end,
  config = function()
    require('dblite').setup()
  end,
}
```

### Manual

```sh
git clone https://github.com/aaronshahriari/dblite
cd dblite
```

Then open Neovim, add the directory to `runtimepath`, call `require('dblite').setup()`, and run `:DbliteBuild`.

## Connections

Connections are stored at `~/.local/share/nvim/dblite/connections.json` (chmod 600). Passwords can be stored as `$ENV_VAR` references and are resolved from the shell environment at query time.

| Command | Description |
|---|---|
| `:DbliteBuild` | Compile the native binary via Maven (needed once after install). |
| `:DbliteAddConn [uri]` | Add a connection. Accepts `oracle://user:pass@host:port/service` or prompts field-by-field. |
| `:DbliteListConns` | List all connections. Active connection is marked `*`. |
| `:DbliteUseConn <name>` | Set the active connection for `:DbliteRun`. |
| `:DbliteEditConn <name>` | Edit a saved connection. |
| `:DbliteDeleteConn <name>` | Delete a connection. |

All commands that take a name support tab-completion.

## Usage

Open a `.sql` file, set an active connection with `:DbliteUseConn`, then run `:DbliteRun` to execute the buffer. Results appear in a paginated split.

| Key | Action |
|---|---|
| `L` | Next page |
| `H` | Previous page |
| `<C-c>` | Cancel in-flight query |

## Configuration

```lua
require('dblite').setup({
  split_dir    = 'horizontal', -- 'vertical' | 'horizontal' | 'tab'
  split_size   = { width = 80, height = 20 },
  page_size    = 100,
  max_rows     = 10000,
  max_col_width = 50,
  keymaps = {
    dbout = { next = 'L', prev = 'H', cancel = '<C-c>' },
  },
})
```

## Todo
- Integrated panel
  - connections
    - check mark next to currently connected
  - queries per connection
  - help menu (toggle via config)
- Dbout
  - show with ligatures
  - keybind to pull into its own buffer (table, json, csv)
