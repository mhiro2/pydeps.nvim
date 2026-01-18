local cache = require("pydeps.core.cache")

local M = {}

---@class PyDepsTreeBadge
---@field text string
---@field highlight string

---@class PyDepsTreePackageInfo
---@field direct boolean
---@field group string?
---@field extras string[]

---@param root string
---@param package string
---@param direct_deps table<string, boolean>
---@return PyDepsTreePackageInfo
function M.get_package_info(root, package, direct_deps)
  -- Determine if direct
  local direct = direct_deps[package] or false

  -- Get group/extras from direct deps
  local group = nil
  local extras = {}

  if direct then
    -- Find the dep in pyproject to get group/extras
    local pyproject_path = vim.fs.joinpath(root, "pyproject.toml")
    local pyproject_buf = vim.fn.bufadd(pyproject_path)
    vim.fn.bufload(pyproject_buf)
    local deps = cache.get_pyproject(pyproject_buf)

    for _, dep in ipairs(deps) do
      if dep.name == package then
        group = dep.group
        -- Parse extras from the dependency spec if needed
        break
      end
    end
  end

  return {
    direct = direct,
    group = group,
    extras = extras,
  }
end

---@param info PyDepsTreePackageInfo
---@return PyDepsTreeBadge[]
function M.build_badges(info)
  local badges = {}

  if info.direct then
    table.insert(badges, {
      text = "[direct]",
      highlight = "PyDepsBadgeDirect",
    })
  else
    table.insert(badges, {
      text = "[transitive]",
      highlight = "PyDepsBadgeTransitive",
    })
  end

  if info.group and info.group ~= "" and info.group ~= "project" then
    -- Extract group name from "group:name" or "optional:name" format
    local group_name = info.group:gsub("^[^:]+:", "")
    table.insert(badges, {
      text = "[" .. group_name .. "]",
      highlight = "PyDepsBadgeGroup",
    })
  end

  for _, extra in ipairs(info.extras) do
    table.insert(badges, {
      text = "[extra:" .. extra .. "]",
      highlight = "PyDepsBadgeExtra",
    })
  end

  return badges
end

return M
