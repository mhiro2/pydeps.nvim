local buffer_context = require("pydeps.core.buffer_context")
local cache = require("pydeps.core.cache")

local M = {}

---@param flag_name string
---@param uv_args string[]
---@param primary_args string[]
---@param fallback_args? string[]
---@return boolean
local function add_if_supported(flag_name, uv_args, primary_args, fallback_args)
  local uv = require("pydeps.providers.uv")
  if uv.supports_tree_flag(flag_name) then
    vim.list_extend(uv_args, primary_args)
    return true
  end
  if fallback_args then
    vim.list_extend(uv_args, fallback_args)
    return true
  end
  vim.notify("pydeps: --" .. flag_name .. " not supported by this uv version", vim.log.levels.WARN)
  return false
end

---@param tree_args PyDepsTreeArgs
---@param target? string
---@return string[]
local function build_tree_args(tree_args, target)
  local uv = require("pydeps.providers.uv")
  local uv_args = { "tree" }

  if tree_args.frozen and uv.supports_tree_flag("frozen") then
    vim.list_extend(uv_args, { "--frozen" })
  end
  if target then
    add_if_supported("package", uv_args, { "--package", target }, { target })
  end
  if tree_args.depth then
    add_if_supported("depth", uv_args, { "--depth", tostring(tree_args.depth) })
  end
  if tree_args.invert then
    add_if_supported("invert", uv_args, { "--invert" })
  end
  if tree_args.universal then
    add_if_supported("universal", uv_args, { "--universal" })
  end
  if tree_args.show_sizes then
    add_if_supported("show_sizes", uv_args, { "--show-sizes" })
  end
  if tree_args.all_groups then
    add_if_supported("all_groups", uv_args, { "--all-groups" })
  end

  for _, group in ipairs(tree_args.groups or {}) do
    if not add_if_supported("group", uv_args, { "--group", group }) then
      break
    end
  end
  for _, group in ipairs(tree_args.no_groups or {}) do
    if not add_if_supported("no_group", uv_args, { "--no-group", group }) then
      break
    end
  end

  return uv_args
end

---@param root string
---@return fun(lines: string[]): integer
local function build_width_calc(root)
  return function(lines)
    local tree_ui = require("pydeps.ui.tree")
    local pyproject_path = vim.fs.joinpath(root, "pyproject.toml")
    local pyproject = require("pydeps.sources.pyproject")
    local deps_list = pyproject.parse(pyproject_path)
    local direct_deps = {}
    for _, dep in ipairs(deps_list) do
      direct_deps[dep.name] = true
    end
    return tree_ui.estimate_width(lines, direct_deps, deps_list)
  end
end

---@param bufnr integer
---@param tree_args PyDepsTreeArgs
---@param args_str string
---@param opts table
---@return string?
local function resolve_target(bufnr, tree_args, args_str, opts)
  local target = tree_args.target
  if not target then
    local deps = buffer_context.get_deps(bufnr)
    local dep = buffer_context.dep_under_cursor(deps)
    target = dep and dep.name
  end

  if tree_args.reverse and not target then
    vim.ui.input({ prompt = "pydeps: package name for reverse tree" }, function(input)
      if input and input ~= "" then
        M.run("--package " .. input .. " " .. args_str, false, opts)
      end
    end)
    return nil
  end

  return target
end

---@param root string
---@param uv_args string[]
---@param opts? { anchor?: "center"|"cursor"|"hover", mode?: "split"|"float", width?: integer, height?: integer }
---@return nil
local function show_tree(root, uv_args, opts)
  local output = require("pydeps.ui.output")
  local tree_ui = require("pydeps.ui.tree")
  local uv = require("pydeps.providers.uv")
  local command = uv.tree_command({
    root = root,
    args = uv_args,
  })
  if not command then
    return
  end

  local width_calc = nil
  if opts and opts.mode == "float" and not opts.width then
    width_calc = build_width_calc(root)
  end

  output.run_command(command.cmd, {
    cwd = command.cwd,
    title = "PyDeps Tree",
    anchor = opts and opts.anchor,
    mode = opts and opts.mode,
    width = opts and opts.width,
    height = opts and opts.height,
    width_calc = width_calc,
    on_show = function(buf, lines)
      tree_ui.setup_keymaps(buf, lines, { root = root })
    end,
  })
end

---@param args_str string
---@param bang boolean
---@param opts? { anchor?: "center"|"cursor"|"hover", mode?: "split"|"float", width?: integer, height?: integer }
---@return nil
function M.run(args_str, bang, opts)
  local uv = require("pydeps.providers.uv")
  if not uv.tree_features_ready() then
    uv.detect_tree_features(function()
      vim.schedule(function()
        M.run(args_str, bang, opts)
      end)
    end)
    vim.notify("pydeps: detecting uv tree features...", vim.log.levels.INFO)
    return
  end

  local tree_args = require("pydeps.core.tree_args").parse(args_str, bang)
  if #tree_args.unknown_options > 0 then
    vim.notify("pydeps: unknown tree options: " .. table.concat(tree_args.unknown_options, ", "), vim.log.levels.WARN)
  end

  local bufnr = buffer_context.current_buf()
  local root = buffer_context.find_root(bufnr)
  if not root then
    vim.notify("pydeps: project root not found", vim.log.levels.WARN)
    return
  end

  if tree_args.frozen and uv.supports_tree_flag("frozen") then
    local _, missing = cache.get_lockfile(root, { sync = true })
    if missing then
      vim.notify(
        "pydeps: uv.lock not found. Run :PyDepsResolve first, or use --resolve to skip frozen mode.",
        vim.log.levels.WARN
      )
      return
    end
  end

  local target = resolve_target(bufnr, tree_args, args_str, opts or {})
  if not target and tree_args.reverse then
    return
  end

  show_tree(root, build_tree_args(tree_args, target), opts)
end

return M
