local config = require("pydeps.config")
local rate_limit = require("pydeps.core.rate_limit")

local M = {}

M.MAX_CONCURRENT_PYPI_REQUESTS = 5

---@class PyDepsDebounceState
---@field timer uv_timer_t?
---@field pending boolean

---@class PyDepsBufferDebouncer
---@field clear fun(bufnr: integer)
---@field schedule fun(bufnr: integer, callback: fun())

---Create a per-buffer debouncer that coalesces quick successive render requests.
---@param delay_ms? integer
---@return PyDepsBufferDebouncer
function M.new_buffer_debouncer(delay_ms)
  local wait = delay_ms or 50
  ---@type table<integer, PyDepsDebounceState>
  local debounce_state = {}

  ---@param bufnr integer
  local function clear(bufnr)
    local state = debounce_state[bufnr]
    if not state then
      return
    end
    if state.timer then
      state.timer:stop()
      state.timer:close()
    end
    debounce_state[bufnr] = nil
  end

  ---@param bufnr integer
  ---@param callback fun()
  local function schedule(bufnr, callback)
    local state = debounce_state[bufnr]
    if state and state.pending then
      return
    end

    clear(bufnr)

    local timer = vim.uv.new_timer()
    debounce_state[bufnr] = { timer = timer, pending = true }
    timer:start(wait, 0, function()
      timer:stop()
      timer:close()
      debounce_state[bufnr] = nil

      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          callback()
        end
      end)
    end)
  end

  return {
    clear = clear,
    schedule = schedule,
  }
end

---@param spec? string
---@return string?
function M.extract_marker(spec)
  if not spec then
    return nil
  end
  return spec:match(";%s*(.+)$")
end

---@param base? PyDepsEnv
---@param dep PyDepsDependency
---@return PyDepsEnv
function M.with_extra_env(base, dep)
  local env_copy = vim.tbl_extend("force", {}, base or {})
  if dep.group then
    if dep.group:match("^optional:") then
      env_copy.extra = dep.group:sub(#"optional:" + 1)
    elseif dep.group:match("^group:") then
      local group_name = dep.group:sub(#"group:" + 1)
      env_copy.group = group_name
      env_copy.dependency_group = group_name
    end
  end
  return env_copy
end

---@param meta? PyDepsPyPIMeta
---@param version string
---@return boolean
function M.is_version_in_releases(meta, version)
  if not meta or not meta.releases then
    return true
  end
  return meta.releases[version] ~= nil
end

---@param kind string
---@return string
function M.icon_for(kind)
  local icons = (config.options.ui and config.options.ui.icons) or {}
  if icons.enabled == false then
    return (icons.fallback and icons.fallback[kind]) or ""
  end
  return icons[kind] or (icons.fallback and icons.fallback[kind]) or ""
end

---@param max_concurrent? integer
---@return PyDepsRateLimiter
function M.new_pypi_limiter(max_concurrent)
  return rate_limit.new(max_concurrent or M.MAX_CONCURRENT_PYPI_REQUESTS)
end

return M
