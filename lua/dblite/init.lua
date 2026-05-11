local config       = require("dblite.config")
local connections  = require("dblite.connections")
local panel        = require("dblite.panel")
local query_module = require("dblite.query")

local M = {}

-- Resolve plugin root from this file's location (lua/dblite/init.lua → root)
local _plugin_root = (function()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    return src:sub(2):gsub("/lua/dblite/init%.lua$", "")
  end
end)()

local split_cmds = {
  vertical = "vnew",
  horizontal = "new",
  tab = "tabnew",
}

local ns       = vim.api.nvim_create_namespace("dblite")
local flash_ns = vim.api.nvim_create_namespace("dblite_flash")
vim.api.nvim_set_hl(0, "DbliteStatusPage", { link = "Title",    default = true })
vim.api.nvim_set_hl(0, "DbliteFlash",      { link = "Visual",    default = true })

local state = {
  result_bufnr   = nil,
  current_job    = nil,
  rows           = {},
  columns        = {},
  widths         = {},
  page           = 1,
  active_conn    = nil,
  spinner_timer  = nil,
  spinner_start  = 0,
  last_elapsed   = nil,
  flash_bufnr    = nil,
}

local function merge_into(target, source)
  for k, v in pairs(source) do
    if type(v) == "table" and type(target[k]) == "table" then
      merge_into(target[k], v)
    else
      target[k] = v
    end
  end
end

function M.setup(opts)
  if opts then merge_into(config, opts) end
end

local function cell(value, width)
  local s = value == vim.NIL and "" or tostring(value)
  local max = config.max_col_width or 0
  if max > 0 and #s > max then
    s = s:sub(1, max - 1) .. "…"
  end
  if #s < width then
    s = s .. string.rep(" ", width - #s)
  end
  return s
end

local function compute_widths(rows, columns)
  local widths = {}
  local max = config.max_col_width or 0
  for _, col in ipairs(columns) do
    widths[col] = #col
  end
  for _, row in ipairs(rows) do
    for _, col in ipairs(columns) do
      local v = row[col]
      local s = v == vim.NIL and "" or tostring(v)
      if max > 0 and #s > max then s = s:sub(1, max) end
      if #s > widths[col] then widths[col] = #s end
    end
  end
  return widths
end

local function render_page()
  local bufnr = state.result_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  local total = #state.rows
  local page_size = config.page_size or 100
  local total_pages = math.max(1, math.ceil(total / page_size))
  if state.page > total_pages then state.page = total_pages end
  if state.page < 1 then state.page = 1 end

  local start_row = (state.page - 1) * page_size + 1
  local end_row = math.min(start_row + page_size - 1, total)

  local lines = {}
  local base = total == 0
    and "(no rows)"
    or string.format("(%d/%d)", state.page, total_pages)
  local status = state.last_elapsed
    and (base .. string.format("  —  %.3fs", state.last_elapsed))
    or base
  table.insert(lines, status)
  table.insert(lines, "")

  if total == 0 then
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
      end_col = #status,
      hl_group = "DbliteStatusPage",
    })
    set_winbar_header()
    return
  end

  local header_parts = {}
  local sep_parts = {}
  for _, col in ipairs(state.columns) do
    table.insert(header_parts, cell(col, state.widths[col]))
    table.insert(sep_parts, string.rep("-", state.widths[col]))
  end
  table.insert(lines, table.concat(header_parts, " | "))
  table.insert(lines, table.concat(sep_parts, "-+-"))

  for i = start_row, end_row do
    local row = state.rows[i]
    local parts = {}
    for _, col in ipairs(state.columns) do
      table.insert(parts, cell(row[col], state.widths[col]))
    end
    table.insert(lines, table.concat(parts, " | "))
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
    end_col = #status,
    hl_group = "DbliteStatusPage",
  })
  set_winbar_header()
end

local function set_status(text)
  local bufnr = state.result_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { text })
  vim.bo[bufnr].modifiable = false
end

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function stop_spinner()
  if state.spinner_timer then
    state.spinner_timer:stop()
    state.spinner_timer:close()
    state.spinner_timer = nil
  end
end

local function start_spinner()
  stop_spinner()
  local idx = 1
  state.spinner_start = vim.uv.now()
  local timer = vim.uv.new_timer()
  timer:start(0, 80, vim.schedule_wrap(function()
    if not state.result_bufnr or not vim.api.nvim_buf_is_valid(state.result_bufnr) then
      stop_spinner()
      return
    end
    local elapsed = (vim.uv.now() - state.spinner_start) / 1000
    set_status(string.format("   %s  %.1fs", SPINNER[idx], elapsed))
    idx = (idx % #SPINNER) + 1
  end))
  state.spinner_timer = timer
end

local function clear_flash()
  if state.flash_bufnr and vim.api.nvim_buf_is_valid(state.flash_bufnr) then
    vim.api.nvim_buf_clear_namespace(state.flash_bufnr, flash_ns, 0, -1)
  end
  state.flash_bufnr = nil
end

local function set_flash(bufnr, sr, sc, er, ec)
  clear_flash()
  state.flash_bufnr = bufnr
  local end_row = (ec == 0 and er > sr) and er - 1 or er
  local lines = vim.api.nvim_buf_get_lines(bufnr, sr, end_row + 1, false)
  for i, line in ipairs(lines) do
    vim.api.nvim_buf_set_extmark(bufnr, flash_ns, sr + i - 1, 0, {
      end_col  = #line,
      hl_group = "DbliteFlash",
      hl_eol   = true,
    })
  end
  local timeout = config.flash_timeout or 2000
  if timeout > 0 then
    vim.defer_fn(clear_flash, timeout)
  end
end

local function clear_winbar()
  if not state.result_bufnr or not vim.api.nvim_buf_is_valid(state.result_bufnr) then return end
  for _, winnr in ipairs(vim.fn.win_findbuf(state.result_bufnr)) do
    pcall(function() vim.wo[winnr].winbar = "" end)
  end
end

local function set_winbar_header()
  if not config.sticky_header then clear_winbar(); return end
  if not state.result_bufnr or not vim.api.nvim_buf_is_valid(state.result_bufnr) then return end
  if #state.columns == 0 then clear_winbar(); return end
  local wins = vim.fn.win_findbuf(state.result_bufnr)
  if #wins == 0 then return end
  local parts = {}
  for _, col in ipairs(state.columns) do
    table.insert(parts, cell(col, state.widths[col]))
  end
  local header = table.concat(parts, " | "):gsub("%%", "%%%%")
  for _, winnr in ipairs(wins) do
    pcall(function() vim.wo[winnr].winbar = header end)
  end
end

local function configure_result_buffer(bufnr)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = config.filetype or ""

  local function map(lhs, fn, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, desc = desc })
    end
  end

  local km = (config.keymaps and config.keymaps.dbout) or {}

  map(km.next, function()
    state.page = state.page + 1
    render_page()
  end, "dblite: next page")

  map(km.prev, function()
    state.page = state.page - 1
    render_page()
  end, "dblite: prev page")

  map(km.cancel, function()
    if state.current_job then
      pcall(function() state.current_job:kill(15) end)
      stop_spinner()
      clear_flash()
      set_status("-- cancelling...")
    end
  end, "dblite: cancel query")

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      if state.current_job then
        pcall(function() state.current_job:kill(15) end)
      end
      state.result_bufnr = nil
    end,
  })
end

local function ensure_result_buffer()
  if state.result_bufnr and vim.api.nvim_buf_is_valid(state.result_bufnr) then
    local bufnr = state.result_bufnr
    local wins = vim.fn.win_findbuf(bufnr)
    if #wins == 0 then
      vim.cmd(split_cmds[config.split_dir] or split_cmds.vertical)
      vim.api.nvim_win_set_buf(0, bufnr)
      local sz = config.split_size or {}
      if config.split_dir == "vertical" and sz.width and sz.width > 0 then
        vim.api.nvim_win_set_width(0, sz.width)
      elseif config.split_dir == "horizontal" and sz.height and sz.height > 0 then
        vim.api.nvim_win_set_height(0, sz.height)
      end
      vim.cmd("wincmd p")
    end
    return bufnr
  end

  vim.cmd(split_cmds[config.split_dir] or split_cmds.vertical)
  local bufnr = vim.api.nvim_get_current_buf()
  configure_result_buffer(bufnr)

  local sz = config.split_size or {}
  if config.split_dir == "vertical" and sz.width and sz.width > 0 then
    vim.api.nvim_win_set_width(0, sz.width)
  elseif config.split_dir == "horizontal" and sz.height and sz.height > 0 then
    vim.api.nvim_win_set_height(0, sz.height)
  end

  vim.cmd("wincmd p")
  state.result_bufnr = bufnr
  return bufnr
end

local function expand_env(s)
  if type(s) ~= "string" then return s end
  return (s:gsub("%$([%w_]+)", function(var) return os.getenv(var) or ("$" .. var) end))
end

local function execute_core(query)
  if vim.fn.executable(config.binary) ~= 1 then
    local hint = _plugin_root
      and "run :DbliteBuild to compile the native binary"
      or  "binary 'dblite' not found on PATH — run the build first"
    vim.notify("dblite: " .. hint, vim.log.levels.ERROR)
    return
  end

  if not state.active_conn then
    vim.notify("dblite: no active connection — use :DbliteUseConn <name>", vim.log.levels.ERROR)
    return
  end

  if state.current_job then
    pcall(function() state.current_job:kill(15) end)
    state.current_job = nil
  end

  state.last_elapsed = nil
  ensure_result_buffer()
  start_spinner()

  local cmd = { config.binary }
  if config.max_rows and config.max_rows > 0 then
    table.insert(cmd, "--max-rows")
    table.insert(cmd, tostring(config.max_rows))
  end

  local c = state.active_conn
  local sys_env = {
    DB_URL      = connections.jdbc_url(c),
    DB_USER     = expand_env(c.user),
    DB_PASSWORD = expand_env(c.password or ""),
  }

  local job
  job = vim.system(cmd, { stdin = query, text = true, env = sys_env }, function(result)
    vim.schedule(function()
      if state.current_job ~= job then return end
      state.current_job = nil
      local elapsed = (vim.uv.now() - state.spinner_start) / 1000
      stop_spinner()
      clear_flash()

      if not state.result_bufnr or not vim.api.nvim_buf_is_valid(state.result_bufnr) then return end

      if result.signal ~= 0 then
        clear_winbar()
        set_status(string.format("-- cancelled  (%.3fs)", elapsed))
        return
      end

      if result.code ~= 0 then
        clear_winbar()
        local err_lines = vim.split("-- dblite failed: " .. (result.stderr or ""), "\n", { plain = true })
        vim.bo[state.result_bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(state.result_bufnr, 0, -1, false, err_lines)
        vim.bo[state.result_bufnr].modifiable = false
        return
      end

      local ok, parsed = pcall(vim.json.decode, result.stdout)
      if not ok or type(parsed) ~= "table" then
        clear_winbar()
        set_status("-- dblite: failed to parse JSON: " .. tostring(parsed))
        return
      end

      state.columns      = parsed.columns or {}
      state.rows         = parsed.rows    or {}
      state.widths       = compute_widths(state.rows, state.columns)
      state.page         = 1
      state.last_elapsed = elapsed
      render_page()
    end)
  end)
  state.current_job = job
end

function M.execute()
  local query = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  execute_core(query)
end

function M.execute_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local sr, sc, er, ec, query = query_module.at_cursor(bufnr)
  if not sr or not query or query:match("^%s*$") then
    vim.notify("dblite: no query at cursor", vim.log.levels.WARN)
    return
  end
  set_flash(bufnr, sr, sc, er, ec)
  execute_core(query)
end

vim.api.nvim_create_user_command("DbliteRun",   M.execute,           {})
vim.api.nvim_create_user_command("DbliteRunAt", M.execute_at_cursor, {})

-- :DbliteBuild — download pre-built binary from GitHub Releases, or build from source
vim.api.nvim_create_user_command("DbliteBuild", function()
  require("dblite.download").download_or_build()
  -- Re-resolve binary path in case it was just created
  if _plugin_root then
    local bin = _plugin_root .. "/bin/dblite"
    if vim.fn.filereadable(bin) == 1 then
      config.binary = bin
    end
  end
end, {})

-- Returns sorted list of saved connection names (used for tab-completion).
local function conn_names()
  local names = {}
  for _, c in ipairs(connections.list()) do table.insert(names, c.name) end
  table.sort(names)
  return names
end

local function complete_name(arg_lead)
  local out = {}
  for _, n in ipairs(conn_names()) do
    if n:sub(1, #arg_lead) == arg_lead then table.insert(out, n) end
  end
  return out
end

local function edit_conn_by_name(name)
  local conn = connections.get_by_name(name)
  if not conn then
    vim.notify("dblite: connection '" .. name .. "' not found", vim.log.levels.ERROR)
    return
  end

  local function prompt(label, current)
    local v = vim.fn.input(label .. " [" .. tostring(current) .. "]: ")
    return v ~= "" and v or current
  end

  local updates = {
    name    = prompt("Name",    conn.name),
    host    = prompt("Host",    conn.host),
    port    = tonumber(prompt("Port", conn.port or 1521)),
    service = prompt("Service", conn.service),
    user    = prompt("User",    conn.user),
  }
  local pw = vim.fn.inputsecret("Password (leave blank to keep): ")
  if pw ~= "" then updates.password = pw end

  local ok, result = pcall(connections.update, conn.id, updates)
  if not ok then
    vim.notify("\ndblite: " .. tostring(result), vim.log.levels.ERROR)
    return
  end
  if state.active_conn and state.active_conn.id == conn.id then
    state.active_conn = connections.get(conn.id)
  end
  vim.notify("\ndblite: updated '" .. (updates.name or conn.name) .. "'", vim.log.levels.INFO)
  panel.refresh()
end

panel.setup({
  get_state = function() return state end,
  on_edit   = function(name) edit_conn_by_name(name) end,
})

-- :DbliteAddConn — interactive; optionally accepts a URI as first argument
-- URI format: oracle://user[:password]@host[:port]/service
vim.api.nvim_create_user_command("DbliteAddConn", function(opts)
  local fields

  if opts.args ~= "" then
    local parsed, err = connections.parse_uri(opts.args)
    if not parsed then
      vim.notify("dblite: " .. err, vim.log.levels.ERROR)
      return
    end
    fields = parsed
  else
    -- Ask for URI first; blank means fall through to field-by-field
    local uri_input = vim.fn.input("URI (oracle://user:pass@host:port/service) or blank for manual: ")
    if uri_input ~= "" then
      local parsed, err = connections.parse_uri(uri_input)
      if not parsed then
        vim.notify("\ndblite: " .. err, vim.log.levels.ERROR)
        return
      end
      fields = parsed
    end
  end

  local name = vim.fn.input("Connection name: ")
  if name == "" then return end

  if not fields then
    local host     = vim.fn.input("Host: ")
    if host == "" then return end
    local port_s   = vim.fn.input("Port [1521]: ")
    local service  = vim.fn.input("Service: ")
    if service == "" then return end
    local user     = vim.fn.input("User: ")
    if user == "" then return end
    local password = vim.fn.inputsecret("Password (or $ENV_VAR): ")
    fields = {
      host     = host,
      port     = tonumber(port_s ~= "" and port_s or "1521") or 1521,
      service  = service,
      user     = user,
      password = password,
    }
  else
    -- URI path: password may be missing — give the user a chance to set it
    if (fields.password or "") == "" then
      fields.password = vim.fn.inputsecret("Password (or $ENV_VAR, leave blank to set later): ")
    end
  end

  fields.name = name
  local ok, result = pcall(connections.add, fields)
  if ok then
    vim.notify("\ndblite: saved connection '" .. name .. "'", vim.log.levels.INFO)
    panel.refresh()
  else
    vim.notify("\ndblite: " .. tostring(result), vim.log.levels.ERROR)
  end
end, { nargs = "?" })

-- :DbliteListConns — show all connections; active one is marked with *
vim.api.nvim_create_user_command("DbliteListConns", function()
  local conns = connections.list()
  if #conns == 0 then
    vim.notify("dblite: no connections saved. Use :DbliteAddConn", vim.log.levels.INFO)
    return
  end
  local lines = { "dblite connections:" }
  for _, c in ipairs(conns) do
    local active = (state.active_conn and state.active_conn.id == c.id) and " *" or ""
    table.insert(lines, string.format(
      "  %-20s  %s@%s:%d/%s%s",
      c.name, c.user, c.host, c.port or 1521, c.service, active
    ))
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, {})

-- :DbliteUseConn <name> — set the active connection for queries
vim.api.nvim_create_user_command("DbliteUseConn", function(opts)
  if opts.args == "" then
    local msg = state.active_conn
      and ("dblite: active connection: " .. state.active_conn.name)
      or  "dblite: no active connection"
    vim.notify(msg, vim.log.levels.INFO)
    return
  end
  local conn = connections.get_by_name(opts.args)
  if not conn then
    vim.notify("dblite: connection '" .. opts.args .. "' not found", vim.log.levels.ERROR)
    return
  end
  state.active_conn = conn
  vim.notify("dblite: using '" .. conn.name .. "'", vim.log.levels.INFO)
  panel.refresh()
end, { nargs = "?", complete = complete_name })

-- :DbliteEditConn <name> — re-prompt each field (leave blank to keep current value)
vim.api.nvim_create_user_command("DbliteEditConn", function(opts)
  edit_conn_by_name(opts.args)
end, { nargs = 1, complete = complete_name })

-- :DbliteDeleteConn <name> — permanently remove a saved connection
vim.api.nvim_create_user_command("DbliteDeleteConn", function(opts)
  local conn = connections.get_by_name(opts.args)
  if not conn then
    vim.notify("dblite: connection '" .. opts.args .. "' not found", vim.log.levels.ERROR)
    return
  end
  if state.active_conn and state.active_conn.id == conn.id then
    state.active_conn = nil
  end
  connections.delete(conn.id)
  vim.notify("dblite: deleted '" .. conn.name .. "'", vim.log.levels.INFO)
  panel.refresh()
end, { nargs = 1, complete = complete_name })

function M.toggle_dbout()
  if not state.result_bufnr or not vim.api.nvim_buf_is_valid(state.result_bufnr) then return end
  local wins = vim.fn.win_findbuf(state.result_bufnr)
  if #wins > 0 then
    for _, winnr in ipairs(wins) do
      pcall(vim.api.nvim_win_hide, winnr)
    end
  else
    vim.cmd(split_cmds[config.split_dir] or split_cmds.vertical)
    vim.api.nvim_win_set_buf(0, state.result_bufnr)
    local sz = config.split_size or {}
    if config.split_dir == "vertical" and sz.width and sz.width > 0 then
      vim.api.nvim_win_set_width(0, sz.width)
    elseif config.split_dir == "horizontal" and sz.height and sz.height > 0 then
      vim.api.nvim_win_set_height(0, sz.height)
    end
    vim.cmd("wincmd p")
  end
end

vim.api.nvim_create_user_command("DbliteToggleOut", M.toggle_dbout, {})

-- Panel public API
M.toggle_panel    = panel.toggle
M.open_panel      = panel.open
M.close_panel     = panel.close
M.is_panel_open   = panel.is_open

vim.api.nvim_create_user_command("DblitePanel", function()
  panel.toggle()
end, {})

-- Unified :Dblite <subcommand> entry point
do
  local dispatch = {
    run           = function(a) if a[2] == "at" then M.execute_at_cursor() else M.execute() end end,
    toggle        = function(a)
      if     a[2] == "panel" then panel.toggle()
      elseif a[2] == "dbout" then M.toggle_dbout()
      else vim.notify("dblite: toggle what? (panel | dbout)", vim.log.levels.ERROR) end
    end,
    conn          = function(a)
      local sub = a[2]
      if     sub == "add"  then vim.cmd("DbliteAddConn "  .. (a[3] or ""))
      elseif sub == "list" then vim.cmd("DbliteListConns")
      elseif sub == "use"  then vim.cmd("DbliteUseConn "  .. (a[3] or ""))
      elseif sub == "edit" then vim.cmd("DbliteEditConn " .. (a[3] or ""))
      elseif sub == "del"  then vim.cmd("DbliteDeleteConn " .. (a[3] or ""))
      else vim.notify("dblite: conn what? (add | list | use | edit | del)", vim.log.levels.ERROR) end
    end,
    build         = function() vim.cmd("DbliteBuild") end,
  }

  local function complete(arg_lead, cmd_line)
    local tokens = vim.split(cmd_line, "%s+")
    local n = #tokens
    if n == 2 then
      return vim.tbl_filter(function(k) return k:sub(1, #arg_lead) == arg_lead end,
        { "run", "toggle", "conn", "build" })
    elseif n == 3 then
      local sub = tokens[2]
      local opts = {
        run    = { "at" },
        toggle = { "panel", "dbout" },
        conn   = { "add", "list", "use", "edit", "del" },
      }
      local choices = opts[sub] or {}
      return vim.tbl_filter(function(k) return k:sub(1, #arg_lead) == arg_lead end, choices)
    elseif n >= 4 and tokens[2] == "conn" and (tokens[3] == "use" or tokens[3] == "edit" or tokens[3] == "del") then
      return complete_name(arg_lead)
    end
    return {}
  end

  vim.api.nvim_create_user_command("Dblite", function(opts)
    local args = vim.split(opts.args, "%s+")
    local fn = dispatch[args[1]]
    if fn then
      fn(args)
    else
      vim.notify("dblite: unknown subcommand '" .. (args[1] or "") .. "'", vim.log.levels.ERROR)
    end
  end, {
    nargs    = "+",
    complete = complete,
  })
end

return M
