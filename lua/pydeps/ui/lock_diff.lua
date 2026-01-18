local output = require("pydeps.ui.output")

local M = {}

---@param before PyDepsResolved
---@param after PyDepsResolved
---@return string[]
function M.build_lines(before, after)
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

  table.sort(added, function(a, b)
    return a.name < b.name
  end)
  table.sort(removed, function(a, b)
    return a.name < b.name
  end)
  table.sort(updated, function(a, b)
    return a.name < b.name
  end)

  local lines = {}
  local total = #added + #removed + #updated
  if total == 0 then
    return { "No changes detected in uv.lock." }
  end

  table.insert(lines, ("Summary: +%d ~%d -%d"):format(#added, #updated, #removed))
  table.insert(lines, "")

  if #updated > 0 then
    table.insert(lines, "Updated:")
    for _, item in ipairs(updated) do
      table.insert(lines, ("  ~ %s %s -> %s"):format(item.name, item.from, item.to))
    end
    table.insert(lines, "")
  end

  if #added > 0 then
    table.insert(lines, "Added:")
    for _, item in ipairs(added) do
      table.insert(lines, ("  + %s %s"):format(item.name, item.version))
    end
    table.insert(lines, "")
  end

  if #removed > 0 then
    table.insert(lines, "Removed:")
    for _, item in ipairs(removed) do
      table.insert(lines, ("  - %s %s"):format(item.name, item.version))
    end
  end

  return lines
end

---@param before PyDepsResolved
---@param after PyDepsResolved
---@param opts? { title?: string }
function M.show(before, after, opts)
  local lines = M.build_lines(before or {}, after or {})
  output.show(opts and opts.title or "PyDeps Lock Diff", lines)
end

return M
