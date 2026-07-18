-- Background (async) bulk-export jobs + their side panel.
--
-- A "job" is a long-running query whose result set is streamed straight to a
-- file by the native binary (`--to-file`). Jobs run detached from the main
-- dblite result buffer so the user can keep running normal queries while a big
-- dump churns in the background. This module owns the job registry and the
-- panel that visualises it (spinner + elapsed seconds while running, a ✓/✗ when
-- done, auto-removed after `config.jobs.cleanup_delay` seconds).
local config = require("dblite.config")

local M = {}

local ns = vim.api.nvim_create_namespace("dblite_jobs_panel")

vim.api.nvim_set_hl(0, "DbliteJobsTitle",     { link = "Title",           default = true })
vim.api.nvim_set_hl(0, "DbliteJobsSep",       { link = "Comment",         default = true })
vim.api.nvim_set_hl(0, "DbliteJobsRunning",   { link = "Function",        default = true })
vim.api.nvim_set_hl(0, "DbliteJobsDone",      { link = "String",          default = true })
vim.api.nvim_set_hl(0, "DbliteJobsError",     { link = "DiagnosticError", default = true })
vim.api.nvim_set_hl(0, "DbliteJobsCancelled", { link = "WarningMsg",      default = true })
vim.api.nvim_set_hl(0, "DbliteJobsMeta",      { link = "Comment",         default = true })

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local ICON = { done = "✓", error = "✗", cancelled = "⊘" }

local jobs    = {}   -- list of job records (see M.register)
local next_id = 1

local state = {
  bufnr      = nil,
  winnr      = nil,
  line_map   = {},   -- panel line (1-based) → job id
  prev_winnr = nil,
  timer      = nil,  -- repeating render timer (runs only while panel is open)
  spin_idx   = 1,
}

-- --- Registry -------------------------------------------------------------

local function job_by_id(id)
  for _, j in ipairs(jobs) do
    if j.id == id then return j end
  end
end

-- Register a new running job. `rec` supplies: label, path, format, conn_name,
-- query. Returns the job id used by set_handle / finish.
function M.register(rec)
  rec.id     = next_id
  next_id    = next_id + 1
  rec.status = "running"
  rec.start  = vim.uv.now()
  table.insert(jobs, rec)
  M.refresh()
  return rec.id
end

function M.set_handle(id, handle)
  local j = job_by_id(id)
  if j then j.handle = handle end
end

-- Mark a job finished (status = "done" | "error" | "cancelled") and merge any
-- extra fields (rows, error). Schedules auto-removal from the panel.
function M.finish(id, fields)
  local j = job_by_id(id)
  if not j then return end
  for k, v in pairs(fields or {}) do j[k] = v end
  j.finish  = vim.uv.now()
  j.handle  = nil
  local delay = config.jobs and config.jobs.cleanup_delay or 300
  if delay and delay > 0 then
    j.cleanup = vim.defer_fn(function()
      M.remove(id)
    end, delay * 1000)
  end
  M.refresh()
end

-- Remove a job from the registry (and cancel its pending cleanup timer).
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

local function first_line(s)
  return (vim.split(tostring(s or ""), "\n", { plain = true })[1] or ""):gsub("%s+$", "")
end

local function elapsed_secs(j)
  local finish = j.finish or vim.uv.now()
  return (finish - j.start) / 1000
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

  if #jobs == 0 then
    table.insert(lines, "  (no background jobs)")
    table.insert(hls, { row = 2, col = 0, ecol = #lines[3], group = "DbliteJobsMeta" })
    return lines, line_map, hls
  end

  for _, j in ipairs(jobs) do
    local icon, status_hl, meta
    local secs = elapsed_secs(j)
    if j.status == "running" then
      icon      = SPINNER[state.spin_idx]
      status_hl = "DbliteJobsRunning"
      meta      = string.format("%ds", math.floor(secs))
    elseif j.status == "done" then
      icon      = ICON.done
      status_hl = "DbliteJobsDone"
      meta      = string.format("%.1fs · %s rows", secs, j.rows ~= nil and tostring(j.rows) or "?")
    elseif j.status == "error" then
      icon      = ICON.error
      status_hl = "DbliteJobsError"
      meta      = string.format("%.1fs · %s", secs, first_line(j.error))
    else -- cancelled
      icon      = ICON.cancelled
      status_hl = "DbliteJobsCancelled"
      meta      = string.format("%.1fs · cancelled", secs)
    end

    local prefix  = "  "
    local mid     = "  "
    local labelf  = trunc(j.label or j.path or "?", 20)
    local pad     = string.rep(" ", math.max(1, 21 - vim.fn.strdisplaywidth(labelf)))
    local line    = prefix .. icon .. mid .. labelf .. pad .. meta

    table.insert(lines, line)
    local row = #lines - 1
    line_map[#lines] = j.id

    local icon_col = #prefix
    local meta_col = #prefix + #icon + #mid + #labelf + #pad
    table.insert(hls, { row = row, col = icon_col, ecol = icon_col + #icon, group = status_hl })
    table.insert(hls, { row = row, col = meta_col, ecol = meta_col + #meta, group = "DbliteJobsMeta" })
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

local function start_timer()
  if state.timer then return end
  local timer = vim.uv.new_timer()
  timer:start(0, 120, vim.schedule_wrap(function()
    if not state.winnr or not vim.api.nvim_win_is_valid(state.winnr) then return end
    state.spin_idx = (state.spin_idx % #SPINNER) + 1
    render()
  end))
  state.timer = timer
end

local function stop_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

local function job_at_cursor()
  if not state.winnr or not vim.api.nvim_win_is_valid(state.winnr) then return nil end
  local row = vim.api.nvim_win_get_cursor(state.winnr)[1]
  local id  = state.line_map[row]
  return id and job_by_id(id)
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
    vim.cmd("tabedit " .. vim.fn.fnameescape(j.path))
  end, "dblite: open job output")

  map(km.cancel or "x", function()
    local j = job_at_cursor()
    if not j then return end
    if j.status == "running" then
      if j.handle then pcall(function() j.handle:kill(15) end) end
      vim.notify("dblite: cancelling job → " .. (j.path or ""), vim.log.levels.INFO)
    else
      M.remove(j.id)
    end
  end, "dblite: cancel / dismiss job")

  map(km.close or "q", function() M.close() end, "dblite: close jobs panel")
end

-- Open the panel. opts.focus = false leaves the cursor in the previous window
-- (used when auto-opening on job start so we don't steal focus from the editor).
function M.open(opts)
  opts = opts or {}
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

  local width = (config.jobs and config.jobs.panel and config.jobs.panel.width) or 46
  vim.cmd("botright " .. width .. "vsplit")
  local winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winnr, state.bufnr)
  state.winnr = winnr

  vim.wo[winnr].number         = false
  vim.wo[winnr].relativenumber = false
  vim.wo[winnr].signcolumn     = "no"
  vim.wo[winnr].wrap           = false
  vim.wo[winnr].cursorline     = true
  vim.wo[winnr].winfixwidth    = true

  render()
  start_timer()

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(winnr),
    once     = true,
    callback = function()
      state.winnr = nil
      stop_timer()
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
  stop_timer()
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
