local M = {}

---@type table<integer, table<integer, string>>
local line_to_package = {}

local tree_ns = vim.api.nvim_create_namespace("pydeps-tree")

local project = require("pydeps.core.project")

---@param root string
---@return table<string, boolean>
local function build_direct_deps(root)
  local pyproject_path = vim.fs.joinpath(root, "pyproject.toml")
  local pyproject = require("pydeps.sources.pyproject")
  local deps = pyproject.parse(pyproject_path)
  local direct_deps = {}
  for _, dep in ipairs(deps) do
    direct_deps[dep.name] = true
  end
  return direct_deps
end

---@param lines string[]
---@param root string
---@param direct_deps table<string, boolean>?
---@return table<integer, PyDepsTreeBadge[]>
local function build_badges_for_lines(lines, root, direct_deps)
  local badges = require("pydeps.core.tree_badges")
  local packages = M.extract_packages(lines)
  local result = {}

  for line_num, package_name in pairs(packages) do
    local pkg_info = badges.get_package_info(root, package_name, direct_deps)
    result[line_num] = badges.build_badges(pkg_info)
  end

  return result
end

---@param badge_list PyDepsTreeBadge[]
---@return integer
local function calc_badge_width(badge_list)
  if not badge_list or #badge_list == 0 then
    return 0
  end

  local width = 0
  for i, badge in ipairs(badge_list) do
    width = width + vim.fn.strdisplaywidth(badge.text)
    if i > 1 then
      width = width + 1 -- space between badges
    end
  end
  return width
end

---@param lines string[]
---@param root string
---@param direct_deps table<string, boolean>?
---@return integer
function M.estimate_width(lines, root, direct_deps)
  if not root then
    -- No badges without root, just return max line width
    local width = 0
    for _, line in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    return width + 2 -- padding
  end

  direct_deps = direct_deps or build_direct_deps(root)
  local badges_by_line = build_badges_for_lines(lines, root, direct_deps)

  local max_width = 0
  for line_num, line in ipairs(lines) do
    local line_width = vim.fn.strdisplaywidth(line)
    local badge_list = badges_by_line[line_num]
    local badge_width = calc_badge_width(badge_list)

    local total_width = line_width
    if badge_width > 0 then
      total_width = total_width + 1 + badge_width -- 1 space before badges
    end

    max_width = math.max(max_width, total_width)
  end

  return max_width + 2 -- float padding
end

---@param lines string[]
---@return table<integer, string>
function M.extract_packages(lines)
  local result = {}

  for line_num, line in ipairs(lines) do
    -- Match uv tree output patterns:
    -- "package-name version"
    -- "├── package-name version"
    -- "│   └── package-name version"
    -- "└── package-name version"
    -- Also handle (*) for already-shown packages

    local stripped = line:gsub("^%s*", ""):gsub("^[│├└─%s]+", "")
    -- Skip lines that are just (*) markers or empty
    if stripped ~= "" and stripped:match("^%(%*%)$") == nil then
      -- Extract package name (followed by version number - space and optional "v" prefix and digit)
      local package_name = stripped:match("^([%w%._%-]+)%s+v?%d")
      if package_name and package_name ~= "" then
        result[line_num] = package_name
      end
    end
  end

  return result
end

---@param buf integer
---@param lines string[]
---@param root string
---@param direct_deps table<string, boolean>
---@return nil
function M.add_badges(buf, lines, root, direct_deps)
  local badges_by_line = build_badges_for_lines(lines, root, direct_deps)

  for line_num, badge_list in pairs(badges_by_line) do
    local badge_texts = {}
    for _, badge in ipairs(badge_list) do
      table.insert(badge_texts, { badge.text, badge.highlight })
    end

    -- Add virtual text at end of line (0-indexed)
    local line = lines[line_num]
    local col = #line
    vim.api.nvim_buf_set_extmark(buf, tree_ns, line_num - 1, col, {
      virt_text = badge_texts,
      virt_text_pos = "eol",
    })
  end
end

---@param buf integer
---@param lines string[]
---@param opts? { root?: string }
---@return nil
function M.setup_keymaps(buf, lines, opts)
  opts = opts or {}
  local packages = M.extract_packages(lines)
  line_to_package[buf] = packages

  -- Clear existing keymaps
  pcall(vim.keymap.del, "n", "<CR>", { buffer = buf })
  pcall(vim.keymap.del, "n", "i", { buffer = buf })

  -- Enter key: PyDepsWhy
  vim.keymap.set("n", "<CR>", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local pkg = line_to_package[buf] and line_to_package[buf][line]
    if pkg then
      local commands = require("pydeps.commands")
      commands.provenance(pkg)
    else
      vim.notify("pydeps: no package on this line", vim.log.levels.WARN)
    end
  end, { buffer = buf, desc = "PyDeps: Show why this package is needed", nowait = true })

  -- i key: PyDepsInfo - show minimal info since we don't have full dep object
  vim.keymap.set("n", "i", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local pkg = line_to_package[buf] and line_to_package[buf][line]
    if pkg then
      -- Find the root from opts if available, otherwise use project root
      local root = opts.root and opts.root or project.find_root(buf)
      if not root then
        vim.notify("pydeps: project root not found", vim.log.levels.WARN)
        return
      end

      -- Get resolved version from lockfile
      local cache = require("pydeps.core.cache")
      local lock_data, missing = cache.get_lockfile(root)
      local resolved = lock_data and lock_data.resolved or {}
      local version = resolved[pkg]

      -- Create minimal dep object
      local dep = { name = pkg, spec = version and "===" .. version or nil }

      local info_mod = require("pydeps.ui.info")
      info_mod.show(dep, version, { lockfile_missing = missing })
    else
      vim.notify("pydeps: no package on this line", vim.log.levels.WARN)
    end
  end, { buffer = buf, desc = "PyDeps: Show package info", nowait = true })

  -- Add badges if root provided
  if opts.root then
    local direct_deps = build_direct_deps(opts.root)
    M.add_badges(buf, lines, opts.root, direct_deps)
  end

  -- Setup cleanup on buffer wipe
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      M.cleanup(buf)
    end,
  })
end

---@param buf integer
---@return nil
function M.cleanup(buf)
  line_to_package[buf] = nil
  vim.api.nvim_buf_clear_namespace(buf, tree_ns, 0, -1)
end

return M
