local info = require("pydeps.ui.info")
local output = require("pydeps.ui.output")
local provenance = require("pydeps.core.provenance")

local M = {}

local provenance_ns = vim.api.nvim_create_namespace("pydeps-why")

---@param buf integer
---@param lines string[]
---@return nil
local function highlight(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, provenance_ns, 0, -1)
  for idx, line in ipairs(lines) do
    local label = line:match("^([%a%s]+):%s")
    if label then
      local start_col = line:find(label, 1, true)
      if start_col then
        vim.api.nvim_buf_add_highlight(buf, provenance_ns, "Identifier", idx - 1, start_col - 1, start_col - 1 + #label)
      end
      if label == "Target" then
        local value_start = line:find(": ", 1, true)
        if value_start then
          local col = value_start + 2
          vim.api.nvim_buf_add_highlight(buf, provenance_ns, "Title", idx - 1, col - 1, #line)
        end
      end
    end
    if line:match("^Press q or <Esc> to close") then
      vim.api.nvim_buf_add_highlight(buf, provenance_ns, "Comment", idx - 1, 0, #line)
    end
  end
end

---@param deps PyDepsDependency[]
---@return string[], table<string, string>
local function collect_roots(deps)
  local roots = {}
  local root_labels = {}
  local seen = {}

  for _, entry in ipairs(deps or {}) do
    if not seen[entry.name] then
      seen[entry.name] = true
      table.insert(roots, entry.name)
      local label = (entry.group and entry.group ~= "" and entry.group ~= "project") and entry.group or "project"
      root_labels[entry.name] = label
    end
  end

  return roots, root_labels
end

---@param target string
---@param roots string[]
---@param root_labels table<string, string>
---@param reachable table<string, boolean>
---@param graph table<string, string[]>
---@return string[]
local function build_lines(target, roots, root_labels, reachable, graph)
  local lines = { "Target: " .. target }
  local direct_label = root_labels[target]
  if direct_label then
    if direct_label ~= "project" then
      table.insert(lines, ("Direct: yes (%s)"):format(direct_label))
    else
      table.insert(lines, "Direct: yes")
    end
  else
    table.insert(lines, "Direct: no")
  end

  local total_paths = 0
  local group_counts = {}
  local label_order = {}
  local label_seen = {}
  for _, root_name in ipairs(roots) do
    if reachable[root_name] then
      total_paths = total_paths + 1
      local label = root_labels[root_name] or "project"
      group_counts[label] = (group_counts[label] or 0) + 1
      if not label_seen[label] then
        label_seen[label] = true
        table.insert(label_order, label)
      end
    end
  end

  if total_paths == 0 then
    table.insert(lines, "No path from active roots.")
  else
    local parts = {}
    if label_seen["project"] then
      table.insert(parts, ("project(%d)"):format(group_counts["project"]))
    end
    for _, label in ipairs(label_order) do
      if label ~= "project" then
        table.insert(parts, ("%s(%d)"):format(label, group_counts[label]))
      end
    end
    table.insert(lines, ("Roots with path: %d (%s)"):format(total_paths, table.concat(parts, ", ")))

    local display_limit = 5
    local shown = math.min(display_limit, total_paths)
    table.insert(lines, ("Paths (showing %d/%d):"):format(shown, total_paths))

    local shown_paths = 0
    for _, root_name in ipairs(roots) do
      if reachable[root_name] then
        local path = provenance.find_path(graph, root_name, target)
        if path then
          local head = path[1]
          local label = root_labels[head]
          if label and label ~= "project" then
            path = vim.deepcopy(path)
            path[1] = ("%s [%s]"):format(head, label)
          end
          table.insert(lines, "  - " .. table.concat(path, " -> "))
          shown_paths = shown_paths + 1
          if shown_paths >= display_limit then
            break
          end
        end
      end
    end

    if total_paths > display_limit then
      table.insert(lines, ("  ... and %d more"):format(total_paths - display_limit))
    end
  end

  table.insert(lines, "")
  table.insert(lines, "Press q or <Esc> to close")
  return lines
end

---@param target string
---@param deps PyDepsDependency[]
---@param graph table<string, string[]>
---@return boolean?, string?
function M.show(target, deps, graph)
  local roots, root_labels = collect_roots(deps)
  local reachable = provenance.roots_reaching_target(graph, roots, target)
  local lines = build_lines(target, roots, root_labels, reachable, graph)

  info.suspend_close()
  local ok, err = pcall(output.show, "PyDeps Why: " .. target, lines, {
    mode = "float",
    anchor = "hover",
    highlight = highlight,
    on_close = function()
      info.resume_close()
    end,
  })
  if not ok then
    info.resume_close()
    return nil, err
  end
  return true
end

return M
