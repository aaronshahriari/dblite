-- Background (async) bulk-export jobs + their side panel.
--
-- A "job" is a long-running query whose result set is streamed straight to a
-- file by the native binary (`--to-file`). Jobs run detached from the main
-- dblite result buffer so the user can keep running normal queries while a big
-- dump churns in the background. This module owns the job registry and the
-- panel that visualises it (status, file name, duration, and row count).
local config = require("dblite.config")

local M = {}

local ns = vim.api.nvim_create_namespace("dblite_jobs_panel")

vim.api.nvim_set_hl(0, "DbliteJobsTitle",     { link = "Title",           default = true })
vim.api.nvim_set_hl(0, "DbliteJobsSep",       { link = "Comment",         default = true })
vim.api.nvim_set_hl(0, "DbliteJobsSection",   { link = "Type",            default = true })
vim.api.nvim_set_hl(0, "DbliteJobsRunning",   { link = "Function",        default = true })
vim.api.nvim_set_hl(0, "DbliteJobsDone",      { link = "String",          default = true })
vim.api.nvim_set_hl(0, "DbliteJobsError",     { link = "DiagnosticError", default = true })
vim.api.nvim_set_hl(0, "DbliteJobsCancelled", { link = "WarningMsg",      default = true })
vim.api.nvim_set_hl(0, "DbliteJobsMeta",      { link = "Comment",         default = true })

local ICON = { running = "…", done = "✓", error = "✗", cancelled = "✗" }

local jobs = {}   -- live job records for THIS instance (running + pending cleanup)

-- Globally-unique job id: time + pid + counter, so entries from concurrent
-- Neovim instances never collide when merged into the shared history file.
local pid         = vim.fn.getpid()
local id_counter  = 0
local function new_id()
  id_counter = id_counter + 1
  return string.format("%d-%d-%d", os.time(), pid, id_counter)
end

local state = {
  bufnr      = nil,
  winnr      = nil,
  line_map   = {},   -- panel line (1-based) → job id
  prev_winnr = nil,
}

-- --- Persistent history ---------------------------------------------------
-- Terminal jobs (done/error/cancelled) are appended to a shared JSON file so
-- history survives restarts and is visible across all Neovim instances. Only
-- terminal jobs are persisted — running jobs live in the owning instance's
-- memory, so a killed instance never leaves a stuck "running" ghost.

local history_cache = {}  -- past terminal jobs, newest-first (in-memory mirror)

local function history_cfg()
  return (config.jobs and config.jobs.history) or {}
end

local function history_enabled()
  return history_cfg().enabled ~= false  -- default on
end

local function history_path()
  return history_cfg().file or (vim.fn.stdpath("data") .. "/dblite/jobs.json")
end

local function read_history_file()
  local f = io.open(history_path(), "r")
  if not f then return {} end
  local raw = f:read("*a"); f:close()
  local ok, data = pcall(vim.json.decode, raw or "")
  return (ok and type(data) == "table" and vim.islist(data)) and data or {}
end

local function write_history_file(list)
  local p = history_path()
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  local tmp = p .. ".tmp." .. pid
  local f = io.open(tmp, "wb")
  if not f then return end
  local ok = pcall(function() f:write(vim.json.encode(list)) end)
  f:close()
  if ok then os.rename(tmp, p) else os.remove(tmp) end
end

local function newest_first(list)
  table.sort(list, function(a, b) return (a.finished_at or 0) > (b.finished_at or 0) end)
  return list
end

-- The persisted shape of a job (runtime-only fields like handle/timers dropped).
local function to_record(j)
  return {
    id        = j.id,        label     = j.label,   path    = j.path,
    format    = j.format,    conn_name = j.conn_name, query = j.query,
    status    = j.status,    started_at = j.started_at, finished_at = j.finished_at,
    duration  = j.duration,  rows      = j.rows,    error   = j.error,
  }
end

-- Read → merge this job by id → sort → trim to max_entries → atomic write.
local function persist(j)
  if not history_enabled() then return end
  local list = read_history_file()
  local replaced = false
  for i, e in ipairs(list) do
    if e.id == j.id then list[i] = to_record(j); replaced = true; break end
  end
  if not replaced then table.insert(list, to_record(j)) end
  newest_first(list)
  local cap = history_cfg().max_entries or 200
  if cap > 0 and #list > cap then
    for i = #list, cap + 1, -1 do table.remove(list, i) end
  end
  write_history_file(list)
  history_cache = list
end

-- Refresh the in-memory mirror from disk (called on panel open + after writes).
local function load_history()
  history_cache = history_enabled() and newest_first(read_history_file()) or {}
end

-- --- Registry -------------------------------------------------------------

local function job_by_id(id)
  for _, j in ipairs(jobs) do
    if j.id == id then return j end
  end
end

-- Find a displayed entry (live job or history record) by id.
local function entry_by_id(id)
  local j = job_by_id(id)
  if j then return j end
  for _, e in ipairs(history_cache) do
    if e.id == id then return e end
  end
end

-- Register a new running job. `rec` supplies: label, path, format, conn_name,
-- query. Returns the job id used by set_handle / finish.
function M.register(rec)
  rec.id         = new_id()
  rec.status     = "running"
  rec.start      = vim.uv.now()  -- monotonic; live elapsed only (not persisted)
  rec.started_at = os.time()     -- wall clock; persisted
  table.insert(jobs, rec)
  M.refresh()
  return rec.id
end

function M.set_handle(id, handle)
  local j = job_by_id(id)
  if j then j.handle = handle end
end

-- Mark a job finished (status = "done" | "error" | "cancelled") and merge any
-- extra fields (rows, error). Persists it to history and schedules removal of
-- the live copy after cleanup_delay (it stays visible via history afterwards).
function M.finish(id, fields)
  local j = job_by_id(id)
  if not j then return end
  for k, v in pairs(fields or {}) do j[k] = v end
  j.finished_at = os.time()
  j.duration    = j.start and (vim.uv.now() - j.start) / 1000 or 0
  j.handle      = nil
  persist(j)
  local delay = config.jobs and config.jobs.cleanup_delay or 300
  if delay and delay > 0 then
    j.cleanup = vim.defer_fn(function() M.remove(id) end, delay * 1000)
  end
  M.refresh()
end

-- Remove a job from the live registry (and cancel its pending cleanup timer).
-- Does not touch history — see M.forget.
function M.remove(id)
  for i, j in ipairs(jobs) do
    if j.id == id then
      if j.cleanup then pcall(function() j.cleanup:stop(); j.cleanup:close() end) end
      table.remove(jobs, i)
      break
    end
  end
  M.refresh()
end

-- Permanently delete a job from the shared history file.
function M.forget(id)
  if not history_enabled() then return end
  local list = read_history_file()
  local changed = false
  for i = #list, 1, -1 do
    if list[i].id == id then table.remove(list, i); changed = true end
  end
  if changed then write_history_file(list) end
  history_cache = newest_first(list)
  M.refresh()
end

function M.has_running()
  for _, j in ipairs(jobs) do
    if j.status == "running" then return true end
  end
  return false
end

-- --- Rendering ------------------------------------------------------------

local function trunc(s, n)
  if vim.fn.strchars(s) <= n then return s end
  return vim.fn.strcharpart(s, 0, n - 1) .. "…"
end

local function format_duration(j)
  if j.status == "running" then return "running" end
  if not j.duration then return "?s" end
  return string.format("%.1fs", j.duration)
end

local function format_rows(rows)
  return (rows ~= nil and tostring(rows) or "?") .. " rows"
end

local function file_name(j)
  local name = j.label or j.path or "?"
  return name == "?" and name or vim.fn.fnamemodify(name, ":t")
end

local function confirm(prompt)
  return vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1
end

local function id_counter(id)
  return tonumber(tostring(id or ""):match("%-(%d+)$")) or 0
end

local function newer_running_first(a, b)
  local ast, bst = a.started_at or 0, b.started_at or 0
  if ast ~= bst then return ast > bst end
  local am, bm = a.start or 0, b.start or 0
  if am ~= bm then return am > bm end
  return id_counter(a.id) > id_counter(b.id)
end

local function newer_history_first(a, b)
  local aft, bft = a.finished_at or 0, b.finished_at or 0
  if aft ~= bft then return aft > bft end
  local ast, bst = a.started_at or 0, b.started_at or 0
  if ast ~= bst then return ast > bst end
  return id_counter(a.id) > id_counter(b.id)
end

-- Running jobs and terminal history are rendered separately. Terminal live jobs
-- are included in history until cleanup removes the live copy, so recently
-- finished jobs stay in the right chronological position.
local function display_groups()
  local running, history, seen_history = {}, {}, {}

  for _, j in ipairs(jobs) do
    if j.status == "running" then
      running[#running + 1] = j
    else
      history[#history + 1] = j
      seen_history[j.id] = true
    end
  end

  local show = history_cfg().show or 20
  for _, e in ipairs(history_cache) do
    if not seen_history[e.id] then
      history[#history + 1] = e
    end
  end

  table.sort(running, newer_running_first)
  table.sort(history, newer_history_first)
  if show > 0 and #history > show then
    for i = #history, show + 1, -1 do table.remove(history, i) end
  end

  return running, history
end

local function append_section(lines, hls, title)
  if #lines > 2 then table.insert(lines, "") end
  table.insert(lines, "  " .. title)
  table.insert(hls, { row = #lines - 1, col = 2, ecol = #lines[#lines], group = "DbliteJobsSection" })
end

local function append_job(lines, line_map, hls, width, j)
  local icon, status_hl, meta
  if j.status == "running" then
    icon      = ICON.running
    status_hl = "DbliteJobsRunning"
    meta      = format_duration(j) .. " · " .. format_rows(j.rows)
  else
    if j.status == "done" then
      icon      = ICON.done
      status_hl = "DbliteJobsDone"
    elseif j.status == "error" then
      icon      = ICON.error
      status_hl = "DbliteJobsError"
    else -- cancelled
      icon      = ICON.cancelled
      status_hl = "DbliteJobsCancelled"
    end
    meta = format_duration(j) .. " · " .. format_rows(j.rows)
  end

  local prefix  = "  "
  local mid     = "  "
  local label_width = math.max(8, width - 8 - vim.fn.strdisplaywidth(meta))
  local labelf  = trunc(file_name(j), label_width)
  local pad     = string.rep(" ", math.max(1, label_width + 1 - vim.fn.strdisplaywidth(labelf)))
  local line    = prefix .. icon .. mid .. labelf .. pad .. meta

  table.insert(lines, line)
  local row = #lines - 1
  line_map[#lines] = j.id

  local icon_col = #prefix
  local meta_col = #prefix + #icon + #mid + #labelf + #pad
  table.insert(hls, { row = row, col = icon_col, ecol = icon_col + #icon, group = status_hl })
  table.insert(hls, { row = row, col = meta_col, ecol = meta_col + #meta, group = "DbliteJobsMeta" })
end

local function build_lines()
  local width     = (config.jobs and config.jobs.panel and config.jobs.panel.width) or 46
  local sep_width = width - 2

  local lines    = { "Background Jobs", string.rep("─", sep_width) }
  local line_map = {}
  local hls      = {
    { row = 0, col = 0, ecol = #lines[1], group = "DbliteJobsTitle" },
    { row = 1, col = 0, ecol = #lines[2], group = "DbliteJobsSep"   },
  }

  local running, history = display_groups()
  if #running == 0 and #history == 0 then
    table.insert(lines, "  (no background jobs)")
    table.insert(hls, { row = 2, col = 0, ecol = #lines[3], group = "DbliteJobsMeta" })
    return lines, line_map, hls
  end

  if #running > 0 then
    append_section(lines, hls, "Running")
    for _, j in ipairs(running) do append_job(lines, line_map, hls, width, j) end
  end

  if #history > 0 then
    append_section(lines, hls, "History")
    for _, j in ipairs(history) do append_job(lines, line_map, hls, width, j) end
  end

  return lines, line_map, hls
end

local function render()
  local bufnr = state.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  local lines, line_map, hls = build_lines()
  state.line_map = line_map

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, h.row, h.col, { end_col = h.ecol, hl_group = h.group })
  end
end

-- Public refresh: re-render only if the panel is currently open.
function M.refresh()
  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then render() end
end

-- --- Panel window ---------------------------------------------------------

local function job_at_cursor()
  if not state.winnr or not vim.api.nvim_win_is_valid(state.winnr) then return nil end
  local row = vim.api.nvim_win_get_cursor(state.winnr)[1]
  local id  = state.line_map[row]
  return id and entry_by_id(id)
end

local function setup_keymaps(bufnr)
  local km = (config.keymaps and config.keymaps.jobs) or {}

  local function map(lhs, fn, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, desc = desc })
    end
  end

  map(km.open or "<CR>", function()
    local j = job_at_cursor()
    if not j then return end
    if j.status == "running" then
      vim.notify("dblite: job still running — " .. (j.path or ""), vim.log.levels.INFO)
      return
    end
    if j.status ~= "done" then
      vim.notify("dblite: no output file (" .. j.status .. ")", vim.log.levels.WARN)
      return
    end
    if vim.fn.filereadable(j.path) ~= 1 then
      vim.notify("dblite: output file not found: " .. tostring(j.path), vim.log.levels.WARN)
      return
    end
    local target = state.prev_winnr
    if target and vim.api.nvim_win_is_valid(target) then
      vim.api.nvim_set_current_win(target)
    end
    if not (config.jobs and config.jobs.close_on_open == false) then
      M.close()
    end
    vim.cmd("tabedit " .. vim.fn.fnameescape(j.path))
  end, "dblite: open job output")

  local function cancel_or_delete()
    local j = job_at_cursor()
    if not j then return end
    if j.status == "running" then
      if not confirm("Cancel running job?\n\n" .. file_name(j)) then return end
      if j.handle then pcall(function() j.handle:kill(15) end) end
      vim.notify("dblite: cancelling job → " .. (j.path or ""), vim.log.levels.INFO)
    else
      if not confirm("Delete job from history?\n\n" .. file_name(j)) then return end
      M.remove(j.id)   -- drop the live copy (if any)
      M.forget(j.id)   -- and delete it from the shared history
    end
  end

  local cancel_lhs = km.cancel or "x"
  map(cancel_lhs, cancel_or_delete, "dblite: cancel / delete job")
  if cancel_lhs == "x" then
    map("X", cancel_or_delete, "dblite: cancel / delete job")
  end

  map(km.close or "q", function() M.close() end, "dblite: close jobs panel")

  -- Optional: same key you opened the panel with can close it from inside.
  -- Off by default (""); set to your open key's lhs for symmetry.
  map(km.toggle, function() M.toggle() end, "dblite: toggle jobs panel")
end

-- Open the panel. opts.focus = false leaves the cursor in the previous window
-- (used when auto-opening on job start so we don't steal focus from the editor).
-- When opts.focus is nil, fall back to `config.jobs.focus` (default true).
function M.open(opts)
  opts = opts or {}
  if opts.focus == nil then
    local jc = config.jobs
    opts.focus = not (jc and jc.focus == false)
  end
  local prev = vim.api.nvim_get_current_win()

  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
    if opts.focus == false then return end
    vim.api.nvim_set_current_win(state.winnr)
    return
  end

  state.prev_winnr = prev

  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype   = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile  = false
    state.bufnr = bufnr
    setup_keymaps(bufnr)
  end

  local panel_cfg = config.jobs and config.jobs.panel or {}
  local max_width = math.max(1, vim.o.columns - 4)
  local max_height = math.max(3, vim.o.lines - 4)
  local width = math.min(panel_cfg.width or 46, max_width)
  local height = math.min(panel_cfg.height or math.max(3, math.floor(vim.o.lines * 0.6)), max_height)
  local winnr = vim.api.nvim_open_win(state.bufnr, opts.focus ~= false, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = 1,
    col = math.max(0, vim.o.columns - width - 2),
  })
  state.winnr = winnr

  vim.wo[winnr].number         = false
  vim.wo[winnr].relativenumber = false
  vim.wo[winnr].signcolumn     = "no"
  vim.wo[winnr].wrap           = false
  vim.wo[winnr].cursorline     = true

  load_history()  -- pick up entries from past sessions / other instances
  render()

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(winnr),
    once     = true,
    callback = function()
      state.winnr = nil
    end,
  })

  if opts.focus == false and vim.api.nvim_win_is_valid(prev) then
    vim.api.nvim_set_current_win(prev)
  end
end

function M.close()
  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
    vim.api.nvim_win_close(state.winnr, true)
  end
  state.winnr = nil
  if state.prev_winnr and vim.api.nvim_win_is_valid(state.prev_winnr) then
    vim.api.nvim_set_current_win(state.prev_winnr)
  end
end

function M.toggle()
  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
    M.close()
  else
    M.open()
  end
end

function M.is_open()
  return state.winnr ~= nil and vim.api.nvim_win_is_valid(state.winnr)
end

return M
