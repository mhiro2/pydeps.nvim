local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

local function create_project(lines, packages)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/pyproject.toml"
  vim.fn.writefile(lines, path)
  helpers.create_uv_lock(dir, packages)
  vim.cmd("edit " .. path)
  helpers.setup_buffer(lines)
  helpers.defer(function()
    vim.fn.delete(dir, "rf")
  end)
  return dir, path
end

---@param path string
---@return string
local function realpath(path)
  return vim.uv.fs_realpath(path) or path
end

---@return { messages: string[], levels: integer[] }
local function capture_notify()
  local captured = { messages = {}, levels = {} }
  helpers.stub(vim, "notify", function(msg, level)
    table.insert(captured.messages, msg)
    table.insert(captured.levels, level)
  end)
  return captured
end

---@param captured { messages: string[] }
---@param pattern string
---@return boolean
local function notified(captured, pattern)
  for _, msg in ipairs(captured.messages) do
    if msg:find(pattern) then
      return true
    end
  end
  return false
end

---@return { results: table?, opts: table? }
local function stub_osv_audit(results)
  local captured = {}
  helpers.stub_module("pydeps.providers.osv", {
    audit = function(packages, cb)
      captured.packages = packages
      if results then
        cb(results, nil)
      end
    end,
  })
  return captured
end

T["audit sends lockfile packages to OSV and reports the summary"] = function()
  local osv = stub_osv_audit({
    {
      name = "requests",
      version = "2.31.0",
      status = "vulnerable",
      vulnerabilities = {
        { id = "GHSA-1234", summary = "Leak", severity = "HIGH", severity_scores = {}, aliases = {} },
        { id = "GHSA-5678", summary = "Crash", severity = "LOW", severity_scores = {}, aliases = {} },
      },
    },
    { name = "urllib3", version = "2.2.0", status = "clean", vulnerabilities = {} },
  })
  local shown
  helpers.stub(require("pydeps.ui.output"), "show", function(title, lines)
    shown = { title = title, lines = lines }
  end)
  local events = {}
  local autocmd = vim.api.nvim_create_autocmd("User", {
    pattern = "PyDepsAuditCompleted",
    callback = function(args)
      table.insert(events, args.data)
    end,
  })
  helpers.defer(function()
    vim.api.nvim_del_autocmd(autocmd)
  end)
  local dir = create_project({
    "[project]",
    'dependencies = ["requests", "urllib3"]',
  }, {
    requests = "2.31.0",
    urllib3 = "2.2.0",
  })

  vim.cmd("PyDepsAudit")
  helpers.wait_for(function()
    return #events == 1
  end, "PyDepsAuditCompleted")

  MiniTest.expect.equality(osv.packages, {
    { name = "requests", version = "2.31.0" },
    { name = "urllib3", version = "2.2.0" },
  })
  MiniTest.expect.equality(shown.title, "PyDeps Audit")
  MiniTest.expect.equality(vim.list_slice(shown.lines, 1, 6), {
    "PyDeps Security Audit (OSV)",
    "Scanned packages: 2",
    "Failed packages: 0",
    "Not scanned packages: 0",
    "Packages with vulnerabilities: 1",
    "Total vulnerabilities: 2",
  })
  MiniTest.expect.equality(vim.tbl_contains(shown.lines, "  requests@2.31.0 (2)"), true)
  MiniTest.expect.equality(realpath(events[1].root), realpath(dir))
  events[1].root = nil
  MiniTest.expect.equality(events[1], { scanned = 2, vulnerable_packages = 1, vulnerabilities = 2 })
end

T["audit includes every universal version and deduplicates sources"] = function()
  local osv = stub_osv_audit(nil)
  local dir = create_project({ "[project]", 'dependencies = ["demo"]' })
  vim.fn.writefile(vim.fn.readfile("tests/fixtures/fork.uv.lock"), dir .. "/uv.lock")
  require("pydeps.core.cache").invalidate_lockfile(dir)
  require("pydeps.commands").audit()
  local found = {}
  for _, pkg in ipairs(osv.packages or {}) do
    found[#found + 1] = pkg.name .. "@" .. pkg.version
  end
  MiniTest.expect.equality(found, { "app@0.1.0", "child@3.0", "demo@1.0", "demo@2.0", "same@1.0", "tester@1.0" })
end

T["audit warns when uv.lock is missing"] = function()
  local osv = stub_osv_audit(nil)
  local captured = capture_notify()
  local dir = create_project({
    "[project]",
    'dependencies = ["requests"]',
  }, {
    requests = "2.31.0",
  })
  vim.fn.delete(dir .. "/uv.lock")

  require("pydeps.commands").audit()

  MiniTest.expect.equality(notified(captured, "uv%.lock not found"), true)
  MiniTest.expect.equality(osv.packages, nil)
end

T["provenance uses project dependencies outside pyproject buffers"] = function()
  local captured = nil
  helpers.stub_module("pydeps.commands", nil)
  helpers.stub_module("pydeps.commands.provenance", nil)
  helpers.stub_module("pydeps.ui.provenance", {
    show = function(target, deps, graph)
      captured = {
        target = target,
        deps = deps,
        graph = graph,
      }
      return true
    end,
  })

  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["requests>=2.31", "rich>=13"]',
  }, {
    requests = "2.31.0",
    rich = "13.7.0",
  })
  local script_path = dir .. "/app.py"
  vim.fn.writefile({ "print('hello')" }, script_path)

  local script_buf = vim.fn.bufadd(script_path)
  vim.fn.bufload(script_buf)
  vim.api.nvim_set_current_buf(script_buf)

  commands.provenance("requests")

  MiniTest.expect.equality(captured ~= nil, true)
  MiniTest.expect.equality(captured.target, "requests")
  MiniTest.expect.equality(#captured.deps, 2)
  MiniTest.expect.equality(captured.deps[1].name, "requests")
  MiniTest.expect.equality(captured.deps[2].name, "rich")
end

T["info preserves lockfile loading state"] = function()
  local captured = nil
  helpers.stub_module("pydeps.core.cache", {
    get_pyproject = function()
      return {
        {
          name = "requests",
          spec = "requests>=2.31",
          line = 2,
          col_start = 18,
          col_end = 25,
        },
      }
    end,
    get_lockfile = function()
      return { resolved = {} }, false, true
    end,
  })
  helpers.stub_module("pydeps.commands", nil)
  helpers.stub_module("pydeps.commands.info", nil)
  helpers.stub_module("pydeps.ui.info", {
    show = function(dep, resolved, opts)
      captured = {
        dep = dep,
        resolved = resolved,
        opts = opts,
      }
    end,
  })

  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["requests>=2.31"]',
  })

  vim.api.nvim_win_set_cursor(0, { 2, 18 })
  commands.info()

  MiniTest.expect.equality(captured ~= nil, true)
  MiniTest.expect.equality(captured.dep.name, "requests")
  MiniTest.expect.equality(captured.opts.lockfile_loading, true)
  MiniTest.expect.equality(captured.opts.lockfile_missing, false)
  MiniTest.expect.equality(realpath(captured.opts.root), realpath(dir))
end

-- `uv tree --help` output listing every flag the command knows except those
-- in `unsupported`.
---@param unsupported? string[]
---@return string
local function tree_help(unsupported)
  local flags = {
    "--frozen",
    "--package",
    "--depth",
    "--invert",
    "--universal",
    "--show-sizes",
    "--all-groups",
    "--group",
    "--no-group",
    "--no-default-groups",
    "--python-version",
    "--python-platform",
  }
  local lines = { "Usage: uv tree [OPTIONS]" }
  for _, flag in ipairs(flags) do
    if not vim.tbl_contains(unsupported or {}, flag) then
      table.insert(lines, "      " .. flag)
    end
  end
  return table.concat(lines, "\n")
end

-- Run the real tree command against a stubbed uv binary and capture what
-- would be spawned.
---@param unsupported? string[]
---@return { runs: table[] }
local function stub_uv_tree(unsupported)
  local spy = { runs = {} }
  local original_executable = vim.fn.executable
  helpers.stub(vim.fn, "executable", function(cmd)
    if cmd == "uv" then
      return 1
    end
    return original_executable(cmd)
  end)
  helpers.stub(vim, "system", function(_, _, on_exit)
    on_exit({ code = 0, stdout = tree_help(unsupported), stderr = "" })
  end)
  helpers.stub(require("pydeps.ui.output"), "run_command", function(cmd, opts)
    table.insert(spy.runs, { cmd = cmd, cwd = opts.cwd, on_exit = opts.on_exit })
  end)
  local uv = require("pydeps.providers.uv")
  uv._clear_tree_features_cache()
  uv.detect_tree_features()
  helpers.wait_for(uv.tree_features_ready, "uv tree feature detection")
  return spy
end

T["tree passes parsed options to uv tree"] = function()
  local dir = create_project({
    "[project]",
    'dependencies = ["requests>=2"]',
  })
  local cases = {
    { cmd = "PyDepsTree --reverse requests", args = { "--frozen", "--package", "requests", "--invert" } },
    { cmd = "PyDepsTree --invert requests", args = { "--frozen", "--package", "requests", "--invert" } },
    { cmd = "PyDepsTree! requests", args = { "--frozen", "--package", "requests", "--invert" } },
    {
      cmd = "PyDepsTree requests --depth 2 --universal --show-sizes --all-groups --group dev --no-group test",
      args = {
        "--frozen",
        "--package",
        "requests",
        "--depth",
        "2",
        "--universal",
        "--show-sizes",
        "--all-groups",
        "--group",
        "dev",
        "--no-group",
        "test",
      },
    },
    { cmd = "PyDepsTree --resolve", args = {} },
  }
  local spy = stub_uv_tree()
  for _, case in ipairs(cases) do
    spy.runs = {}
    vim.cmd(case.cmd)
    MiniTest.expect.equality(#spy.runs, 1)
    MiniTest.expect.equality(spy.runs[1].cmd, vim.list_extend({ "uv", "tree" }, case.args))
    MiniTest.expect.equality(realpath(spy.runs[1].cwd), realpath(dir))
  end
end

T["tree filters for the shared context unless the command chooses itself"] = function()
  local dir = create_project({
    "[project]",
    'dependencies = ["requests>=2"]',
    "",
    "[dependency-groups]",
    'test = ["pytest>=8"]',
  })
  local context = require("pydeps.core.context")
  helpers.defer(context._clear)
  local root = require("pydeps.core.buffer_context").find_root(vim.api.nvim_get_current_buf())
  context.set(root, "python", "3.11")
  context.set(root, "platform", "linux")
  context.set(root, "groups", { "test" })
  local spy = stub_uv_tree()

  local cases = {
    {
      cmd = "PyDepsTree",
      args = {
        "--frozen",
        "--python-version",
        "3.11",
        "--python-platform",
        "linux",
        "--no-default-groups",
        "--group",
        "test",
      },
    },
    { cmd = "PyDepsTree --universal", args = { "--frozen", "--universal" } },
    {
      cmd = "PyDepsTree --group dev",
      args = { "--frozen", "--group", "dev", "--python-version", "3.11", "--python-platform", "linux" },
    },
  }
  for _, case in ipairs(cases) do
    spy.runs = {}
    vim.cmd(case.cmd)
    MiniTest.expect.equality(spy.runs[1].cmd, vim.list_extend({ "uv", "tree" }, case.args))
    MiniTest.expect.equality(realpath(spy.runs[1].cwd), realpath(dir))
  end
end

T["tree warns on unknown options and still invokes uv tree"] = function()
  local spy = stub_uv_tree()
  local captured = capture_notify()
  create_project({
    "[project]",
    'dependencies = ["requests>=2"]',
  })

  require("pydeps.commands").tree("--unknown requests", false, {})

  MiniTest.expect.equality(notified(captured, "unknown tree options: %-%-unknown"), true)
  MiniTest.expect.equality(spy.runs[1].cmd, { "uv", "tree", "--frozen", "--package", "requests" })
end

T["tree drops flags the installed uv does not support"] = function()
  local spy = stub_uv_tree({ "--invert", "--package" })
  local captured = capture_notify()
  create_project({
    "[project]",
    'dependencies = ["requests>=2"]',
  })

  require("pydeps.commands").tree("--reverse requests --depth 1", false, {})

  MiniTest.expect.equality(notified(captured, "%-%-invert not supported"), true)
  -- Without --package the target is passed positionally.
  MiniTest.expect.equality(spy.runs[1].cmd, { "uv", "tree", "--frozen", "requests", "--depth", "1" })
end

T["tree warns when uv cannot run frozen"] = function()
  local spy = stub_uv_tree({ "--frozen" })
  local captured = capture_notify()
  create_project({
    "[project]",
    'dependencies = ["requests>=2"]',
  })

  require("pydeps.commands").tree("requests", false, {})

  MiniTest.expect.equality(notified(captured, "%-%-frozen not supported"), true)
  MiniTest.expect.equality(vim.tbl_contains(captured.levels, vim.log.levels.WARN), true)
  MiniTest.expect.equality(spy.runs[1].cmd, { "uv", "tree", "--package", "requests" })
  MiniTest.expect.equality(type(spy.runs[1].on_exit), "function")
end

T["tree reports uv.lock rewritten by a resolving run"] = function()
  local spy = stub_uv_tree()
  local dir = create_project({
    "[project]",
    'dependencies = ["requests>=2"]',
  }, { requests = "2.31.0" })
  local refreshed = 0
  helpers.stub(require("pydeps.core.state"), "refresh_all", function()
    refreshed = refreshed + 1
  end)
  local captured = capture_notify()

  vim.cmd("PyDepsTree")
  MiniTest.expect.equality(spy.runs[1].on_exit, nil)

  vim.cmd("PyDepsTree --resolve")
  spy.runs[2].on_exit(0)
  MiniTest.expect.equality(notified(captured, "updated uv.lock"), false)
  MiniTest.expect.equality(refreshed, 0)

  vim.cmd("PyDepsTree --resolve")
  helpers.create_uv_lock(dir, { requests = "2.32.10" })
  spy.runs[3].on_exit(0)
  MiniTest.expect.equality(notified(captured, "uv tree updated uv.lock"), true)
  MiniTest.expect.equality(refreshed, 1)

  vim.fn.delete(dir .. "/uv.lock")
  vim.cmd("PyDepsTree --resolve")
  helpers.create_uv_lock(dir, { requests = "2.32.10" })
  spy.runs[4].on_exit(0)
  MiniTest.expect.equality(refreshed, 2)
end

local PINNED_MTIME = 1700000000

---@param dir string
---@param version string
local function write_lock_with_pinned_stat(dir, version)
  local path = dir .. "/uv.lock"
  helpers.create_uv_lock(dir, { requests = version })
  -- Equal size and mtime across rewrites: only an explicit invalidation can
  -- reveal the change to the lockfile cache.
  vim.uv.fs_utime(path, PINNED_MTIME, PINNED_MTIME)
end

---@return { opts: table?, refresh_all: integer, diffs: table[] }
local function stub_resolve_deps()
  local spy = { refresh_all = 0, diffs = {} }
  helpers.stub_module("pydeps.providers.uv", {
    resolve = function(opts)
      spy.opts = opts
    end,
  })
  helpers.stub(require("pydeps.ui.lock_diff"), "show", function(before, after, opts)
    table.insert(spy.diffs, { before = before, after = after, opts = opts })
  end)
  helpers.stub(require("pydeps.core.state"), "refresh_all", function()
    spy.refresh_all = spy.refresh_all + 1
  end)
  return spy
end

T["resolve snapshots the lockfile, reloads it after uv lock and shows the diff"] = function()
  local spy = stub_resolve_deps()
  capture_notify()
  local dir = create_project({ "[project]", 'dependencies = ["requests"]' }, { requests = "2.31.0" })
  write_lock_with_pinned_stat(dir, "2.31.0")
  local cache = require("pydeps.core.cache")
  MiniTest.expect.equality(cache.get_lockfile(dir, { sync = true }).resolved.requests, "2.31.0")

  vim.cmd("PyDepsResolve")

  MiniTest.expect.equality(realpath(spy.opts.root), realpath(dir))
  MiniTest.expect.equality(cache.get_lock_snapshot(dir), { requests = "2.31.0" })
  MiniTest.expect.equality(spy.refresh_all, 0)

  write_lock_with_pinned_stat(dir, "2.32.0")
  spy.opts.on_finish({ ok = true, code = 0 })

  MiniTest.expect.equality(#spy.diffs, 1)
  MiniTest.expect.equality(spy.diffs[1].before, { requests = "2.31.0" })
  MiniTest.expect.equality(spy.diffs[1].after, { requests = "2.32.0" })
  MiniTest.expect.equality(cache.get_lock_snapshot(dir), { requests = "2.32.0" })
  MiniTest.expect.equality(spy.refresh_all, 1)
end

T["resolve reports uv lock failures without touching the snapshot"] = function()
  local spy = stub_resolve_deps()
  local captured = capture_notify()
  local dir = create_project({ "[project]", 'dependencies = ["requests"]' }, { requests = "2.31.0" })

  require("pydeps.commands").resolve()
  spy.opts.on_finish({ ok = false, code = 2, reason = "exit", stderr = "no solution" })

  MiniTest.expect.equality(notified(captured, "uv lock failed %(exit code 2%)\nno solution"), true)
  MiniTest.expect.equality(spy.diffs, {})
  MiniTest.expect.equality(spy.refresh_all, 0)
  MiniTest.expect.equality(require("pydeps.core.cache").get_lock_snapshot(dir), { requests = "2.31.0" })
end

T["resolve! shows the diff against the last snapshot without running uv"] = function()
  local spy = stub_resolve_deps()
  local captured = capture_notify()
  local dir = create_project({ "[project]", 'dependencies = ["requests"]' }, { requests = "2.32.0" })

  vim.cmd("PyDepsResolve!")
  MiniTest.expect.equality(notified(captured, "no previous lockfile snapshot"), true)
  MiniTest.expect.equality(spy.diffs, {})
  MiniTest.expect.equality(spy.refresh_all, 1)

  require("pydeps.core.cache").set_lock_snapshot(dir, { requests = "2.31.0" })
  vim.cmd("PyDepsResolve!")

  MiniTest.expect.equality(spy.opts, nil)
  MiniTest.expect.equality(#spy.diffs, 1)
  MiniTest.expect.equality(spy.diffs[1].before, { requests = "2.31.0" })
  MiniTest.expect.equality(spy.diffs[1].after, { requests = "2.32.0" })
  MiniTest.expect.equality(spy.refresh_all, 2)
end

return T
