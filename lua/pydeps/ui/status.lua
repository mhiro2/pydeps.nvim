local markers = require("pydeps.core.markers")
local ui_shared = require("pydeps.ui.shared")

local M = {}

---@class PyDepsUiStatusContext
---@field active boolean?
---@field yanked boolean?
---@field spec string?
---@field meta? PyDepsPyPIMeta
---@field missing_lockfile boolean?
---@field unresolved boolean?
---@field pending? "searching"|"loading"
---@field latest? string
---@field resolved? string

---@class PyDepsUiStatusResult
---@field class? "ok"|"update"|"major"|"inactive"|"yanked"|"lock_mismatch"|"pin_not_found"|"searching"|"loading"|"unknown"
---@field pinned_version? string

---@param spec? string
---@return string?
function M.extract_pinned_version(spec)
  if not spec then
    return nil
  end
  local without_marker = spec:match("^[^;]+") or spec
  return without_marker:match("===%s*([^,%s]+)") or without_marker:match("==%s*([^,%s]+)")
end

---@param resolved? string
---@param latest? string
---@return boolean
function M.is_major_bump(resolved, latest)
  local function major(v)
    if not v then
      return nil
    end
    local m = tostring(v):match("^(%d+)")
    return m and tonumber(m) or nil
  end
  local r = major(resolved)
  local l = major(latest)
  return (r and l and l > r) or false
end

---@param dep PyDepsDependency
---@param current_env? PyDepsEnv
---@return boolean
function M.is_active(dep, current_env)
  local marker = ui_shared.extract_marker(dep.spec)
  if not marker then
    return true
  end
  local marker_result = markers.evaluate(marker, ui_shared.with_extra_env(current_env, dep))
  return marker_result ~= false
end

---@param context PyDepsUiStatusContext
---@return PyDepsUiStatusResult
function M.classify(context)
  if context.active == false then
    return { class = "inactive" }
  end

  if context.yanked then
    return { class = "yanked" }
  end

  local pinned_version = M.extract_pinned_version(context.spec)
  if pinned_version and context.meta and not ui_shared.is_version_in_releases(context.meta, pinned_version) then
    return {
      class = "pin_not_found",
      pinned_version = pinned_version,
    }
  end

  if context.missing_lockfile or context.unresolved then
    return { class = "unknown" }
  end

  if context.resolved and pinned_version and pinned_version ~= context.resolved then
    return {
      class = "lock_mismatch",
      pinned_version = pinned_version,
    }
  end

  if context.pending == "searching" then
    return { class = "searching" }
  end
  if context.pending == "loading" then
    return { class = "loading" }
  end

  if context.latest and context.resolved and context.latest ~= context.resolved then
    return {
      class = M.is_major_bump(context.resolved, context.latest) and "major" or "update",
    }
  end

  if context.resolved then
    return { class = "ok" }
  end

  return {}
end

return M
