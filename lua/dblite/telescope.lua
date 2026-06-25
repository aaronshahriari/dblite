-- Optional telescope.nvim-based connection picker.
-- Enabled with `connection_picker = "telescope"`; requires nvim-telescope/telescope.nvim.
local config      = require("dblite.config")
local connections = require("dblite.connections")

local M = {}

local _get_state
local _on_select

vim.api.nvim_set_hl(0, "DbliteTelescopeActive", { link = "String", default = true })

local type_labels = {
  oracle    = "Oracle",
  sqlserver = "SQL Server",
}

function M.setup(opts)
  _get_state = opts.get_state
  _on_select = opts.on_select
end

-- Returns true if telescope.nvim is available on the runtimepath.
function M.available()
  return pcall(require, "telescope")
end

local function target_str(c)
  local db_val       = (c.type == "sqlserver") and c.database or c.service
  local default_port = (c.type == "sqlserver") and 1433 or 1521
  return string.format("%s@%s:%d/%s",
    c.user or "", c.host or "", c.port or default_port, db_val or "?")
end

-- Opens the telescope picker for saved connections. Marks the active
-- connection so a connected user re-opening the picker sees they're still on it.
function M.pick()
  if not M.available() then
    vim.notify(
      "dblite: telescope.nvim is not installed (connection_picker = 'telescope')",
      vim.log.levels.ERROR)
    return
  end

  local pickers       = require("telescope.pickers")
  local finders       = require("telescope.finders")
  local conf          = require("telescope.config").values
  local actions       = require("telescope.actions")
  local action_state  = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  local conns = connections.list()
  if #conns == 0 then
    vim.notify("dblite: no connections saved. Use :DbliteAddConn", vim.log.levels.INFO)
    return
  end

  local st     = _get_state and _get_state() or {}
  local active = st.active_conn

  local displayer = entry_display.create({
    separator = "  ",
    items = {
      { width = 1 },         -- active marker
      { width = 24 },        -- name
      { width = 11 },        -- type label
      { remaining = true },  -- user@host:port/db
    },
  })

  local function entry_maker(c)
    local is_active = active ~= nil and active.id == c.id
    local target    = target_str(c)
    local name_hl   = is_active and "DbliteTelescopeActive" or "TelescopeResultsNormal"
    return {
      value   = c,
      ordinal = (c.name or "") .. " " .. (c.type or "") .. " " .. target,
      display = function()
        return displayer({
          { is_active and "\xe2\x97\x8f" or " ", "DbliteTelescopeActive" },  -- ● in UTF-8
          { c.name or "",                         name_hl },
          { type_labels[c.type] or c.type or "?", "Comment" },
          { target,                               "Comment" },
        })
      end,
    }
  end

  local title = active
    and ("Connections  (active: " .. active.name .. ")")
    or  "Connections"

  pickers.new({}, {
    prompt_title = title,
    finder = finders.new_table({ results = conns, entry_maker = entry_maker }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then return end
        local conn = entry.value
        if active and active.id == conn.id then
          vim.notify("dblite: already using '" .. conn.name .. "'", vim.log.levels.INFO)
          return
        end
        if _on_select then _on_select(conn) end
      end)
      return true
    end,
  }):find()
end

return M
