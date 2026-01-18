---@class PyDepsUvOptions
---@field root? string
---@field on_exit? fun(code: integer)

local output = require("pydeps.ui.output")

local M = {}

local uv = vim.uv

-- uv.lock timeout in milliseconds (5 minutes)
local UV_LOCK_TIMEOUT = 300000

-- Track whether we've notified about uv not being found
local uv_notified = false

---@param timer uv_timer_t
---@return nil
local function safe_close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

---@return boolean
local function ensure_uv()
  if vim.fn.executable("uv") == 1 then
    return true
  end
  if not uv_notified then
    vim.notify("pydeps: uv not found in PATH", vim.log.levels.ERROR)
    uv_notified = true
  end
  return false
end

---@param opts? PyDepsUvOptions
---@return nil
function M.resolve(opts)
  if not ensure_uv() then
    return
  end
  local cwd = opts and opts.root or nil
  vim.notify("pydeps: running uv lock", vim.log.levels.INFO)
  local stderr = {}
  local completed = false

  local job_id = vim.fn.jobstart({ "uv", "lock" }, {
    cwd = cwd,
    stderr_buffered = true,
    on_stderr = function(_, data)
      if data then
        stderr = data
      end
    end,
    on_exit = function(_, code, _)
      if completed then
        return
      end
      completed = true

      if code ~= 0 then
        local err_msg = table.concat(stderr or {}, "\n"):gsub("^%s*(.-)%s*$", "%1")
        local msg = "pydeps: uv lock failed (exit code " .. code .. ")"
        if err_msg ~= "" then
          msg = msg .. "\n" .. err_msg
        end
        vim.notify(msg, vim.log.levels.ERROR)
        return
      end
      vim.notify("pydeps: uv lock succeeded", vim.log.levels.INFO)
      if opts and opts.on_exit then
        opts.on_exit(code)
      end
    end,
  })

  -- Set up timeout timer
  if job_id > 0 then
    local timer = uv.new_timer()
    timer:start(UV_LOCK_TIMEOUT, 0, function()
      safe_close_timer(timer)
      if not completed then
        completed = true
        vim.fn.jobstop(job_id)
        vim.notify("pydeps: uv lock timed out after 5 minutes", vim.log.levels.ERROR)
      end
    end)
  end
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

---@class PyDepsUvTreeOptions
---@field root string
---@field args string[]
---@field anchor? "center"|"cursor"|"hover"
---@field mode? "split"|"float"
---@field width? integer
---@field height? integer

---@param opts PyDepsUvTreeOptions
---@return nil
function M.tree(opts)
  if not ensure_uv() then
    return
  end

  local cmd = { "uv" }
  vim.list_extend(cmd, opts.args or { "tree" })

  local tree_ui = require("pydeps.ui.tree")

  -- For float mode without explicit width, use width_calc callback
  local width_calc = nil
  if opts.mode == "float" and not opts.width then
    width_calc = function(lines)
      return tree_ui.estimate_width(lines, opts.root, nil)
    end
  end

  output.run_command(cmd, {
    cwd = opts.root,
    title = "PyDeps Tree",
    anchor = opts.anchor,
    mode = opts.mode,
    width = opts.width,
    height = opts.height,
    width_calc = width_calc,
    on_show = function(buf, lines)
      tree_ui.setup_keymaps(buf, lines, { root = opts.root })
    end,
    on_close = function()
      -- Cleanup will be handled by BufWipeout autocmd in tree.lua if we add it
    end,
  })
end

return M
