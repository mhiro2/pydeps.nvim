local config = require("pydeps.config")
local env = require("pydeps.core.env")
local ui_shared = require("pydeps.ui.shared")
local status = require("pydeps.ui.status")

local M = {}

---@class PyDepsDependencyView
---@field dep PyDepsDependency
---@field name string
---@field spec string
---@field group? string
---@field marker string?
---@field current_env PyDepsEnv
---@field resolved string?
---@field latest string?
---@field meta? PyDepsPyPIMeta
---@field pending? "searching"|"loading"
---@field missing_lockfile boolean
---@field missing_lockfile_text string
---@field lockfile_loading boolean
---@field unresolved boolean
---@field active boolean
---@field yanked boolean
---@field class? "ok"|"update"|"major"|"inactive"|"yanked"|"lock_mismatch"|"pin_not_found"|"searching"|"loading"|"unknown"
---@field pinned_version? string
---@field base_class? "ok"|"update"|"major"|"inactive"|"yanked"|"lock_mismatch"|"pin_not_found"|"searching"|"loading"|"unknown"
---@field base_pinned_version? string
---@field status_kind "ok"|"update"|"warn"|"error"|"inactive"|"unknown"
---@field status_text string
---@field status_icon string
---@field lock_status? string
---@field show_latest_warning boolean

---@class PyDepsDependencyViewOptions
---@field root? string
---@field current_env? PyDepsEnv
---@field resolved? PyDepsResolved
---@field resolved_version? string
---@field meta? PyDepsPyPIMeta
---@field pending? "searching"|"loading"
---@field lockfile_missing? boolean
---@field lockfile_loading? boolean
---@field yanked? boolean

---@return PyDepsPyPIMetaProvider?
local function get_pypi()
  local ok, provider = pcall(require, "pydeps.providers.pypi")
  if ok then
    return provider
  end
  return nil
end

---@param meta? PyDepsPyPIMeta
---@param pypi_provider? table
---@return string?
local function latest_from_meta(meta, pypi_provider)
  if not meta then
    return nil
  end
  if meta.info and meta.info.version then
    return meta.info.version
  end
  if pypi_provider and pypi_provider.sorted_versions then
    local versions = pypi_provider.sorted_versions(meta)
    return versions[1]
  end
  return nil
end

---@param class? string
---@param resolved? string
---@return "ok"|"update"|"warn"|"error"|"inactive"|"unknown", string, string, string?, boolean
local function summarize_status(class, resolved)
  if class == "inactive" then
    return "inactive", "inactive", ui_shared.icon_for("inactive"), nil, false
  end
  if class == "yanked" then
    return "error", "yanked", ui_shared.icon_for("yanked"), "(yanked)", false
  end
  if class == "pin_not_found" then
    return "error", "pin not found", ui_shared.icon_for("pin_not_found"), "(not on public PyPI)", false
  end
  if class == "lock_mismatch" then
    return "warn", "lock mismatch", ui_shared.icon_for("lock_mismatch"), "(lock mismatch)", false
  end
  if class == "update" or class == "major" then
    return "update", "update available", ui_shared.icon_for("update"), nil, true
  end
  if class == "searching" then
    return "unknown", config.options.ui.status_text.searching, ui_shared.icon_for("searching"), nil, false
  end
  if class == "loading" then
    return "unknown", config.options.ui.status_text.loading, ui_shared.icon_for("loading"), nil, false
  end
  if class == "unknown" or class == nil then
    return "unknown", "unknown", ui_shared.icon_for("unknown"), nil, false
  end
  return "ok", "active", ui_shared.icon_for("ok"), resolved and "(up-to-date)" or nil, false
end

---@param dep PyDepsDependency
---@param opts? PyDepsDependencyViewOptions
---@return PyDepsDependencyView
function M.build(dep, opts)
  opts = opts or {}
  local pypi_provider = get_pypi()

  local current_env = opts.current_env or env.get(opts.root)
  local resolved = opts.resolved_version
  if resolved == nil and opts.resolved then
    resolved = opts.resolved[dep.name]
  end

  local meta = opts.meta
  if meta == nil and pypi_provider and pypi_provider.get_cached then
    meta = pypi_provider.get_cached(dep.name)
  end

  local latest = latest_from_meta(meta, pypi_provider)
  local lockfile_missing = opts.lockfile_missing == true
  local lockfile_loading = opts.lockfile_loading == true
  local pending = opts.pending
  if pending == nil and lockfile_loading and resolved == nil then
    pending = "loading"
  end
  local unresolved = resolved == nil and meta ~= nil and not lockfile_missing and not lockfile_loading
  local marker = ui_shared.extract_marker(dep.spec)
  local active = status.is_active(dep, current_env)

  local yanked = opts.yanked
  if yanked == nil then
    yanked = resolved ~= nil
        and meta ~= nil
        and pypi_provider ~= nil
        and pypi_provider.is_yanked ~= nil
        and pypi_provider.is_yanked(meta, resolved)
      or false
  end

  local classified = status.classify({
    active = active,
    yanked = yanked,
    spec = dep.spec,
    meta = meta,
    missing_lockfile = lockfile_missing,
    unresolved = unresolved,
    pending = pending,
    latest = latest,
    resolved = resolved,
  })
  local base_classified = status.classify({
    active = active,
    spec = dep.spec,
    resolved = resolved,
  })

  local status_kind, status_text, status_icon, lock_status, show_latest_warning =
    summarize_status(classified.class, resolved)

  return {
    dep = dep,
    name = dep.name,
    spec = dep.spec,
    group = dep.group,
    marker = marker,
    current_env = current_env,
    resolved = resolved,
    latest = latest,
    meta = meta,
    pending = pending,
    missing_lockfile = lockfile_missing,
    missing_lockfile_text = config.options.missing_lockfile_virtual_text or "missing uv.lock",
    lockfile_loading = lockfile_loading,
    unresolved = unresolved,
    active = active,
    yanked = yanked,
    class = classified.class,
    pinned_version = classified.pinned_version,
    base_class = base_classified.class,
    base_pinned_version = base_classified.pinned_version,
    status_kind = status_kind,
    status_text = status_text,
    status_icon = status_icon,
    lock_status = lock_status,
    show_latest_warning = show_latest_warning,
  }
end

return M
