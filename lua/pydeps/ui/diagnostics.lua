local config = require("pydeps.config")
local project = require("pydeps.core.project")
local env = require("pydeps.core.env")
local markers = require("pydeps.core.markers")

local ok_pypi, pypi = pcall(require, "pydeps.providers.pypi")

local M = {}

local ns = vim.api.nvim_create_namespace("pydeps")

-- Rate limiting for PyPI requests (max concurrent requests)
local MAX_CONCURRENT_REQUESTS = 5
---@type table<string, boolean>
local pending = {}
local rate_limit = require("pydeps.core.rate_limit")
local limiter = rate_limit.new(MAX_CONCURRENT_REQUESTS)

-- Debounce state to prevent recursive rendering (per-buffer)
---@type table<integer, {timer: uv_timer_t, pending: boolean}>
local debounce_state = {}

---@param bufnr integer
---@return uv_timer_t?, boolean?
local function get_debounce_state(bufnr)
  local state = debounce_state[bufnr]
  if state then
    return state.timer, state.pending
  end
  return nil, false
end

---@param bufnr integer
---@param timer uv_timer_t
---@param is_pending boolean
local function set_debounce_state(bufnr, timer, is_pending)
  debounce_state[bufnr] = { timer = timer, pending = is_pending }
end

---@param bufnr integer
local function clear_debounce_state(bufnr)
  local state = debounce_state[bufnr]
  if state then
    if state.timer then
      state.timer:stop()
      state.timer:close()
    end
    debounce_state[bufnr] = nil
  end
end

---@private
---@param bufnr integer
---@param deps table[]
---@param resolved table
---@param opts? table
local function schedule_render(bufnr, deps, resolved, opts)
  local _, is_pending = get_debounce_state(bufnr)
  if is_pending then
    return
  end

  -- Clear any existing timer for this buffer
  clear_debounce_state(bufnr)

  local timer = vim.uv.new_timer()
  set_debounce_state(bufnr, timer, true)

  timer:start(50, 0, function()
    timer:stop()
    timer:close()
    set_debounce_state(bufnr, nil, false)

    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.render(bufnr, deps, resolved, opts)
      end
    end)
  end)
end

---@param spec? string
---@return string?
local function extract_marker(spec)
  if not spec then
    return nil
  end
  return spec:match(";%s*(.+)$")
end

---@param spec? string
---@return string?
local function extract_exact_version(spec)
  if not spec then
    return nil
  end
  local without_marker = spec:match("^[^;]+") or spec
  local pinned = without_marker:match("===%s*([^,%s]+)") or without_marker:match("==%s*([^,%s]+)")
  if pinned then
    return pinned
  end
  return nil
end

---@param meta? PyDepsPyPIMeta
---@param version string
---@return boolean
local function is_version_in_releases(meta, version)
  if not meta or not meta.releases then
    return true
  end
  return meta.releases[version] ~= nil
end

---@param dep PyDepsDependency
---@return integer, integer, integer
local function diag_range(dep)
  local col_start = math.max((dep.col_start or 1) - 1, 0)
  local col_end = dep.col_end
  if not col_end or col_end <= col_start then
    col_end = col_start + 1
  end
  return dep.line - 1, col_start, col_end
end

---@param dep PyDepsDependency
---@param message string
---@param severity? integer
---@return table
local function make_diag(dep, message, severity)
  local lnum, col, end_col = diag_range(dep)
  return {
    lnum = lnum,
    col = col,
    end_col = end_col,
    severity = severity or vim.diagnostic.severity.WARN,
    source = "pydeps",
    message = message,
  }
end

---@param base? PyDepsEnv
---@param dep PyDepsDependency
---@return PyDepsEnv
local function with_extra_env(base, dep)
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

---@param bufnr integer
---@param deps? PyDepsDependency[]
---@param resolved? PyDepsResolved
---@param opts? PyDepsRenderOptions
---@return table[]
local function compute_diagnostics(bufnr, deps, resolved, opts)
  local root = project.find_root(bufnr)
  local current_env = env.get(root)
  local diagnostics = {}
  local lockfile_missing = opts and opts.lockfile_missing
  local lockfile_loading = opts and opts.lockfile_loading

  if lockfile_loading then
    return diagnostics
  end

  for _, dep in ipairs(deps or {}) do
    local resolved_version = resolved and resolved[dep.name] or nil
    local marker = extract_marker(dep.spec)
    local marker_result = markers.evaluate(marker, with_extra_env(current_env, dep))
    -- If result is nil (evaluation incomplete), treat as active (don't show diagnostic)
    local marker_active = marker_result ~= false
    local active = marker_active

    if marker and not marker_active and resolved_version then
      table.insert(
        diagnostics,
        make_diag(
          dep,
          "marker evaluates to false, but lockfile has a resolved version",
          config.options.diagnostic_severity.marker
        )
      )
    elseif marker and marker_active and not resolved_version and not lockfile_missing then
      table.insert(
        diagnostics,
        make_diag(
          dep,
          "marker evaluates to true, but lockfile is missing the package",
          config.options.diagnostic_severity.marker
        )
      )
    elseif not lockfile_missing and active and not resolved_version then
      table.insert(
        diagnostics,
        make_diag(dep, "declared in pyproject.toml but missing in uv.lock", config.options.diagnostic_severity.lock)
      )
    end

    local pinned = extract_exact_version(dep.spec)
    if pinned and resolved_version and pinned ~= resolved_version then
      table.insert(
        diagnostics,
        make_diag(
          dep,
          "lock mismatch: pinned " .. pinned .. " but resolved " .. resolved_version,
          config.options.diagnostic_severity.lock
        )
      )
    end

    if ok_pypi then
      local data = pypi.get_cached(dep.name)

      -- Check for pin not found (only for pinned specs)
      if pinned and data and not is_version_in_releases(data, pinned) then
        table.insert(
          diagnostics,
          make_diag(
            dep,
            "pinned version " .. pinned .. " not found on public PyPI",
            config.options.diagnostic_severity.lock
          )
        )
      end

      -- Check for yanked versions
      if resolved_version and data then
        local yanked = pypi.is_yanked(data, resolved_version)
        if yanked then
          table.insert(
            diagnostics,
            make_diag(dep, "resolved version is yanked on PyPI", config.options.diagnostic_severity.yanked)
          )
        end
      elseif not data and not pending[dep.name] then
        pending[dep.name] = true
        limiter:enqueue(function(done)
          pypi.get(dep.name, function()
            pending[dep.name] = nil
            done()
            schedule_render(bufnr, deps, resolved, opts)
          end)
        end)
      end
    end
  end

  return diagnostics
end

---@param bufnr integer
function M.clear(bufnr)
  clear_debounce_state(bufnr)
  vim.diagnostic.reset(ns, bufnr)
end

---@param bufnr integer
---@param deps? PyDepsDependency[]
---@param resolved? PyDepsResolved
---@param opts? PyDepsRenderOptions
function M.render(bufnr, deps, resolved, opts)
  if not config.options.enable_diagnostics then
    M.clear(bufnr)
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local diagnostics = compute_diagnostics(bufnr, deps, resolved, opts)
  vim.diagnostic.set(ns, bufnr, diagnostics, {
    underline = true,
    virtual_text = false,
    signs = true,
    update_in_insert = false,
  })
end

return M
