local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local info_helpers = require("tests.info_helpers")

local T = helpers.create_test_set()

---@param view_overrides? table
---@param opts? PyDepsRenderOptions
---@param cache_opts? table
---@return string[]
local function render(view_overrides, opts, cache_opts)
  info_helpers.stub_cache(cache_opts)
  local render_lines = info_helpers.require_render_lines()
  return render_lines.build_lines(info_helpers.view(view_overrides), opts or {})
end

---@param lines string[]
---@param label string
---@return string?
local function value_of(lines, label)
  for _, line in ipairs(lines) do
    local value = line:match("^%S*%s*" .. label .. "%s+(.-)%s*$")
    if value then
      return value
    end
  end
  return nil
end

---@param packages string[][] lock package lines
---@return PyDepsLockfileData
local function lock_with(packages)
  local lines = { "version = 1", "" }
  for _, pkg in ipairs(packages) do
    vim.list_extend(lines, pkg)
  end
  return info_helpers.lock_data(lines)
end

T["render_lines shows description when available"] = function()
  local lines = render()
  MiniTest.expect.equality(lines[3]:match("HTTP library") ~= nil, true)
end

T["render_lines skips description when metadata summary is empty"] = function()
  local lines = render({
    meta = {
      info = {
        version = "1.0.0",
        summary = "",
      },
      releases = {},
    },
  })

  MiniTest.expect.equality(lines[2]:match("spec") ~= nil, true)
  MiniTest.expect.equality(lines[2]:match("HTTP library") ~= nil, false)
end

T["render_lines renders extras from group and spec only once"] = function()
  local dep = info_helpers.dep({
    spec = "testpkg[fast, speed]>=1.0",
    group = "optional:fast",
  })
  local lines = render({ dep = dep, spec = dep.spec, group = dep.group })

  MiniTest.expect.equality(value_of(lines, "extras"), "fast, speed")
end

T["render_lines renders markers when present"] = function()
  local dep = info_helpers.dep({
    spec = '>=1.0; python_version < "3.12"',
  })
  local lines = render({
    dep = dep,
    spec = dep.spec,
    marker = 'python_version < "3.12"',
  })

  local markers_line = table.concat(lines, "\n"):match("[^\n]*markers[^\n]*")
  MiniTest.expect.equality(markers_line ~= nil, true)
  MiniTest.expect.equality(markers_line:match('python_version < "3.12"') ~= nil, true)
end

T["render_lines always shows status even without environment section"] = function()
  local lines = render({
    dep = info_helpers.dep({ group = "project" }),
    marker = nil,
  })

  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*status[^\n]*") ~= nil, true)
end

T["render_lines always shows spec lock and latest"] = function()
  local lines = render()
  local output = table.concat(lines, "\n")

  MiniTest.expect.equality(output:match("[^\n]*spec[^\n]*") ~= nil, true)
  MiniTest.expect.equality(output:match("[^\n]*lock[^\n]*") ~= nil, true)
  MiniTest.expect.equality(output:match("[^\n]*latest[^\n]*") ~= nil, true)
end

T["render_lines shows missing lockfile text when lockfile is absent"] = function()
  local lines = render({ resolved = vim.NIL }, { lockfile_missing = true })
  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*lock[^\n]*%(missing%)") ~= nil, true)
end

T["render_lines shows loading while lockfile is refreshing"] = function()
  local lines = render({
    resolved = vim.NIL,
    class = "loading",
    status_text = "Loading",
  }, { lockfile_loading = true })

  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*lock[^\n]*%(loading%.%.%.%)") ~= nil, true)
  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*status[^\n]*Loading") ~= nil, true)
end

T["render_lines shows not found when dependency is not in lockfile"] = function()
  local lines = render({ resolved = vim.NIL }, { lockfile_missing = false })
  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*lock[^\n]*%(not found%)") ~= nil, true)
end

T["render_lines shows update suffix on latest when newer version exists"] = function()
  local lines = render({
    latest = "2.0.0",
    status_kind = "update",
    status_text = "update available",
    show_latest_warning = true,
    lock_status = vim.NIL,
  })

  MiniTest.expect.equality(value_of(lines, "latest"), "2.0.0    (update available)")
  MiniTest.expect.equality(value_of(lines, "lock"), "1.0.0")
end

T["render_lines renders an update built by dependency_view"] = function()
  info_helpers.stub_pypi()
  info_helpers.stub_cache()
  local dependency_view = require("pydeps.ui.dependency_view")
  local view = dependency_view.build(info_helpers.dep(), {
    current_env = {},
    resolved_version = "1.0.0",
    meta = { info = { version = "2.0.0", summary = "HTTP library" }, releases = {} },
  })
  local lines = info_helpers.require_render_lines().build_lines(view, {})

  MiniTest.expect.equality(value_of(lines, "lock"), "1.0.0")
  MiniTest.expect.equality(value_of(lines, "latest"), "2.0.0    (update available)")
  MiniTest.expect.equality(value_of(lines, "status"), "update available")
end

T["render_lines explains an inactive dependency under its status"] = function()
  local lines = render({
    current_env = { sys_platform = "darwin" },
    status_kind = "inactive",
    status_text = "inactive",
    inactive_reasons = { 'sys_platform == "win32" is false (sys_platform is "darwin")' },
  })

  local status_index
  for index, line in ipairs(lines) do
    if line:match("status%s+inactive") then
      status_index = index
    end
  end
  MiniTest.expect.no_equality(status_index, nil)
  MiniTest.expect.equality(
    vim.trim(lines[status_index + 1]),
    'sys_platform == "win32" is false (sys_platform is "darwin")'
  )
end

T["render_lines shows dependency count and shortcuts when lock graph is available"] = function()
  local dep = info_helpers.dep()
  local lines = render(nil, { root = "/fake/root" }, {
    dep = dep,
    lock_data = lock_with({
      info_helpers.lock_package_lines(dep.name, "1.0.0", { "dep1", "dep2", "dep3", "dep4" }),
      info_helpers.lock_package_lines("other", "1.0.0", { "dep1" }),
    }),
  })

  MiniTest.expect.equality(value_of(lines, "deps"), "4    (Enter: Why, gT: Tree)")
end

T["render_lines shows zero dependency count when package has no children"] = function()
  local dep = info_helpers.dep()
  local lines = render(nil, { root = "/fake/root" }, {
    dep = dep,
    lock_data = lock_with({ info_helpers.lock_package_lines(dep.name, "1.0.0") }),
  })

  MiniTest.expect.equality(value_of(lines, "deps"), "0    (Enter: Why, gT: Tree)")
end

T["render_lines shows unknown dependency count without lock data"] = function()
  local lines = render()
  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*deps[^\n]*%?[^\n]*") ~= nil, true)
end

T["render_lines shows PyPI URL when package metadata has a version"] = function()
  MiniTest.expect.equality(value_of(render(), "pypi"), "https://pypi.org/pypi/testpkg")

  require("pydeps.config").options.pypi_url = "https://mirror.example/pypi"
  local lines = render({ dep = { name = "otherpkg" } })
  MiniTest.expect.equality(value_of(lines, "pypi"), "https://mirror.example/pypi/otherpkg")
end

T["render_lines shows public PyPI miss message when metadata is unavailable"] = function()
  local lines = render({ meta = vim.NIL, latest = vim.NIL })
  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*pypi[^\n]*not found on public PyPI") ~= nil, true)
end

T["render_lines falls back to unknown when a custom status text is empty"] = function()
  require("pydeps.config").setup({ ui = { status_text = { loading = "" } } })
  info_helpers.stub_pypi()
  info_helpers.stub_cache()
  local view = require("pydeps.ui.dependency_view").build(info_helpers.dep(), {
    current_env = {},
    lockfile_loading = true,
    meta = { info = { version = "1.0.0" }, releases = {} },
  })
  local lines = info_helpers.require_render_lines().build_lines(view, { lockfile_loading = true })

  MiniTest.expect.equality(view.status_text, "")
  MiniTest.expect.equality(value_of(lines, "status"), "unknown")
end

return T
