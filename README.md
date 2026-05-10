# dblite

A Neovim plugin for querying Oracle databases. Runs SQL from the current buffer, displays paginated results in a split, and manages named connections with env-var support for credentials.

**Requires:** GraalVM with `native-image` on PATH (build step only).

## Installation

### vim.pack (Neovim 0.11+)

Register the `PackChanged` hook **before** calling `vim.pack.add()` so the build runs on install and update:

```lua
vim.api.nvim_create_autocmd('PackChanged', {
  callback = function(ev)
    local name, kind = ev.data.spec.name, ev.data.kind
    if name == 'dblite' and (kind == 'install' or kind == 'update') then
      vim.notify('dblite: building native binary...', vim.log.levels.INFO)
      vim.system(
        { 'mvn', '-q', 'clean', 'package', '-Pnative' },
        { cwd = ev.data.path }
      ):wait()
      vim.notify('dblite: build complete', vim.log.levels.INFO)
    end
  end,
})

vim.pack.add({
  { src = 'https://github.com/aaronshahriari/dblite' },
})

require('dblite').setup()
```

### lazy.nvim

```lua
{
  'aaronshahriari/dblite',
  build = 'mvn -q clean package -Pnative',
  config = function()
    require('dblite').setup()
  end,
}
```

### Manual

```sh
git clone https://github.com/aaronshahriari/dblite
cd dblite
mvn -q clean package -Pnative
```

Add the directory to your Neovim `runtimepath`, then call `require('dblite').setup()`.

## Connections

Connections are stored at `~/.local/share/nvim/dblite/connections.json` (chmod 600). Passwords can be stored as `$ENV_VAR` references and are resolved from the shell environment at query time.

| Command | Description |
|---|---|
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
