---@class PyDepsContextOverrides
---@field python? string Python version as uv `--python-version` takes it
---@field platform? string Target as uv `--python-platform` takes it
---@field extras? string[] Selected extras (normalized); nil leaves extras unfiltered
---@field groups? string[] Selected dependency groups (normalized); nil leaves groups unfiltered

local project = require("pydeps.core.project")
local util = require("pydeps.util")

local M = {}

M.FIELDS = { "python", "platform", "extras", "groups" }

---@type table<string, PyDepsContextOverrides>
local overrides = {}

local OS_MARKERS = {
  linux = { sys_platform = "linux", platform_system = "Linux", os_name = "posix" },
  darwin = { sys_platform = "darwin", platform_system = "Darwin", os_name = "posix" },
  windows = { sys_platform = "win32", platform_system = "Windows", os_name = "nt" },
}

-- Target triples uv accepts for `--python-platform`, with the `platform_machine`
-- each reports. The aliases resolve to the triple uv documents for them.
local TARGETS = {
  ["x86_64-unknown-linux-gnu"] = { os = "linux", machine = "x86_64" },
  ["aarch64-unknown-linux-gnu"] = { os = "linux", machine = "aarch64" },
  ["x86_64-unknown-linux-musl"] = { os = "linux", machine = "x86_64" },
  ["aarch64-unknown-linux-musl"] = { os = "linux", machine = "aarch64" },
  ["aarch64-apple-darwin"] = { os = "darwin", machine = "arm64" },
  ["x86_64-apple-darwin"] = { os = "darwin", machine = "x86_64" },
  ["x86_64-pc-windows-msvc"] = { os = "windows", machine = "AMD64" },
  ["aarch64-pc-windows-msvc"] = { os = "windows", machine = "ARM64" },
  ["i686-pc-windows-msvc"] = { os = "windows", machine = "x86" },
}

local ALIASES = {
  linux = "x86_64-unknown-linux-gnu",
  macos = "aarch64-apple-darwin",
  windows = "x86_64-pc-windows-msvc",
}

---Platform values accepted by `set`, aliases first.
---@return string[]
function M.platforms()
  local targets = vim.tbl_keys(TARGETS)
  table.sort(targets)
  return vim.list_extend({ "linux", "macos", "windows" }, targets)
end

---@param list? string[]
---@param name string
---@return boolean
local function contains(list, name)
  return vim.tbl_contains(list or {}, util.normalize_package_name(name))
end

---@param root string
---@return integer?
local function pyproject_buffer(root)
  local path = vim.fs.joinpath(root, "pyproject.toml")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(bufnr)
      and util.is_pyproject(vim.api.nvim_buf_get_name(bufnr))
      and project.normalize_path(vim.api.nvim_buf_get_name(bufnr)) == project.normalize_path(path)
    then
      return bufnr
    end
  end
  return nil
end

---Extras and dependency groups the project declares, read from the open buffer when there is one.
---@param root string
---@return PyDepsSelectableSections
function M.sections(root)
  return require("pydeps.sources.pyproject").parse_sections(
    vim.fs.joinpath(root, "pyproject.toml"),
    pyproject_buffer(root)
  )
end

---Selected groups plus every group they include, transitively.
---@param groups string[]
---@param includes table<string, string[]>
---@return string[]
local function expand_groups(groups, includes)
  local normalized = {}
  for name, included in pairs(includes) do
    normalized[util.normalize_package_name(name)] = included
  end
  local seen, result, queue = {}, {}, vim.list_extend({}, groups)
  while #queue > 0 do
    local name = util.normalize_package_name(table.remove(queue))
    if not seen[name] then
      seen[name] = true
      result[#result + 1] = name
      vim.list_extend(queue, normalized[name] or {})
    end
  end
  table.sort(result)
  return result
end

---@param root? string
---@return PyDepsContextOverrides
function M.overrides(root)
  return vim.deepcopy(root and overrides[root] or {})
end

---Environment that every view evaluates markers and lock projections against:
---the detected interpreter with the user's overrides applied.
---@param root? string
---@return PyDepsEnv
function M.env(root)
  local base = require("pydeps.core.env").get(root)
  local selected = root and overrides[root]
  if not selected then
    return base
  end

  local result = vim.tbl_extend("force", {}, base)
  if selected.python then
    -- uv maps a version without a patch component to its first patch release.
    local full = selected.python:match("^%d+%.%d+$") and (selected.python .. ".0") or selected.python
    result.python_version = full:match("^(%d+%.%d+)")
    result.python_full_version = full
    result.implementation_version = base.implementation_name == "cpython" and full or nil
  end
  if selected.platform then
    local target = TARGETS[ALIASES[selected.platform] or selected.platform]
    result = vim.tbl_extend("force", result, OS_MARKERS[target.os], { platform_machine = target.machine })
    -- The target says nothing about the OS release or build.
    result.platform_release = nil
    result.platform_version = nil
  end
  if selected.extras then
    result.extras = vim.deepcopy(selected.extras)
  end
  if selected.groups then
    result.dependency_groups = expand_groups(selected.groups, M.sections(root).includes)
  end
  return result
end

---Why a declared dependency's extra or group lies outside the selection.
---@param dep PyDepsDependency
---@param current_env? PyDepsEnv
---@return string?
function M.excluded_reason(dep, current_env)
  local group = dep.group or ""
  local extra = group:match("^optional:(.+)$")
  if extra and current_env and current_env.extras and not contains(current_env.extras, extra) then
    return string.format('extra "%s" is not selected', extra)
  end
  local dependency_group = group:match("^group:(.+)$")
  if
    dependency_group
    and current_env
    and current_env.dependency_groups
    and not contains(current_env.dependency_groups, dependency_group)
  then
    return string.format('group "%s" is not selected', dependency_group)
  end
  return nil
end

---@param values string[]
---@param declared string[]
---@param kind string
---@return string[]? normalized
---@return string? err
local function validate_names(values, declared, kind)
  local known = {}
  for _, name in ipairs(declared) do
    known[util.normalize_package_name(name)] = true
  end
  local result, seen = {}, {}
  for _, value in ipairs(values) do
    local name = util.normalize_package_name(value)
    if not known[name] then
      return nil, string.format("unknown %s '%s'", kind, value)
    end
    if not seen[name] then
      seen[name] = true
      result[#result + 1] = name
    end
  end
  table.sort(result)
  return result
end

---@param root string
---@param field string
---@param value string|string[]|nil
---@return any normalized
---@return string? err
local function normalize(root, field, value)
  if field == "python" then
    if type(value) ~= "string" or not (value:match("^%d+%.%d+$") or value:match("^%d+%.%d+%.%d+$")) then
      return nil, "python must be a version like 3.12 or 3.12.4"
    end
    return value
  elseif field == "platform" then
    if type(value) ~= "string" or not (ALIASES[value] or TARGETS[value]) then
      return nil, "unsupported platform; expected one of: " .. table.concat(M.platforms(), ", ")
    end
    return value
  end
  local sections = M.sections(root)
  local values = type(value) == "table" and value or {}
  if field == "extras" then
    return validate_names(values, sections.extras, "extra")
  end
  return validate_names(values, sections.groups, "group")
end

---@param root string
local function changed(root)
  require("pydeps.core.state").refresh_all()
  util.emit_user_autocmd("PyDepsContextChanged", { root = root })
end

---Override one field of the root's context. A nil value restores detection or
---leaves the selection unfiltered; an empty list selects no extras or groups.
---@param root string
---@param field "python"|"platform"|"extras"|"groups"
---@param value string|string[]|nil
---@return boolean ok
---@return string? err
function M.set(root, field, value)
  if not vim.tbl_contains(M.FIELDS, field) then
    return false, "unknown context field '" .. tostring(field) .. "'"
  end
  local normalized = nil
  if value ~= nil then
    local err
    normalized, err = normalize(root, field, value)
    if err then
      return false, err
    end
  end
  local selected = overrides[root] or {}
  selected[field] = normalized
  overrides[root] = next(selected) and selected or nil
  changed(root)
  return true
end

---Drop every override for the root, or only `field`.
---@param root string
---@param field? string
---@return boolean ok
---@return string? err
function M.reset(root, field)
  if field then
    return M.set(root, field, nil)
  end
  overrides[root] = nil
  changed(root)
  return true
end

---@param list? string[]
---@return string
local function format_selection(list)
  if not list then
    return "all"
  end
  if #list == 0 then
    return "none"
  end
  return table.concat(list, ", ")
end

---One-line description of the context, e.g. `python 3.11.0 · linux · extras all · groups test`.
---@param root? string
---@param current_env? PyDepsEnv
---@return string
function M.summary(root, current_env)
  local selected = root and overrides[root] or {}
  current_env = current_env or M.env(root)
  return table.concat({
    "python " .. (current_env.python_full_version or current_env.python_version or "?"),
    selected.platform or current_env.sys_platform or "?",
    "extras " .. format_selection(selected.extras),
    "groups " .. format_selection(selected.groups),
  }, " · ")
end

---Field rows for the context menu: value and whether it is detected or chosen.
---@param root string
---@return { field: string, value: string, source: string }[]
function M.describe(root)
  local selected = overrides[root] or {}
  local detected = require("pydeps.core.env").get(root)
  local current = M.env(root)
  local function source(field, detected_value)
    if selected[field] == nil then
      return (field == "extras" or field == "groups") and "unfiltered" or "detected"
    end
    return detected_value and ("override; detected " .. detected_value) or "override"
  end
  local groups = format_selection(selected.groups)
  if selected.groups and current.dependency_groups and #current.dependency_groups > #selected.groups then
    groups = groups .. " (with includes: " .. table.concat(current.dependency_groups, ", ") .. ")"
  end
  return {
    {
      field = "python",
      value = current.python_full_version or current.python_version or "?",
      source = source("python", detected.python_full_version),
    },
    {
      field = "platform",
      value = selected.platform or current.sys_platform or "?",
      source = source("platform", detected.sys_platform),
    },
    { field = "extras", value = format_selection(selected.extras), source = source("extras") },
    { field = "groups", value = groups, source = source("groups") },
  }
end

---@private
function M._clear()
  overrides = {}
end

return M
