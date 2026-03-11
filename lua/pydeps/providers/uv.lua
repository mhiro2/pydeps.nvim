---@class PyDepsUvResolveOptions
---@field root? string
---@field on_finish? fun(result: PyDepsUvResolveResult)

---@class PyDepsUvResolveResult
---@field ok boolean
---@field code integer
---@field reason? "missing_uv"|"spawn"|"timeout"|"exit"
---@field stderr? string

---@class PyDepsUvCommand
---@field cmd string[]
---@field cwd? string

local util = require("pydeps.util")

local M = {}

local uv = vim.uv

-- uv.lock timeout in milliseconds (5 minutes)
local UV_LOCK_TIMEOUT = 300000

-- Track whether we've notified about uv not being found
local uv_notified = false

---@param opts? { silent?: boolean }
---@return boolean
local function ensure_uv(opts)
  if vim.fn.executable("uv") == 1 then
    return true
  end
  if not (opts and opts.silent) and not uv_notified then
    vim.notify("pydeps: uv not found in PATH", vim.log.levels.ERROR)
    uv_notified = true
  end
  return false
end

---@param opts? PyDepsUvResolveOptions
---@return nil
function M.resolve(opts)
  opts = opts or {}

  if not ensure_uv({ silent = true }) then
    if opts.on_finish then
      opts.on_finish({
        ok = false,
        code = -1,
        reason = "missing_uv",
      })
    end
    return
  end

  local cwd = opts.root or nil
  local stderr = {}
  local completed = false
  local timer = nil

  ---@param result PyDepsUvResolveResult
  ---@return nil
  local function finish(result)
    if completed then
      return
    end
    completed = true
    util.safe_close_timer(timer)
    timer = nil

    if opts.on_finish then
      opts.on_finish(result)
    end
  end

  local job_id = vim.fn.jobstart({ "uv", "lock" }, {
    cwd = cwd,
    stderr_buffered = true,
    on_stderr = function(_, data)
      if data then
        stderr = data
      end
    end,
    on_exit = function(_, code, _)
      if code ~= 0 then
        local err_msg = table.concat(stderr or {}, "\n"):gsub("^%s*(.-)%s*$", "%1")
        finish({
          ok = false,
          code = code,
          reason = "exit",
          stderr = err_msg ~= "" and err_msg or nil,
        })
        return
      end
      finish({ ok = true, code = code })
    end,
  })

  if job_id <= 0 then
    finish({
      ok = false,
      code = -1,
      reason = "spawn",
    })
    return
  end

  -- Set up timeout timer
  timer = uv.new_timer()
  timer:start(UV_LOCK_TIMEOUT, 0, function()
    if completed then
      return
    end
    vim.schedule(function()
      vim.fn.jobstop(job_id)
    end)
    finish({
      ok = false,
      code = -1,
      reason = "timeout",
    })
  end)
end

-- Cached feature detection for uv tree flags
local tree_features = nil
local features_cached = false
local features_pending = false
---@type table<integer, fun(features: table<string, boolean>)>
local feature_callbacks = {}

---@private
---@param cb? fun(features: table<string, boolean>)
---@return nil
function M.detect_tree_features(cb)
  if features_cached then
    if cb then
      cb(tree_features or {})
    end
    return
  end

  if cb then
    table.insert(feature_callbacks, cb)
  end

  if features_pending then
    return
  end
  features_pending = true

  if not ensure_uv() then
    tree_features = {}
    features_cached = true
    features_pending = false
    vim.schedule(function()
      for _, callback in ipairs(feature_callbacks) do
        callback(tree_features)
      end
      feature_callbacks = {}
    end)
    return
  end

  vim.system({ "uv", "tree", "--help" }, { text = true }, function(result)
    local stdout = result and result.stdout or ""
    tree_features = {
      invert = stdout:match("%-%-invert") ~= nil,
      depth = stdout:match("%-%-depth") ~= nil,
      universal = stdout:match("%-%-universal") ~= nil,
      show_sizes = stdout:match("%-%-show%-sizes") ~= nil,
      all_groups = stdout:match("%-%-all%-groups") ~= nil,
      group = stdout:match("%-%-group") ~= nil,
      no_group = stdout:match("%-%-no%-group") ~= nil,
      package = stdout:match("%-%-package") ~= nil,
      frozen = stdout:match("%-%-frozen") ~= nil,
    }
    features_cached = true
    features_pending = false
    vim.schedule(function()
      for _, callback in ipairs(feature_callbacks) do
        callback(tree_features)
      end
      feature_callbacks = {}
    end)
  end)
end

---@param flag string
---@return boolean
function M.supports_tree_flag(flag)
  if not features_cached then
    M.detect_tree_features()
    return false
  end
  return tree_features and tree_features[flag] or false
end

---@return boolean
function M.tree_features_ready()
  return features_cached
end

---@private
---@clears the tree features cache (for testing)
---@return nil
function M._clear_tree_features_cache()
  tree_features = nil
  features_cached = false
  features_pending = false
  feature_callbacks = {}
  uv_notified = false
end

---@param opts { root: string, args: string[] }
---@return PyDepsUvCommand?
function M.tree_command(opts)
  if not ensure_uv({ silent = true }) then
    return nil
  end
  local cmd = { "uv" }
  vim.list_extend(cmd, opts.args or { "tree" })
  return {
    cmd = cmd,
    cwd = opts.root,
  }
end

return M
