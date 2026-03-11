local buffer_context = require("pydeps.core.buffer_context")
local edit = require("pydeps.sources.pyproject_edit")
local state = require("pydeps.core.state")
local util = require("pydeps.util")

local M = {}

---@param spec string
---@return string
local function normalize_spec(spec)
  local req, marker = spec:match("^(.-)%s*;%s*(.+)$")
  if not req then
    req = spec
  end
  req = util.trim(req)
  req = req:gsub("%s*,%s*", ",")
  req = req:gsub("%s*([<>=!~]=?)%s*", "%1")
  req = req:gsub("%s*%[%s*", "["):gsub("%s*%]%s*", "]")
  if marker then
    marker = util.trim(marker)
    return req .. "; " .. marker
  end
  return req
end

---@param spec string
---@param latest string
---@return string
local function update_version(spec, latest)
  local req, marker = spec:match("^(.-)%s*;%s*(.+)$")
  if not req then
    req = spec
  end
  local name_part = req:match("^%s*([%w%._%-]+%s*%b[])")
  local rest = nil
  if name_part then
    rest = req:sub(#name_part + 1)
  else
    name_part = req:match("^%s*([%w%._%-]+)")
    rest = req:sub(#name_part + 1)
  end
  if not name_part then
    return spec
  end
  if rest:find(",") then
    vim.notify("pydeps: multiple constraints detected in version spec; manual update recommended", vim.log.levels.WARN)
    return spec
  end
  local op, version = rest:match("([<>=!~]=?)%s*([^,%s]+)")
  if op and version then
    rest = rest:gsub(vim.pesc(op) .. "%s*" .. vim.pesc(version), op .. latest, 1)
  else
    rest = " >= " .. latest
  end
  local updated = util.trim(name_part .. " " .. util.trim(rest))
  if marker then
    updated = updated .. "; " .. util.trim(marker)
  end
  return normalize_spec(updated)
end

---@param target string
---@param deps PyDepsDependency[]
---@return PyDepsDependency?
local function find_dep_by_name(target, deps)
  local normalized_target = util.parse_requirement_name(target)
  for _, dep in ipairs(deps or {}) do
    local normalized_name = util.parse_requirement_name(dep.name)
    if normalized_name == normalized_target then
      return dep
    end
  end
  return nil
end

---@param spec string
---@return boolean
local function is_direct_reference(spec)
  if spec:find("%s@%s") or spec:find("^[%w%._%-]+@") then
    return true
  end
  if spec:match("https?://") then
    return true
  end
  if spec:match("file://") then
    return true
  end
  if spec:match("%.%/") then
    return true
  end
  return false
end

---@param bufnr integer
---@param dep PyDepsDependency
---@return nil
local function update_dependency(bufnr, dep)
  local pypi = require("pydeps.providers.pypi")
  if is_direct_reference(dep.spec) then
    vim.notify("pydeps: direct reference spec cannot be auto-updated: " .. dep.spec, vim.log.levels.WARN)
    return
  end

  pypi.get(dep.name, function(meta)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if not meta or not meta.info or not meta.info.version then
      vim.notify("pydeps: PyPI metadata not available", vim.log.levels.WARN)
      return
    end
    local updated = update_version(dep.spec, meta.info.version)
    edit.replace_dependency(bufnr, dep, updated)
    state.refresh(bufnr)
  end)
end

---@param target? string
---@param deps PyDepsDependency[]
---@return PyDepsDependency?
local function find_dependency(target, deps)
  if target and target ~= "" then
    local dep = find_dep_by_name(target, deps)
    if not dep then
      vim.notify("pydeps: dependency not found: " .. target, vim.log.levels.WARN)
    end
    return dep
  end

  local dep = buffer_context.dep_under_cursor(deps)
  if dep then
    return dep
  end

  vim.ui.input({ prompt = "pydeps: package name" }, function(input)
    if input and input ~= "" then
      local ok, err = pcall(M.run, input)
      if not ok then
        vim.notify(
          string.format("pydeps: failed to update dependency: %s", err or "unknown error"),
          vim.log.levels.ERROR
        )
      end
    end
  end)

  return nil
end

---@param target? string
---@return nil
function M.run(target)
  local bufnr = buffer_context.current_buf()
  if not buffer_context.is_pyproject_buf(bufnr) then
    vim.notify("pydeps: open pyproject.toml to update dependencies", vim.log.levels.WARN)
    return
  end

  local deps = buffer_context.get_deps(bufnr)
  local dep = find_dependency(target, deps)
  if not dep then
    return
  end

  update_dependency(bufnr, dep)
end

return M
