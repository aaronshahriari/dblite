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
  vertical   = "botright vnew",
  horizontal = "botright new",
  tab        = "tabnew",
}

local ns        = vim.api.nvim_create_namespace("dblite")
local flash_ns  = vim.api.nvim_create_namespace("dblite_flash")
local search_ns = vim.api.nvim_create_namespace("dblite_search")
vim.api.nvim_set_hl(0, "DbliteStatusPage",      { link = "Title",           default = true })
vim.api.nvim_set_hl(0, "DbliteFlash",           { link = "Visual",          default = true })
vim.api.nvim_set_hl(0, "DbliteSearch",          { link = "Search",          default = true })
vim.api.nvim_set_hl(0, "DbliteCancelled",       { link = "DiagnosticError", default = true })

local state = {
  result_bufnr    = nil,
  current_job     = nil,
  rows            = {},
  columns         = {},
  widths          = {},
  page            = 1,
  active_conn     = nil,
  spinner_timer   = nil,
  spinner_start   = 0,
  last_elapsed    = nil,
  flash_bufnr     = nil,
  raw_json        = nil,
  search_matches  = {},  -- global row indices (1-based) matching current search
  search_current  = 0,   -- index into search_matches of the highlighted match
  search_pattern  = nil, -- active pattern string; nil = no search
  history         = {},  -- ring of past query results
  history_idx     = 0,   -- current position in history; 0 = no entries
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
  local ek = (config.keymaps and config.keymaps.editor) or {}
  -- SQL-only keymaps: set per-buffer via FileType autocmd
  local sql_fts = "sql,plsql,mysql,sqlite"
  vim.api.nvim_create_autocmd("FileType", {
    pattern  = vim.split(sql_fts, ","),
    group    = vim.api.nvim_create_augroup("dblite_sql_keymaps", { clear = true }),
    callback = function(ev)
      local buf = ev.buf
      if ek.binds and ek.binds ~= "" then
        vim.keymap.set("n", ek.binds, function() M.edit_binds() end,
          { buffer = buf, silent = true, desc = "dblite: edit bind parameters" })
      end
      if ek.connections and ek.connections ~= "" then
        vim.keymap.set("n", ek.connections, function() M.edit_connections_file() end,
          { buffer = buf, silent = true, desc = "dblite: edit connections file" })
      end
    end,
  })
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

-- Shared status-line builder used by render_page, set_cancelled_status, and the spinner.
-- `overrides` is a table of { item_name = value | nil } that replace the default logic.
-- Items not in overrides fall back to their normal value.  Returns (status_string, hl_marks).
local function render_status_line(overrides, cancelled_items)
  overrides = overrides or {}
  cancelled_items = cancelled_items or {}
  local dbout_style = (config.style and config.style.dbout) or {}
  local sections = dbout_style.sections or {
    { "history" },
    { "pagination", sep = "  " },
    { "query_time", sep = "  —  " },
    { "connection", sep = "  ·  " },
  }

  local status   = ""
  local hl_marks = {}
  local has_items = false
  for _, sec in ipairs(sections) do
    local item = sec[1]
    local value
    if overrides[item] ~= nil then
      value = overrides[item]  -- explicit override (false = skip)
      if value == false then value = nil end
    elseif item == "connection" then
      value = state.active_conn and state.active_conn.name or "no connection"
    elseif item == "binds_file" then
      if vim.fn.filereadable(binds_file_path()) == 1 then value = "binds" end
    elseif item == "history" then
      if #state.history > 1 then
        value = string.format("◀ %d/%d ▶", state.history_idx, #state.history)
      end
    end
    if value then
      if has_items then
        local sep = sec.sep or "  ·  "
        local sep_col = #status
        status = status .. sep
        table.insert(hl_marks, { col = sep_col, end_col = #status, hl = "DbliteStatusPage" })
      end
      local col = #status
      status = status .. value
      local hl = cancelled_items[item] and "DbliteCancelled" or (sec.hl or "DbliteStatusPage")
      table.insert(hl_marks, { col = col, end_col = #status, hl = hl })
      has_items = true
    end
  end
  return status, hl_marks
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
  local status, hl_marks = render_status_line({
    pagination = total == 0 and "(no rows)" or string.format("(%d/%d)", state.page, total_pages),
    query_time = state.last_elapsed and string.format("%.3fs", state.last_elapsed) or nil,
  })
  table.insert(lines, status)
  table.insert(lines, "")

  if total == 0 then
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    for _, m in ipairs(hl_marks) do
      vim.api.nvim_buf_set_extmark(bufnr, ns, 0, m.col, { end_col = m.end_col, hl_group = m.hl })
    end
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
  for _, m in ipairs(hl_marks) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, m.col, { end_col = m.end_col, hl_group = m.hl })
  end
end

local function restore_history(idx)
  if idx < 1 or idx > #state.history then return end
  local entry = state.history[idx]
  state.history_idx  = idx
  state.columns      = entry.columns
  state.rows         = entry.rows
  state.widths       = entry.widths
  state.raw_json     = entry.raw_json
  state.last_elapsed = entry.last_elapsed
  state.page         = 1
  render_page()
end

local function set_status(text)
  local bufnr = state.result_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { text })
  vim.bo[bufnr].modifiable = false
end

local function set_cancelled_status(elapsed)
  local bufnr = state.result_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local status, hl_marks = render_status_line(
    { pagination = "cancelled", query_time = string.format("%.3fs", elapsed) },
    { pagination = true, query_time = true }
  )
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { status })
  vim.bo[bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, m in ipairs(hl_marks) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, m.col, { end_col = m.end_col, hl_group = m.hl })
  end
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
    local bufnr = state.result_bufnr
    local status, hl_marks = render_status_line({
      pagination = string.format("%s  %.1fs", SPINNER[idx], elapsed),
      query_time = false,
    })
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { status })
    vim.bo[bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    for _, m in ipairs(hl_marks) do
      vim.api.nvim_buf_set_extmark(bufnr, ns, 0, m.col, { end_col = m.end_col, hl_group = m.hl })
    end
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

local _saved_cancel_map = nil

local function set_global_cancel_keymap()
  local existing = vim.fn.maparg("<C-c>", "n", false, true)
  _saved_cancel_map = (existing and existing.lhs ~= nil) and existing or nil
  vim.keymap.set("n", "<C-c>", function()
    if state.current_job then
      pcall(function() state.current_job:kill(15) end)
      stop_spinner()
      clear_flash()
      if state.result_bufnr and vim.api.nvim_buf_is_valid(state.result_bufnr) then
        set_status("cancelling...")
      end
    end
  end, { desc = "dblite: cancel in-flight query" })
end

local function clear_global_cancel_keymap()
  pcall(vim.keymap.del, "n", "<C-c>")
  if _saved_cancel_map then
    vim.fn.mapset("n", false, _saved_cancel_map)
  end
  _saved_cancel_map = nil
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
      set_status("cancelling...")
    end
  end, "dblite: cancel query")

  map(km.inspect or "gi", function()
    M.inspect()
  end, "dblite: inspect current page")

  map(km.history_prev or "[", function()
    if state.history_idx > 1 then
      restore_history(state.history_idx - 1)
    end
  end, "dblite: previous history entry")

  map(km.history_next or "]", function()
    if state.history_idx < #state.history then
      restore_history(state.history_idx + 1)
    end
  end, "dblite: next history entry")

  map(km.hover_query or "K", function()
    local entry = state.history[state.history_idx]
    if not entry or not entry.query_text then
      vim.notify("dblite: no query in history", vim.log.levels.INFO)
      return
    end
    local lines = vim.split(entry.query_text, "\n", { plain = true })
    vim.lsp.util.open_floating_preview(lines, "sql", {
      border = "rounded",
      focus_id = "dblite_query_hover",
    })
  end, "dblite: hover query")

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

local function apply_dbout_win_style(winnr)
  local st = (config.style and config.style.dbout) or {}
  vim.wo[winnr].cursorline = st.cursorline == true
end

local function ensure_result_buffer()
  if state.result_bufnr and vim.api.nvim_buf_is_valid(state.result_bufnr) then
    local bufnr = state.result_bufnr
    local wins = vim.fn.win_findbuf(bufnr)
    local current_tab = vim.api.nvim_get_current_tabpage()
    local tab_wins = vim.api.nvim_tabpage_list_wins(current_tab)
    local tab_win_set = {}
    for _, w in ipairs(tab_wins) do tab_win_set[w] = true end
    local visible_in_tab = false
    for _, w in ipairs(wins) do
      if tab_win_set[w] then visible_in_tab = true; break end
    end
    if not visible_in_tab then
      -- close dbout windows in other tabs before opening here
      for _, w in ipairs(wins) do
        pcall(vim.api.nvim_win_hide, w)
      end
      vim.cmd(split_cmds[config.split_dir] or split_cmds.vertical)
      vim.api.nvim_win_set_buf(0, bufnr)
      local sz = config.split_size or {}
      if config.split_dir == "vertical" and sz.width and sz.width > 0 then
        vim.api.nvim_win_set_width(0, sz.width)
      elseif config.split_dir == "horizontal" and sz.height and sz.height > 0 then
        vim.api.nvim_win_set_height(0, sz.height)
      end
      apply_dbout_win_style(0)
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

  apply_dbout_win_style(0)
  vim.cmd("wincmd p")
  state.result_bufnr = bufnr
  return bufnr
end

local function binds_file_path()
  return vim.fn.getcwd() .. "/dblite.binds.json"
end

local function load_binds_file()
  local f = io.open(binds_file_path(), "r")
  if not f then return {} end
  local raw = f:read("*a"); f:close()
  if raw == "" then return {} end
  local ok, data = pcall(vim.json.decode, raw)
  return (ok and type(data) == "table") and data or {}
end

local function flatten_binds(tbl, prefix, out)
  out = out or {}
  for k, v in pairs(tbl) do
    local key = prefix and (prefix .. "." .. k) or k
    if type(v) == "table" then
      flatten_binds(v, key, out)
    else
      out[key] = v
    end
  end
  return out
end

-- JSON number → verbatim; "~expr" → raw SQL; string → auto-quoted + escaped
local function format_bind_value(v)
  if type(v) == "number" then return tostring(v) end
  local s = tostring(v)
  if s:sub(1, 1) == "~" then return s:sub(2) end
  return "'" .. s:gsub("'", "''") .. "'"
end

local function parse_bind_names(sql)
  local seen, names = {}, {}
  local stripped = sql:gsub("'[^']*'", function(s) return string.rep(" ", #s) end)
  for raw in stripped:gmatch(":[a-zA-Z_][a-zA-Z0-9_.]*") do
    local key = raw:sub(2):gsub("%.+$", "")
    if not seen[key] then seen[key] = true; table.insert(names, key) end
  end
  return names
end

local function apply_binds(sql, binds)
  local sorted = vim.tbl_keys(binds)
  table.sort(sorted, function(a, b) return #a > #b end)
  for _, name in ipairs(sorted) do
    local val  = format_bind_value(binds[name])
    local pat  = name:gsub("%.", "%%.")           -- escape dots for Lua pattern
    local repl = val:gsub("%%", "%%%%")           -- escape % in replacement string
    sql = sql:gsub(":" .. pat .. "([^a-zA-Z0-9_.])", repl .. "%1")
    if sql:sub(-(#name + 1)) == ":" .. name then
      sql = sql:sub(1, -(#name + 2)) .. val
    end
  end
  return sql
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

  local bind_names = parse_bind_names(query)

  local function do_run(q)
    state.last_elapsed = nil
    state.raw_json     = nil
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

  set_global_cancel_keymap()

  local job
  job = vim.system(cmd, { stdin = q, text = true, env = sys_env }, function(result)
    vim.schedule(function()
      if state.current_job ~= job then return end
      state.current_job = nil
      clear_global_cancel_keymap()
      local elapsed = (vim.uv.now() - state.spinner_start) / 1000
      stop_spinner()
      clear_flash()

      if not state.result_bufnr or not vim.api.nvim_buf_is_valid(state.result_bufnr) then return end

      if result.signal ~= 0 then
        set_cancelled_status(elapsed)
        return
      end

      if result.code ~= 0 then
        local err_lines = vim.split("-- dblite failed: " .. (result.stderr or ""), "\n", { plain = true })
        vim.bo[state.result_bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(state.result_bufnr, 0, -1, false, err_lines)
        vim.bo[state.result_bufnr].modifiable = false
        return
      end

      local ok, parsed = pcall(vim.json.decode, result.stdout)
      if not ok or type(parsed) ~= "table" then
        set_status("-- dblite: failed to parse JSON: " .. tostring(parsed))
        return
      end

      state.columns      = parsed.columns or {}
      state.rows         = parsed.rows    or {}
      state.widths       = compute_widths(state.rows, state.columns)
      state.page         = 1
      state.last_elapsed = elapsed
      state.raw_json     = result.stdout

      local max_hist = config.max_history or 20
      table.insert(state.history, {
        columns      = state.columns,
        rows         = state.rows,
        widths       = state.widths,
        raw_json     = state.raw_json,
        last_elapsed = state.last_elapsed,
        conn_name    = state.active_conn and state.active_conn.name or nil,
        query_text   = q,
      })
      if max_hist > 0 and #state.history > max_hist then
        table.remove(state.history, 1)
      end
      state.history_idx = #state.history

      render_page()
      if state.result_bufnr and #vim.fn.win_findbuf(state.result_bufnr) == 0 then
        vim.notify("dblite: results ready — toggle dbout to view", vim.log.levels.INFO)
      end
    end)
  end)
  state.current_job = job
  end -- do_run

  if #bind_names > 0 then
    local file_binds = flatten_binds(load_binds_file())
    local missing = vim.tbl_filter(
      function(n) return file_binds[n] == nil end, bind_names)
    if #missing > 0 then
      vim.notify(
        "dblite: missing bind params: " .. table.concat(missing, ", ")
        .. "\nAdd them to dblite.binds.json and re-run.",
        vim.log.levels.WARN)
      M.open_binds()
      return
    end
    do_run(apply_binds(query, file_binds))
  else
    do_run(query)
  end
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

  local default_port = conn.type == "sqlserver" and 1433 or 1521
  local db_label     = conn.type == "sqlserver" and "Database" or "Service"
  local db_current   = conn.type == "sqlserver" and conn.database or conn.service
  local db_val       = prompt(db_label, db_current or "")

  local updates = {
    name = prompt("Name", conn.name),
    host = prompt("Host", conn.host),
    port = tonumber(prompt("Port", conn.port or default_port)),
    user = prompt("User", conn.user),
  }
  if conn.type == "sqlserver" then
    updates.database = db_val
  else
    updates.service = db_val
  end
  local pw = vim.fn.inputsecret("Password (leave blank to keep): ")
  if pw ~= "" then updates.password = pw end

  local ok, result = pcall(connections.update, conn.id, updates)
  if not ok then
    vim.notify("\ndblite: " .. tostring(result), vim.log.levels.ERROR)
    return
  end
  if state.active_conn and state.active_conn.id == conn.id then
    state.active_conn = connections.get(conn.id)
    if state.active_conn then require("dblite.schema").prefetch(state.active_conn) end
  end
  vim.notify("\ndblite: updated '" .. (updates.name or conn.name) .. "'", vim.log.levels.INFO)
  panel.refresh()
end

panel.setup({
  get_state = function() return state end,
  on_edit   = function(name) edit_conn_by_name(name) end,
})

-- :DbliteAddConn — interactive; optionally accepts a URI as first argument
-- URI format: oracle://user[:pass]@host[:port]/service  OR  sqlserver://user[:pass]@host[:port]/database
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
    local uri_input = vim.fn.input("URI (oracle://... or sqlserver://...) or blank for manual: ")
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
    local type_s = vim.fn.input("Type [oracle/sqlserver]: ")
    type_s = type_s ~= "" and type_s or "oracle"
    if type_s ~= "oracle" and type_s ~= "sqlserver" then
      vim.notify("\ndblite: type must be 'oracle' or 'sqlserver'", vim.log.levels.ERROR)
      return
    end
    local default_port = type_s == "sqlserver" and "1433" or "1521"
    local host = vim.fn.input("Host: ")
    if host == "" then return end
    local port_s   = vim.fn.input("Port [" .. default_port .. "]: ")
    local db_label = type_s == "sqlserver" and "Database" or "Service"
    local db_val   = vim.fn.input(db_label .. ": ")
    if db_val == "" then return end
    local user     = vim.fn.input("User: ")
    if user == "" then return end
    local password = vim.fn.inputsecret("Password (or $ENV_VAR): ")
    fields = {
      type     = type_s,
      host     = host,
      port     = tonumber(port_s ~= "" and port_s or default_port),
      user     = user,
      password = password,
    }
    if type_s == "sqlserver" then
      fields.database = db_val
    else
      fields.service = db_val
    end
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
    local active  = (state.active_conn and state.active_conn.id == c.id) and " *" or ""
    local db_val  = (c.type == "sqlserver") and c.database or c.service
    local default_port = (c.type == "sqlserver") and 1433 or 1521
    table.insert(lines, string.format(
      "  %-20s  [%-10s]  %s@%s:%d/%s%s",
      c.name, c.type or "oracle", c.user, c.host, c.port or default_port, db_val or "?", active
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
  require("dblite.schema").prefetch(conn)
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
    apply_dbout_win_style(0)
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

function M.inspect(format)
  format = format or config.inspect_format or "json"

  local page_size = config.page_size or 100
  local start_row = (state.page - 1) * page_size + 1
  local end_row   = math.min(start_row + page_size - 1, #state.rows)
  local page_rows = {}
  for i = start_row, end_row do
    table.insert(page_rows, state.rows[i])
  end

  local lines = {}

  if format == "json" then
    if not state.raw_json then
      vim.notify("dblite: no query result to inspect", vim.log.levels.WARN)
      return
    end
    local ok, decoded = pcall(vim.json.decode, state.raw_json)
    if not ok then
      vim.notify("dblite: could not parse stored JSON", vim.log.levels.ERROR)
      return
    end
    local page_data = { columns = decoded.columns, rows = page_rows }
    local encoded   = vim.json.encode(page_data) or ""
    local pretty_ok = false
    pcall(function()
      local r = vim.system({ "jq", "." }, { stdin = encoded }):wait()
      if r.code == 0 and r.stdout and #r.stdout > 0 then
        lines     = vim.split(r.stdout, "\n", { plain = true })
        pretty_ok = true
      end
    end)
    if not pretty_ok then
      lines = vim.split(encoded, "\n", { plain = true })
    end

  elseif format == "table" then
    if #state.columns == 0 then
      vim.notify("dblite: no query result to inspect", vim.log.levels.WARN)
      return
    end
    local widths = {}
    for _, col in ipairs(state.columns) do widths[col] = #tostring(col) end
    for _, row in ipairs(page_rows) do
      for _, col in ipairs(state.columns) do
        local s = (row[col] == nil or row[col] == vim.NIL) and "" or tostring(row[col])
        if #s > widths[col] then widths[col] = #s end
      end
    end
    local function pad(val, w)
      local s = (val == nil or val == vim.NIL) and "" or tostring(val)
      return s .. string.rep(" ", w - #s)
    end
    local headers, seps = {}, {}
    for _, col in ipairs(state.columns) do
      table.insert(headers, pad(col, widths[col]))
      table.insert(seps,    string.rep("-", widths[col]))
    end
    table.insert(lines, table.concat(headers, " | "))
    table.insert(lines, table.concat(seps,    "-+-"))
    for _, row in ipairs(page_rows) do
      local parts = {}
      for _, col in ipairs(state.columns) do
        table.insert(parts, pad(row[col], widths[col]))
      end
      table.insert(lines, table.concat(parts, " | "))
    end

  elseif format == "csv" then
    if #state.columns == 0 then
      vim.notify("dblite: no query result to inspect", vim.log.levels.WARN)
      return
    end
    local function csv_escape(val)
      local s = (val == nil or val == vim.NIL) and "" or tostring(val)
      if s:find('[,"\n\r]') then s = '"' .. s:gsub('"', '""') .. '"' end
      return s
    end
    table.insert(lines, table.concat(vim.tbl_map(csv_escape, state.columns), ","))
    for _, row in ipairs(page_rows) do
      local parts = {}
      for _, col in ipairs(state.columns) do table.insert(parts, csv_escape(row[col])) end
      table.insert(lines, table.concat(parts, ","))
    end

  else
    vim.notify("dblite: unknown inspect format '" .. format .. "' (json|table|csv)", vim.log.levels.ERROR)
    return
  end

  local view     = config.json_view or "tab"
  local filetype = format == "json" and "json" or format == "csv" and "csv" or ""
  local bufnr, winnr

  if view == "float" then
    local width  = math.floor(vim.o.columns * 0.85)
    local height = math.floor(vim.o.lines   * 0.80)
    local frow   = math.floor((vim.o.lines   - height) / 2)
    local fcol   = math.floor((vim.o.columns - width)  / 2)
    bufnr = vim.api.nvim_create_buf(false, true)
    winnr = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor", style = "minimal", border = "rounded",
      width = width, height = height, row = frow, col = fcol,
    })
    vim.keymap.set("n", "q", function() vim.api.nvim_win_close(winnr, true) end,
      { buffer = bufnr, silent = true })
  else
    local cmds = { tab = "tabnew", vertical = "botright vnew", horizontal = "botright new" }
    vim.cmd(cmds[view] or "tabnew")
    bufnr = vim.api.nvim_get_current_buf()
    winnr = vim.api.nvim_get_current_win()
    vim.keymap.set("n", "q", "<cmd>bd<cr>", { buffer = bufnr, silent = true })
  end

  vim.bo[bufnr].buftype   = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile  = false
  vim.bo[bufnr].filetype  = filetype
  vim.wo[winnr].wrap          = false
  vim.wo[winnr].linebreak     = false
  vim.wo[winnr].number        = false
  vim.wo[winnr].sidescrolloff = 3
  vim.bo[bufnr].synmaxcol     = 500

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

local _binds_win = nil

local function ensure_binds_file()
  local path = binds_file_path()
  if vim.fn.filereadable(path) == 0 then
    vim.fn.writefile({ "{", "}" }, path)
    vim.notify("dblite: created " .. path, vim.log.levels.INFO)
  end
  return path
end

local function open_binds_split()
  local path = ensure_binds_file()
  local split_cfg = config.binds_split or {}

  if split_cfg.style == "float" then
    local w = split_cfg.float_width  or 0
    local h = split_cfg.float_height or 0
    if w == 0 then w = math.floor(vim.o.columns * 0.7) end
    if h == 0 then h = math.floor(vim.o.lines   * 0.6) end
    local row = math.floor((vim.o.lines   - h) / 2)
    local col = math.floor((vim.o.columns - w) / 2)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    local winnr = vim.api.nvim_open_win(bufnr, true, {
      relative  = "editor",
      border    = "rounded",
      title     = " dblite.binds.json ",
      title_pos = "center",
      width     = w,
      height    = h,
      row       = row,
      col       = col,
    })
    vim.bo[bufnr].filetype = "json"
    _binds_win = winnr
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern  = tostring(winnr),
      once     = true,
      callback = function() _binds_win = nil end,
    })
    return
  end

  local dir  = split_cfg.split_dir or "vertical"
  local size = ""
  if dir == "vertical" then
    local w = split_cfg.width or 40
    if w > 0 then size = tostring(w) end
    vim.cmd(size .. "vsplit " .. vim.fn.fnameescape(path))
  else
    local h = split_cfg.height or 20
    if h > 0 then size = tostring(h) end
    vim.cmd(size .. "split " .. vim.fn.fnameescape(path))
  end
  _binds_win = vim.api.nvim_get_current_win()
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(_binds_win),
    once     = true,
    callback = function() _binds_win = nil end,
  })
end

function M.open_binds()
  if _binds_win and vim.api.nvim_win_is_valid(_binds_win) then
    vim.api.nvim_set_current_win(_binds_win)
  else
    open_binds_split()
  end
end

function M.toggle_binds()
  if _binds_win and vim.api.nvim_win_is_valid(_binds_win) then
    vim.api.nvim_win_close(_binds_win, false)
    _binds_win = nil
  else
    open_binds_split()
  end
end

M.open_binds_file = M.toggle_binds
M.edit_binds      = M.toggle_binds

function M.edit_connections_file()
  local path = vim.fn.stdpath("data") .. "/dblite/connections.json"
  if vim.fn.filereadable(path) ~= 1 then
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = io.open(path, "w")
    if f then f:write("[]") f:close() end
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer   = vim.api.nvim_get_current_buf(),
    once     = true,
    callback = function()
      panel.refresh()
      if state.active_conn then
        local updated = connections.get(state.active_conn.id)
        if updated then
          state.active_conn = updated
          require("dblite.schema").prefetch(updated)
        end
      end
    end,
  })
end

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
      elseif sub == "file" then M.edit_connections_file()
      else vim.notify("dblite: conn what? (add | list | use | edit | del | file)", vim.log.levels.ERROR) end
    end,
    build         = function() vim.cmd("DbliteBuild") end,
    inspect       = function(a) M.inspect(a[2]) end,
    binds         = function() M.edit_binds() end,
  }

  local function complete(arg_lead, cmd_line)
    local tokens = vim.split(cmd_line, "%s+")
    local n = #tokens
    if n == 2 then
      return vim.tbl_filter(function(k) return k:sub(1, #arg_lead) == arg_lead end,
        { "run", "toggle", "conn", "build", "inspect", "binds" })
    elseif n == 3 then
      local sub = tokens[2]
      local opts = {
        run     = { "at" },
        toggle  = { "panel", "dbout" },
        conn    = { "add", "list", "use", "edit", "del", "file" },
        inspect = { "json", "table", "csv" },
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

function M.get_active_conn()
  return state.active_conn
end

function M.get_flat_binds()
  return flatten_binds(load_binds_file())
end

return M
