local M = {}

---Shortest dependency path from `root` to `target`, both included.
---@param graph table<string, string[]>
---@param root string
---@param target string
---@return string[]?
function M.find_path(graph, root, target)
  graph = graph or {}
  if root == target then
    return { root }
  end
  local queue = { root }
  local parents = { [root] = false }
  local head = 1
  while head <= #queue do
    local node = queue[head]
    head = head + 1
    for _, child in ipairs(graph[node] or {}) do
      if parents[child] == nil then
        parents[child] = node
        if child == target then
          local path = { target }
          local cur = node
          while cur do
            table.insert(path, 1, cur)
            cur = parents[cur]
          end
          return path
        end
        table.insert(queue, child)
      end
    end
  end
  return nil
end

---@param graph table<string, string[]>
---@param roots string[]
---@param target string
---@return table<string, boolean>
function M.roots_reaching_target(graph, roots, target)
  local reverse = {}
  for parent, children in pairs(graph or {}) do
    for _, child in ipairs(children or {}) do
      if not reverse[child] then
        reverse[child] = {}
      end
      table.insert(reverse[child], parent)
    end
  end

  local queue = { target }
  local seen = { [target] = true }
  local head = 1
  while head <= #queue do
    local node = queue[head]
    head = head + 1
    for _, parent in ipairs(reverse[node] or {}) do
      if not seen[parent] then
        seen[parent] = true
        table.insert(queue, parent)
      end
    end
  end

  local reachable = {}
  for _, root in ipairs(roots or {}) do
    if seen[root] then
      reachable[root] = true
    end
  end
  return reachable
end

return M
