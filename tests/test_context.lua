local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

local DETECTED = {
  python_version = "3.13",
  python_full_version = "3.13.1",
  implementation_name = "cpython",
  implementation_version = "3.13.1",
  sys_platform = "darwin",
  platform_system = "Darwin",
  platform_machine = "arm64",
  platform_release = "24.0.0",
  os_name = "posix",
}

local PYPROJECT = {
  "[project]",
  'name = "app"',
  'dependencies = ["requests>=2", "pywin32>=306; sys_platform == \'win32\'"]',
  "",
  "[project.optional-dependencies]",
  'postgres = ["psycopg>=3"]',
  "empty = []",
  "",
  "[dependency-groups]",
  'test = ["pytest>=8"]',
  'ci = [{ include-group = "test" }, "coverage>=7"]',
  'lint = ["ruff>=0.5"]',
}

---@return string root
local function create_project()
  local root = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  vim.fn.writefile(PYPROJECT, root .. "/pyproject.toml")
  helpers.defer(function()
    vim.fn.delete(root, "rf")
  end)
  return root
end

---@return table context
local function fresh_context()
  helpers.stub(require("pydeps.core.env"), "get", function()
    return vim.deepcopy(DETECTED)
  end)
  local context = require("pydeps.core.context")
  context._clear()
  helpers.defer(context._clear)
  return context
end

T["env keeps the detected environment until a field is overridden"] = function()
  local context = fresh_context()
  local root = create_project()

  MiniTest.expect.equality(context.env(root), DETECTED)
  MiniTest.expect.equality(context.overrides(root), {})
end

T["python override follows uv and maps a minor version to its first patch"] = function()
  local context = fresh_context()
  local root = create_project()

  MiniTest.expect.equality(context.set(root, "python", "3.11"), true)
  local current = context.env(root)
  MiniTest.expect.equality(current.python_version, "3.11")
  MiniTest.expect.equality(current.python_full_version, "3.11.0")
  MiniTest.expect.equality(current.implementation_version, "3.11.0")

  context.set(root, "python", "3.10.14")
  MiniTest.expect.equality(context.env(root).python_full_version, "3.10.14")

  local ok, err = context.set(root, "python", "three")
  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(err:match("python must be a version") ~= nil, true)
end

T["platform override sets every OS marker and drops release details"] = function()
  local context = fresh_context()
  local root = create_project()

  context.set(root, "platform", "windows")
  local current = context.env(root)
  MiniTest.expect.equality(current.sys_platform, "win32")
  MiniTest.expect.equality(current.platform_system, "Windows")
  MiniTest.expect.equality(current.os_name, "nt")
  MiniTest.expect.equality(current.platform_machine, "AMD64")
  MiniTest.expect.equality(current.platform_release, nil)

  context.set(root, "platform", "aarch64-unknown-linux-gnu")
  MiniTest.expect.equality(context.env(root).platform_machine, "aarch64")
  MiniTest.expect.equality(context.env(root).sys_platform, "linux")

  local ok = context.set(root, "platform", "plan9")
  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(context.overrides(root).platform, "aarch64-unknown-linux-gnu")
end

T["extras and groups are validated, normalized and expand included groups"] = function()
  local context = fresh_context()
  local root = create_project()

  local ok, err = context.set(root, "extras", { "mysql" })
  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(err, "unknown extra 'mysql'")

  MiniTest.expect.equality(context.set(root, "extras", { "Postgres", "postgres" }), true)
  MiniTest.expect.equality(context.env(root).extras, { "postgres" })

  context.set(root, "groups", { "ci" })
  MiniTest.expect.equality(context.env(root).dependency_groups, { "ci", "test" })

  context.set(root, "groups", {})
  MiniTest.expect.equality(context.env(root).dependency_groups, {})
  MiniTest.expect.equality(context.summary(root), "python 3.13.1 · darwin · extras postgres · groups none")
end

T["excluded_reason reports declared sections outside the selection"] = function()
  local context = fresh_context()
  local root = create_project()
  local postgres = { name = "psycopg", spec = "psycopg>=3", group = "optional:postgres" }
  local pytest = { name = "pytest", spec = "pytest>=8", group = "group:test" }
  local ruff = { name = "ruff", spec = "ruff>=0.5", group = "group:lint" }

  MiniTest.expect.equality(context.excluded_reason(postgres, context.env(root)), nil)

  context.set(root, "extras", {})
  context.set(root, "groups", { "ci" })
  local current = context.env(root)
  MiniTest.expect.equality(context.excluded_reason(postgres, current), 'extra "postgres" is not selected')
  MiniTest.expect.equality(context.excluded_reason(pytest, current), nil)
  MiniTest.expect.equality(context.excluded_reason(ruff, current), 'group "lint" is not selected')
end

T["reset drops one field or the whole context"] = function()
  local context = fresh_context()
  local root = create_project()

  context.set(root, "python", "3.11")
  context.set(root, "platform", "linux")
  context.reset(root, "python")
  MiniTest.expect.equality(context.overrides(root), { platform = "linux" })

  context.reset(root)
  MiniTest.expect.equality(context.overrides(root), {})
  MiniTest.expect.equality(context.env(root), DETECTED)
end

T["dependency view follows the context and explains why a dependency is inactive"] = function()
  local context = fresh_context()
  local root = create_project()
  local dependency_view = require("pydeps.ui.dependency_view")
  local pywin32 = { name = "pywin32", spec = "pywin32>=306; sys_platform == 'win32'", group = "project" }

  local view = dependency_view.build(pywin32, { root = root, resolved_version = "306" })
  MiniTest.expect.equality(view.class, "inactive")
  MiniTest.expect.equality(view.inactive_reasons, { 'sys_platform == "win32" is false (sys_platform is "darwin")' })

  context.set(root, "platform", "windows")
  view = dependency_view.build(pywin32, { root = root, resolved_version = "306" })
  MiniTest.expect.equality(view.active, true)
  MiniTest.expect.equality(view.inactive_reasons, {})

  context.set(root, "extras", {})
  view = dependency_view.build(
    { name = "psycopg", spec = "psycopg>=3", group = "optional:postgres" },
    { root = root, resolved_version = "3.2.0" }
  )
  MiniTest.expect.equality(view.class, "inactive")
  MiniTest.expect.equality(view.inactive_reasons, { 'extra "postgres" is not selected' })
end

T["changing the context notifies listeners"] = function()
  local context = fresh_context()
  local root = create_project()
  local received = {}
  local group = vim.api.nvim_create_augroup("PyDepsContextTest", { clear = true })
  helpers.defer(function()
    vim.api.nvim_del_augroup_by_id(group)
  end)
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "PyDepsContextChanged",
    callback = function(args)
      table.insert(received, args.data.root)
    end,
  })

  context.set(root, "python", "3.12")
  helpers.wait_for(function()
    return #received == 1
  end, "PyDepsContextChanged")
  MiniTest.expect.equality(received, { root })
end

T[":PyDepsContext sets fields and completes declared names"] = function()
  fresh_context()
  local root = create_project()
  vim.cmd("edit " .. root .. "/pyproject.toml")
  local messages = {}
  helpers.stub(vim, "notify", function(msg)
    table.insert(messages, msg)
  end)

  vim.cmd("PyDepsContext groups ci,lint")
  vim.cmd("PyDepsContext extras none")
  vim.cmd("PyDepsContext platform linux")
  local context = require("pydeps.core.context")
  MiniTest.expect.equality(context.overrides(root), { groups = { "ci", "lint" }, extras = {}, platform = "linux" })
  MiniTest.expect.equality(
    messages[#messages],
    "pydeps: context python 3.13.1 · linux · extras none · groups ci, lint"
  )

  vim.cmd("PyDepsContext extras all")
  MiniTest.expect.equality(context.overrides(root).extras, nil)

  vim.cmd("PyDepsContext reset")
  MiniTest.expect.equality(context.overrides(root), {})

  local complete = require("pydeps.commands").complete_context
  MiniTest.expect.equality(complete("", "PyDepsContext "), { "reset", "python", "platform", "extras", "groups" })
  MiniTest.expect.equality(complete("p", "PyDepsContext p"), { "python", "platform" })
  MiniTest.expect.equality(complete("", "PyDepsContext groups "), { "all", "none", "test", "ci", "lint" })
  MiniTest.expect.equality(complete("pos", "PyDepsContext extras pos"), { "postgres" })
  MiniTest.expect.equality(complete("win", "PyDepsContext platform win"), { "windows" })
end

return T
