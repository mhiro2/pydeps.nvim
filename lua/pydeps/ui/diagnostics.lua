local config = require("pydeps.config")
local project = require("pydeps.core.project")
local env = require("pydeps.core.env")
local ui_shared = require("pydeps.ui.shared")
local status = require("pydeps.ui.status")

local ok_pypi, pypi = pcall(require, "pydeps.providers.pypi")

local M = {}

local ns = vim.api.nvim_create_namespace("pydeps")

-- Rate limiting for PyPI requests (max concurrent requests)
local MAX_CONCURRENT_REQUESTS = ui_shared.MAX_CONCURRENT_PYPI_REQUESTS
---@type table<string, boolean>
local pending = {}
local limiter = ui_shared.new_pypi_limiter(MAX_CONCURRENT_REQUESTS)

local debouncer = ui_shared.new_buffer_debouncer(50)

---@private
---@param bufnr integer
---@param deps table[]
---@param resolved table
---@param opts? table
local function schedule_render(bufnr, deps, resolved, opts)
  debouncer.schedule(bufnr, function()
    M.render(bufnr, deps, resolved, opts)
  end)
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
    local marker = ui_shared.extract_marker(dep.spec)
    local marker_active = status.is_active(dep, current_env)
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

    local status_result = status.classify({
      active = active,
      spec = dep.spec,
      resolved = resolved_version,
    })
    if status_result.class == "lock_mismatch" and status_result.pinned_version then
      table.insert(
        diagnostics,
        make_diag(
          dep,
          "lock mismatch: pinned " .. status_result.pinned_version .. " but resolved " .. resolved_version,
          config.options.diagnostic_severity.lock
        )
      )
    end

    if ok_pypi then
      local data = pypi.get_cached(dep.name)
      local class_with_meta = status.classify({
        active = active,
        yanked = resolved_version and data and pypi.is_yanked(data, resolved_version) or false,
        spec = dep.spec,
        meta = data,
        resolved = resolved_version,
      })

      -- Check for pin not found (only for pinned specs)
      if class_with_meta.class == "pin_not_found" and class_with_meta.pinned_version then
        table.insert(
          diagnostics,
          make_diag(
            dep,
            "pinned version " .. class_with_meta.pinned_version .. " not found on public PyPI",
            config.options.diagnostic_severity.lock
          )
        )
      end

      -- Check for yanked versions
      if class_with_meta.class == "yanked" then
        table.insert(
          diagnostics,
          make_diag(dep, "resolved version is yanked on PyPI", config.options.diagnostic_severity.yanked)
        )
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
  debouncer.clear(bufnr)
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
