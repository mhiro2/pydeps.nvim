local cache = require("pydeps.core.cache")
local project = require("pydeps.core.project")
local state = require("pydeps.core.state")
local edit = require("pydeps.sources.pyproject_edit")
local info = require("pydeps.ui.info")
local lock_diff = require("pydeps.ui.lock_diff")
local provenance_ui = require("pydeps.ui.provenance")
local pypi = require("pydeps.providers.pypi")
local util = require("pydeps.util")

local M = {}

-- Helper functions

---@return integer
local function current_buf()
  return vim.api.nvim_get_current_buf()
end

---@param bufnr integer
---@return boolean
local function is_pyproject_buf(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name:match("pyproject%.toml$") ~= nil
end

---@param bufnr integer
---@return PyDepsDependency[]
local function parse_buffer_deps(bufnr)
  return cache.get_pyproject(bufnr)
end

---@param lock_data PyDepsLockfileData
---@return PyDepsAuditPackage[]
local function collect_lock_packages(lock_data)
  local packages = {}
  for name, package in pairs(lock_data.packages or {}) do
    if type(package) == "table" and package.version then
      table.insert(packages, {
        name = package.name or name,
        version = package.version,
      })
    end
  end
  table.sort(packages, function(a, b)
    return a.name < b.name
  end)
  return packages
end

---@param root string
---@return nil
local function show_lock_diff(root)
  local snapshot = cache.get_lock_snapshot(root)
  if not snapshot then
    vim.notify("pydeps: no previous lockfile snapshot (run :PyDepsResolve first)", vim.log.levels.WARN)
    return
  end
  local current, missing = cache.get_lockfile(root, { sync = true })
  if missing then
    vim.notify("pydeps: uv.lock not found", vim.log.levels.WARN)
    return
  end
  lock_diff.show(snapshot, current.resolved or {}, { title = "PyDeps Lock Diff" })
end

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
  -- Check for multiple constraints (e.g., ">=1.0,<2.0")
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
  -- Direct reference with @ (e.g., package @ git+https://...)
  if spec:find("%s@%s") or spec:find("^[%w%._%-]+@") then
    return true
  end
  -- URL reference (https:// or http://)
  if spec:match("https?://") then
    return true
  end
  -- File path reference (file://)
  if spec:match("file://") then
    return true
  end
  -- Relative path (./ or ../)
  if spec:match("%.%/") then
    return true
  end
  return false
end

---@param bufnr integer
---@param dep PyDepsDependency
---@return nil
local function update_dependency(bufnr, dep)
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
local function find_dependency_to_update(target, deps)
  -- If target specified, find by name
  if target and target ~= "" then
    local dep = find_dep_by_name(target, deps)
    if not dep then
      vim.notify("pydeps: dependency not found: " .. target, vim.log.levels.WARN)
    end
    return dep
  end

  -- Otherwise, use dependency under cursor
  local dep = util.dep_under_cursor(deps)
  if dep then
    return dep
  end

  -- Prompt for package name if no dependency found
  vim.ui.input({ prompt = "pydeps: package name" }, function(input)
    if input and input ~= "" then
      local ok, err = pcall(M.update, input)
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
function M.update(target)
  local bufnr = current_buf()
  if not is_pyproject_buf(bufnr) then
    vim.notify("pydeps: open pyproject.toml to update dependencies", vim.log.levels.WARN)
    return
  end

  local deps = parse_buffer_deps(bufnr)
  local dep = find_dependency_to_update(target, deps)

  if not dep then
    return
  end

  update_dependency(bufnr, dep)
end

---@param opts? { diff_only?: boolean, root?: string }
---@return nil
function M.resolve(opts)
  local bufnr = current_buf()
  local root = (opts and opts.root) or project.find_root(bufnr)
  if not root then
    vim.notify("pydeps: project root not found", vim.log.levels.WARN)
    return
  end

  if opts and opts.diff_only then
    show_lock_diff(root)
    state.refresh_all()
    return
  end

  local before = cache.get_lockfile(root, { sync = true })
  cache.set_lock_snapshot(root, before.resolved or {})
  require("pydeps.providers.uv").resolve({
    root = root,
    on_exit = function()
      cache.invalidate_lockfile(root)
      local after, missing = cache.get_lockfile(root, { sync = true })
      if missing then
        vim.notify("pydeps: uv.lock not found after resolve", vim.log.levels.WARN)
      else
        lock_diff.show(before.resolved or {}, after.resolved or {}, { title = "PyDeps Lock Diff" })
        cache.set_lock_snapshot(root, after.resolved or {})
      end
      state.refresh_all()
    end,
  })
end

-- Tree helper functions (must be defined before M.tree)

---@param uv table
---@param uv_args string[]
---@param flag_name string
---@param primary_args string[]
---@param fallback_args? string[]
---@return boolean
local function add_if_supported(uv, uv_args, flag_name, primary_args, fallback_args)
  if uv.supports_tree_flag(flag_name) then
    vim.list_extend(uv_args, primary_args)
    return true
  elseif fallback_args then
    vim.list_extend(uv_args, fallback_args)
    return true
  else
    vim.notify("pydeps: --" .. flag_name .. " not supported by this uv version", vim.log.levels.WARN)
    return false
  end
end

---@param tree_args table
---@param target? string
---@return string[]
local function build_tree_args(tree_args, target)
  local uv = require("pydeps.providers.uv")
  local uv_args = { "tree" }

  -- Add --frozen flag if supported and enabled
  if tree_args.frozen and uv.supports_tree_flag("frozen") then
    vim.list_extend(uv_args, { "--frozen" })
  end

  -- Add target package if specified
  if target then
    add_if_supported(uv, uv_args, "package", { "--package", target }, { target })
  end

  -- Add optional flags
  if tree_args.depth then
    add_if_supported(uv, uv_args, "depth", { "--depth", tostring(tree_args.depth) })
  end
  if tree_args.invert then
    add_if_supported(uv, uv_args, "invert", { "--invert" })
  end
  if tree_args.universal then
    add_if_supported(uv, uv_args, "universal", { "--universal" })
  end
  if tree_args.show_sizes then
    add_if_supported(uv, uv_args, "show_sizes", { "--show-sizes" })
  end
  if tree_args.all_groups then
    add_if_supported(uv, uv_args, "all_groups", { "--all-groups" })
  end

  -- Add group filters
  for _, group in ipairs(tree_args.groups or {}) do
    if not add_if_supported(uv, uv_args, "group", { "--group", group }) then
      break
    end
  end

  for _, group in ipairs(tree_args.no_groups or {}) do
    if not add_if_supported(uv, uv_args, "no_group", { "--no-group", group }) then
      break
    end
  end

  return uv_args
end

---@param bufnr integer
---@param tree_args table
---@param args_str string
---@param opts table
---@return string?
local function resolve_tree_target(bufnr, tree_args, args_str, opts)
  local target = tree_args.target

  if not target then
    -- Try cursor dependency
    local deps = parse_buffer_deps(bufnr)
    local dep = util.dep_under_cursor(deps)
    target = dep and dep.name
  end

  -- Handle --reverse without target
  if tree_args.reverse and not target then
    vim.ui.input({ prompt = "pydeps: package name for reverse tree" }, function(input)
      if input and input ~= "" then
        M.tree("--package " .. input .. " " .. args_str, false, opts)
      end
    end)
    return nil
  end

  return target
end

---@param args_str string
---@param bang boolean
---@param opts? { anchor?: "center"|"cursor"|"hover", mode?: "split"|"float", width?: integer, height?: integer }
function M.tree(args_str, bang, opts)
  local uv = require("pydeps.providers.uv")
  if not uv.tree_features_ready() then
    uv.detect_tree_features(function()
      vim.schedule(function()
        M.tree(args_str, bang, opts)
      end)
    end)
    vim.notify("pydeps: detecting uv tree features...", vim.log.levels.INFO)
    return
  end

  local tree_args = require("pydeps.core.tree_args").parse(args_str, bang)
  local bufnr = current_buf()
  local root = project.find_root(bufnr)
  if not root then
    vim.notify("pydeps: project root not found", vim.log.levels.WARN)
    return
  end

  -- Validate lock file exists when in frozen mode
  if tree_args.frozen then
    if uv.supports_tree_flag("frozen") then
      local _, missing = cache.get_lockfile(root, { sync = true })
      if missing then
        vim.notify(
          "pydeps: uv.lock not found. Run :PyDepsResolve first, or use --resolve to skip frozen mode.",
          vim.log.levels.WARN
        )
        return
      end
    end
  end

  -- Resolve target: explicit flag -> positional -> cursor -> nil
  local target = resolve_tree_target(bufnr, tree_args, args_str, opts)
  if not target and tree_args.reverse then
    return
  end

  -- Build uv args with feature detection
  local uv_args = build_tree_args(tree_args, target)

  uv.tree({
    root = root,
    args = uv_args,
    anchor = opts and opts.anchor,
    mode = opts and opts.mode,
    width = opts and opts.width,
    height = opts and opts.height,
  })
end

---@param target? string
---@return nil
function M.provenance(target)
  local bufnr = current_buf()
  if not is_pyproject_buf(bufnr) and not target then
    vim.notify("pydeps: open pyproject.toml or pass a package name", vim.log.levels.WARN)
    return
  end
  local root = project.find_root(bufnr)
  if not root then
    vim.notify("pydeps: project root not found", vim.log.levels.WARN)
    return
  end
  local deps = parse_buffer_deps(bufnr)
  local dep = target and { name = target } or util.dep_under_cursor(deps)
  if not dep then
    vim.ui.input({ prompt = "pydeps: package name" }, function(input)
      if input and input ~= "" then
        local ok, err = pcall(M.provenance, input)
        if not ok then
          vim.notify(
            string.format("pydeps: failed to show provenance: %s", err or "unknown error"),
            vim.log.levels.ERROR
          )
        end
      end
    end)
    return
  end

  local lock_data, missing = cache.get_lockfile(root, { sync = true })
  if missing then
    vim.notify("pydeps: uv.lock not found", vim.log.levels.WARN)
    return
  end

  local ok, err = provenance_ui.show(dep.name, deps, lock_data.graph or {})
  if not ok then
    vim.notify(string.format("pydeps: failed to show provenance: %s", err or "unknown error"), vim.log.levels.ERROR)
  end
end

---@return nil
function M.info()
  local bufnr = current_buf()
  if not is_pyproject_buf(bufnr) then
    vim.notify("pydeps: open pyproject.toml to inspect dependencies", vim.log.levels.WARN)
    return
  end

  local deps = parse_buffer_deps(bufnr)
  local target = util.dep_under_cursor(deps)

  local root = project.find_root(bufnr)
  local resolved = {}
  local missing_lockfile = false
  if root then
    local lock_data, missing, loading = cache.get_lockfile(root)
    resolved = lock_data.resolved or {}
    missing_lockfile = missing
    if loading then
      missing_lockfile = false
    end
  end
  info.show(target, target and resolved[target.name] or nil, { lockfile_missing = missing_lockfile })
end

---@return nil
function M.audit()
  local bufnr = current_buf()
  local root = project.find_root(bufnr)
  if not root then
    vim.notify("pydeps: project root not found", vim.log.levels.WARN)
    return
  end

  local lock_data, missing = cache.get_lockfile(root, { sync = true })
  if missing then
    vim.notify("pydeps: uv.lock not found", vim.log.levels.WARN)
    return
  end

  local packages = collect_lock_packages(lock_data)
  if #packages == 0 then
    vim.notify("pydeps: no lockfile packages found", vim.log.levels.WARN)
    return
  end

  vim.notify("pydeps: running OSV audit", vim.log.levels.INFO)
  local osv = require("pydeps.providers.osv")
  local security_audit = require("pydeps.ui.security_audit")
  osv.audit(packages, function(results, err)
    local summary = security_audit.show(results, {
      root = root,
      error = err,
    })

    util.emit_user_autocmd("PyDepsAuditCompleted", {
      root = root,
      scanned = summary.scanned_packages,
      vulnerable_packages = summary.vulnerable_packages,
      vulnerabilities = summary.total_vulnerabilities,
      error = err,
    })

    if err then
      vim.notify("pydeps: OSV audit completed with errors: " .. err, vim.log.levels.WARN)
    end
  end)
end

---@return nil
function M.toggle()
  state.toggle()
end

return M
