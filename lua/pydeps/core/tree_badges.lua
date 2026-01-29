local M = {}

---@class PyDepsTreeBadge
---@field text string
---@field highlight string

---@class PyDepsTreePackageInfo
---@field direct boolean
---@field group string?
---@field extras string[]

---@param package string
---@param direct_deps table<string, boolean>
---@param deps_list PyDepsDependency[] Pre-parsed dependency list
---@return PyDepsTreePackageInfo
function M.get_package_info(package, direct_deps, deps_list)
  local direct = direct_deps[package] or false

  local group = nil
  local extras = {}

  if direct then
    for _, dep in ipairs(deps_list) do
      if dep.name == package then
        group = dep.group
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
