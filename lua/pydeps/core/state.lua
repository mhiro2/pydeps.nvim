local cache = require("pydeps.core.cache")
local config = require("pydeps.config")
local project = require("pydeps.core.project")
local diagnostics = require("pydeps.ui.diagnostics")
local info = require("pydeps.ui.info")
local virtual_text = require("pydeps.ui.virtual_text")
local uv = vim.uv

local M = {}

---@type integer?
local augroup_id = nil

---@type boolean
local enabled = true

---@type table<string, boolean>
local missing_lockfile_notified = {}

---@type table<integer, uv_timer_t>
local refresh_timers = {}

---@type table<integer, integer>
local refresh_ticks = {}

---@return integer
local function current_buf()
  return vim.api.nvim_get_current_buf()
end

---@param bufnr integer
---@return boolean
local function is_pyproject_buf(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name:match("pyproject%.toml$") ~= nil
end

---@param bufnr integer
---@return PyDepsDependency[]
local function parse_buffer_deps(bufnr)
  return cache.get_pyproject(bufnr)
end

---@param name string
local function refresh_buffers_with_dep(name)
  if not name or name == "" then
    M.refresh_all()
    return
  end
  local target = name:lower()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and is_pyproject_buf(bufnr) then
      for _, dep in ipairs(parse_buffer_deps(bufnr) or {}) do
        if dep.name == target then
          M.refresh(bufnr)
          break
        end
      end
    end
  end
end

local function clear_autocmds()
  if augroup_id then
    pcall(vim.api.nvim_del_augroup_by_id, augroup_id)
    augroup_id = nil
  end
end

---@param bufnr integer
local function clear_refresh_timer(bufnr)
  local timer = refresh_timers[bufnr]
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
    refresh_timers[bufnr] = nil
  end
  refresh_ticks[bufnr] = nil
end

local function clear_all_timers()
  for bufnr in pairs(refresh_timers) do
    clear_refresh_timer(bufnr)
  end
end

---@param bufnr integer
local function schedule_refresh(bufnr)
  if not is_pyproject_buf(bufnr) or not enabled then
    return
  end

  local debounce_ms = config.options.refresh_debounce_ms or 0
  if debounce_ms <= 0 then
    M.refresh(bufnr)
    return
  end

  -- Record current tick to detect if buffer changes during debounce
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  refresh_ticks[bufnr] = tick

  -- Get or create timer
  local timer = refresh_timers[bufnr]
  if not timer or timer:is_closing() then
    timer = uv.new_timer()
    refresh_timers[bufnr] = timer
  end

  -- Restart timer with debounce delay
  timer:stop()
  timer:start(debounce_ms, 0, function()
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      if refresh_ticks[bufnr] ~= tick then
        return
      end
      M.refresh(bufnr)
    end)
  end)
end

local function ensure_autocmds()
  if augroup_id then
    return
  end
  augroup_id = vim.api.nvim_create_augroup("PyDeps", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = augroup_id,
    pattern = "PyDepsPyPIUpdated",
    callback = function(args)
      local name = args and args.data and args.data.name or nil
      refresh_buffers_with_dep(name)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = augroup_id,
    pattern = "PyDepsEnvUpdated",
    callback = function()
      M.refresh_all()
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = augroup_id,
    pattern = "PyDepsLockfileUpdated",
    callback = function()
      M.refresh_all()
    end,
  })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = augroup_id,
    pattern = "pyproject.toml",
    callback = function(args)
      cache.invalidate_pyproject(args.buf)
      M.refresh(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup_id,
    pattern = "pyproject.toml",
    callback = function(args)
      schedule_refresh(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup_id,
    pattern = "pyproject.toml",
    callback = function(args)
      cache.invalidate_pyproject(args.buf)
      clear_refresh_timer(args.buf)
      virtual_text.clear_debounce_state(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufFilePost" }, {
    group = augroup_id,
    callback = function(args)
      require("pydeps.core.project").clear_cache(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = augroup_id,
    callback = function(args)
      require("pydeps.core.project").clear_cache(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup_id,
    pattern = "uv.lock",
    callback = function(args)
      local root = project.find_root(args.buf)
      if root then
        cache.invalidate_lockfile(root)
      end
      M.refresh_all()
    end,
  })
  -- CursorHold for hover info
  vim.api.nvim_create_autocmd("CursorHold", {
    group = augroup_id,
    pattern = "pyproject.toml",
    callback = function()
      if not enabled then
        return
      end
      info.show_at_cursor()
    end,
  })
  -- Close hover on CursorMoved or InsertEnter
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter" }, {
    group = augroup_id,
    pattern = "pyproject.toml",
    callback = function()
      info.close_hover()
    end,
  })
  -- Close hover on BufLeave (unless suppressed)
  vim.api.nvim_create_autocmd("BufLeave", {
    group = augroup_id,
    pattern = "pyproject.toml",
    callback = function()
      if info.should_close_hover() then
        info.close_hover()
      end
    end,
  })
end

---@param bufnr integer
function M.clear(bufnr)
  virtual_text.clear(bufnr)
  diagnostics.clear(bufnr)
end

function M.clear_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and is_pyproject_buf(bufnr) then
      M.clear(bufnr)
    end
  end
end

---@param root string
---@param missing boolean
local function handle_missing_lockfile(root, missing)
  if missing and config.options.notify_on_missing_lockfile then
    if not missing_lockfile_notified[root] then
      missing_lockfile_notified[root] = true
      vim.notify("pydeps: uv.lock not found", vim.log.levels.WARN)
    end
  elseif not missing then
    missing_lockfile_notified[root] = nil
  end
end

---@param bufnr? integer
function M.refresh(bufnr)
  bufnr = bufnr or current_buf()
  if not is_pyproject_buf(bufnr) then
    return
  end
  if not enabled then
    M.clear(bufnr)
    return
  end

  local root = project.find_root(bufnr)
  if not root then
    return
  end

  -- Get dependency data
  local deps = parse_buffer_deps(bufnr)
  local lock_data, missing_lockfile, lockfile_loading = cache.get_lockfile(root)
  local resolved = lock_data.resolved or {}

  -- Notify about missing lockfile (once per root)
  handle_missing_lockfile(root, missing_lockfile)

  -- Render UI
  virtual_text.render(bufnr, deps, resolved, {
    lockfile_missing = missing_lockfile,
    lockfile_loading = lockfile_loading,
  })
  diagnostics.render(bufnr, deps, resolved, {
    lockfile_missing = missing_lockfile,
    lockfile_loading = lockfile_loading,
  })
end

function M.refresh_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.refresh(bufnr)
    end
  end
end

function M.enable()
  if enabled then
    return
  end
  enabled = true
  if config.options.auto_refresh then
    ensure_autocmds()
  end
  M.refresh_all()
end

function M.disable()
  if not enabled then
    return
  end
  enabled = false
  clear_autocmds()
  clear_all_timers()
  missing_lockfile_notified = {}
  M.clear_all()
end

function M.toggle()
  if enabled then
    M.disable()
  else
    M.enable()
  end
end

function M.is_enabled()
  return enabled
end

function M.setup()
  enabled = true
  if config.options.auto_refresh then
    ensure_autocmds()
  end
  M.refresh_all()
end

return M
