local output = require("pydeps.ui.output")

local M = {}

---@param before PyDepsResolved
---@param after PyDepsResolved
---@return { added: table[], removed: table[], updated: table[] }
local function compute_changes(before, after)
  local added = {}
  local removed = {}
  local updated = {}

  for name, version in pairs(after or {}) do
    local prev = before and before[name] or nil
    if not prev then
      table.insert(added, { name = name, version = version })
    elseif prev ~= version then
      table.insert(updated, { name = name, from = prev, to = version })
    end
  end

  for name, version in pairs(before or {}) do
    if not (after and after[name]) then
      table.insert(removed, { name = name, version = version })
    end
  end

  local by_name = function(a, b)
    return a.name < b.name
  end
  table.sort(added, by_name)
  table.sort(removed, by_name)
  table.sort(updated, by_name)

  return { added = added, removed = removed, updated = updated }
end

---@param deps_list PyDepsDependency[]
---@return table<string, string> name -> group
local function build_direct_map(deps_list)
  local map = {}
  for _, dep in ipairs(deps_list) do
    map[dep.name] = dep.group or "project"
  end
  return map
end

---@param group string
---@return string label
---@return string sort_key
local function group_display(group)
  if group == "project" then
    return "[project]", "0"
  end
  if group == "transitive" then
    return "[transitive]", "~" -- sorts last
  end
  local prefix, name = group:match("^([^:]+):(.+)$")
  if prefix and name then
    return ("[%s]  (%s)"):format(name, prefix), "1:" .. name
  end
  return "[" .. group .. "]", "1:" .. group
end

---@param before PyDepsResolved
---@param after PyDepsResolved
---@return string[]
function M.build_lines(before, after)
  local changes = compute_changes(before, after)
  local total = #changes.added + #changes.removed + #changes.updated

  if total == 0 then
    return { "No changes detected in uv.lock." }
  end

  local lines = {}
  table.insert(lines, ("Summary: +%d ~%d -%d"):format(#changes.added, #changes.updated, #changes.removed))
  table.insert(lines, "")

  if #changes.updated > 0 then
    table.insert(lines, "Updated:")
    for _, item in ipairs(changes.updated) do
      table.insert(lines, ("  ~ %s %s -> %s"):format(item.name, item.from, item.to))
    end
    table.insert(lines, "")
  end

  if #changes.added > 0 then
    table.insert(lines, "Added:")
    for _, item in ipairs(changes.added) do
      table.insert(lines, ("  + %s %s"):format(item.name, item.version))
    end
    table.insert(lines, "")
  end

  if #changes.removed > 0 then
    table.insert(lines, "Removed:")
    for _, item in ipairs(changes.removed) do
      table.insert(lines, ("  - %s %s"):format(item.name, item.version))
    end
  end

  return lines
end

---@param before PyDepsResolved
---@param after PyDepsResolved
---@param deps_list PyDepsDependency[]
---@return string[]
function M.build_grouped_lines(before, after, deps_list)
  local changes = compute_changes(before, after)
  local total = #changes.added + #changes.removed + #changes.updated

  if total == 0 then
    return { "No changes detected in uv.lock." }
  end

  local direct_map = build_direct_map(deps_list)

  -- Classify changes into groups
  ---@type table<string, { updated: table[], added: table[], removed: table[] }>
  local groups = {}

  local function ensure_group(g)
    if not groups[g] then
      groups[g] = { updated = {}, added = {}, removed = {} }
    end
  end

  for _, item in ipairs(changes.updated) do
    local g = direct_map[item.name] or "transitive"
    ensure_group(g)
    table.insert(groups[g].updated, item)
  end

  for _, item in ipairs(changes.added) do
    local g = direct_map[item.name] or "transitive"
    ensure_group(g)
    table.insert(groups[g].added, item)
  end

  for _, item in ipairs(changes.removed) do
    local g = direct_map[item.name] or "transitive"
    ensure_group(g)
    table.insert(groups[g].removed, item)
  end

  -- Sort groups: project first, then optional/group alphabetically, transitive last
  local group_keys = vim.tbl_keys(groups)
  table.sort(group_keys, function(a, b)
    local _, ka = group_display(a)
    local _, kb = group_display(b)
    return ka < kb
  end)

  local lines = {}
  table.insert(lines, ("Summary: +%d ~%d -%d"):format(#changes.added, #changes.updated, #changes.removed))

  for _, gkey in ipairs(group_keys) do
    local g = groups[gkey]
    local label = group_display(gkey)

    table.insert(lines, "")
    table.insert(lines, label)

    for _, item in ipairs(g.updated) do
      table.insert(lines, ("  ~ %s %s -> %s"):format(item.name, item.from, item.to))
    end
    for _, item in ipairs(g.added) do
      table.insert(lines, ("  + %s %s"):format(item.name, item.version))
    end
    for _, item in ipairs(g.removed) do
      table.insert(lines, ("  - %s %s"):format(item.name, item.version))
    end
  end

  return lines
end

---@param before PyDepsResolved
---@param after PyDepsResolved
---@param opts? { title?: string, root?: string }
function M.show(before, after, opts)
  local lines
  local root = opts and opts.root

  if root then
    local pyproject_path = vim.fs.joinpath(root, "pyproject.toml")
    local ok, pyproject = pcall(require, "pydeps.sources.pyproject")
    if ok then
      local deps_list = pyproject.parse(pyproject_path)
      lines = M.build_grouped_lines(before or {}, after or {}, deps_list)
    end
  end

  if not lines then
    lines = M.build_lines(before or {}, after or {})
  end

  output.show(opts and opts.title or "PyDeps Lock Diff", lines)
end

return M
