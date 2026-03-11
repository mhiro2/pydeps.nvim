local cache = require("pydeps.core.cache")
local config = require("pydeps.config")
local ui_shared = require("pydeps.ui.shared")
local util = require("pydeps.util")

local M = {}

---@class PyDepsRenderOptions
---@field lockfile_missing boolean
---@field lockfile_loading? boolean
---@field root? string

---@class PyDepsStatusResult
---@field kind "ok"|"update"|"warn"|"error"|"inactive"|"unknown"
---@field text string
---@field icon string
---@field lock_status? string
---@field show_latest_warning boolean

local COL_LABEL_WIDTH = 12

---@param icon string
---@param label string
---@param value string
---@param suffix? string
---@return string
local function format_line(icon, label, value, suffix)
  local label_text = icon ~= "" and (icon .. " " .. label) or label
  local label_width = vim.fn.strdisplaywidth(label_text)
  local padding = string.rep(" ", COL_LABEL_WIDTH - label_width)
  local formatted = label_text .. padding .. value

  if suffix then
    formatted = formatted .. string.rep(" ", 4) .. suffix
  end

  return formatted
end

---@param dep PyDepsDependency
---@return string?
local function format_extras(dep)
  local extras = {}

  if dep.group and dep.group ~= "" and dep.group ~= "project" then
    if dep.group:match("^optional:") then
      table.insert(extras, dep.group:sub(#"optional:" + 1))
    elseif dep.group:match("^group:") then
      table.insert(extras, dep.group:sub(#"group:" + 1))
    else
      table.insert(extras, dep.group)
    end
  end

  for _, extra in ipairs(util.parse_requirement_extras(dep.spec)) do
    table.insert(extras, extra)
  end

  if #extras == 0 then
    return nil
  end

  local unique = {}
  local seen = {}
  for _, extra in ipairs(extras) do
    if not seen[extra] then
      seen[extra] = true
      table.insert(unique, extra)
    end
  end

  return format_line(ui_shared.icon_for("extras"), "extras", table.concat(unique, ", "))
end

---@param lock_data PyDepsLockfileData
---@param dep_name string
---@return integer|string
local function get_deps_count(lock_data, dep_name)
  if not lock_data or not lock_data.packages then
    return "?"
  end

  local pkg = lock_data.packages[dep_name]
  if not pkg or not pkg.dependencies then
    return 0
  end

  return #pkg.dependencies
end

---@param status PyDepsStatusResult
---@return string
function M.format_status_text(status)
  if status.text and status.text ~= "" then
    return status.text
  end
  if status.kind == "ok" then
    return "active"
  elseif status.kind == "update" then
    return "update available"
  elseif status.kind == "warn" then
    return "lock mismatch"
  elseif status.kind == "error" then
    return "yanked"
  elseif status.kind == "inactive" then
    return "inactive"
  end

  return "unknown"
end

---@param view PyDepsDependencyView
---@return PyDepsStatusResult
function M.determine_status(view)
  return {
    kind = view.status_kind,
    text = view.status_text,
    icon = view.status_icon,
    lock_status = view.lock_status,
    show_latest_warning = view.show_latest_warning,
  }
end

---@param view PyDepsDependencyView
---@param opts? PyDepsRenderOptions
---@return string[]
function M.build_lines(view, opts)
  local dep = view.dep
  local lines = {}
  local root = opts and opts.root
  local lock_data = {}

  if root then
    lock_data = cache.get_lockfile(root)
  end

  local status = M.determine_status(view)
  local description = view.meta and view.meta.info and view.meta.info.summary

  table.insert(lines, ui_shared.icon_for("package") .. " " .. dep.name)

  if description and description ~= "" then
    table.insert(lines, "")
    table.insert(lines, description)
    table.insert(lines, "")
  end

  table.insert(lines, format_line(ui_shared.icon_for("spec"), "spec", dep.spec or "(unknown)"))

  if view.resolved then
    table.insert(lines, format_line(ui_shared.icon_for("lock"), "lock", view.resolved, status.lock_status or ""))
  elseif opts and opts.lockfile_loading then
    table.insert(lines, format_line(ui_shared.icon_for("loading"), "lock", "(loading...)"))
  elseif opts and opts.lockfile_missing then
    table.insert(lines, format_line(ui_shared.icon_for("lock"), "lock", "(missing)"))
  else
    table.insert(lines, format_line(ui_shared.icon_for("lock"), "lock", "(not found)"))
  end

  local latest_version = view.latest or (view.meta and "(not found)" or "(loading...)")
  local latest_suffix = status.show_latest_warning and "(update available)" or nil
  table.insert(lines, format_line(ui_shared.icon_for("latest"), "latest", latest_version, latest_suffix))

  local extras_line = format_extras(dep)
  if extras_line then
    table.insert(lines, extras_line)
  end

  if view.marker then
    table.insert(lines, format_line(ui_shared.icon_for("markers"), "markers", view.marker))
  end

  local status_suffix = ""
  if status.kind == "inactive" then
    local runtime_env = view.current_env or {}
    local python_ver = runtime_env.python_full_version or runtime_env.python_version or "unknown"
    status_suffix = "(python " .. python_ver .. ")"
  end
  table.insert(lines, format_line(ui_shared.icon_for("status"), "status", M.format_status_text(status), status_suffix))

  local deps_count = get_deps_count(lock_data, dep.name)
  table.insert(lines, format_line(ui_shared.icon_for("deps"), "deps", tostring(deps_count), "(Enter: Why, gT: Tree)"))

  local pypi_url = config.options.pypi_url .. "/" .. dep.name
  if view.meta and view.meta.info and view.meta.info.version then
    table.insert(lines, format_line(ui_shared.icon_for("pypi"), "pypi", pypi_url))
  else
    table.insert(lines, format_line(ui_shared.icon_for("pypi"), "pypi", "not found on public PyPI"))
  end

  return lines
end

return M
