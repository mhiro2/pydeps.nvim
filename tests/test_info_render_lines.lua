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

  local extras_line = table.concat(lines, "\n"):match("[^\n]*extras[^\n]*")
  MiniTest.expect.equality(extras_line ~= nil, true)
  MiniTest.expect.equality(extras_line:match("fast") ~= nil, true)
  MiniTest.expect.equality(extras_line:match("speed") ~= nil, true)
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
    lock_status = nil,
  })

  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*latest[^\n]*%(update available%)") ~= nil, true)
end

T["render_lines shows inactive python suffix"] = function()
  local lines = render({
    current_env = { python_full_version = "3.11.8" },
    status_kind = "inactive",
    status_text = "inactive",
  })

  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*status[^\n]*%(python 3%.11%.8%)") ~= nil, true)
end

T["render_lines shows dependency count and shortcuts when lock graph is available"] = function()
  local dep = info_helpers.dep()
  local lines = render(nil, { root = "/fake/root" }, {
    dep = dep,
    lock_data = {
      resolved = { [dep.name] = "1.0.0" },
      packages = {
        [dep.name] = {
          dependencies = { "dep1", "dep2", "dep3", "dep4" },
        },
      },
    },
  })

  local deps_line = table.concat(lines, "\n"):match("[^\n]*deps[^\n]*")
  MiniTest.expect.equality(deps_line ~= nil, true)
  MiniTest.expect.equality(deps_line:match("4") ~= nil, true)
  MiniTest.expect.equality(deps_line:match("Enter: Why") ~= nil, true)
  MiniTest.expect.equality(deps_line:match("gT: Tree") ~= nil, true)
end

T["render_lines shows zero dependency count when package has no children"] = function()
  local dep = info_helpers.dep()
  local lines = render(nil, { root = "/fake/root" }, {
    dep = dep,
    lock_data = {
      resolved = { [dep.name] = "1.0.0" },
      packages = {
        [dep.name] = {
          dependencies = {},
        },
      },
    },
  })

  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*deps[^\n]*0[^\n]*") ~= nil, true)
end

T["render_lines shows unknown dependency count without lock data"] = function()
  local lines = render()
  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*deps[^\n]*%?[^\n]*") ~= nil, true)
end

T["render_lines shows PyPI URL when package metadata has a version"] = function()
  local lines = render()
  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*pypi[^\n]*https://") ~= nil, true)
end

T["render_lines shows public PyPI miss message when metadata is unavailable"] = function()
  local lines = render({ meta = vim.NIL, latest = vim.NIL })
  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*pypi[^\n]*not found on public PyPI") ~= nil, true)
end

T["render_lines format_status_text falls back by kind"] = function()
  local render_lines = info_helpers.require_render_lines()

  MiniTest.expect.equality(render_lines.format_status_text({ kind = "ok", text = "" }), "active")
  MiniTest.expect.equality(render_lines.format_status_text({ kind = "update", text = "" }), "update available")
  MiniTest.expect.equality(render_lines.format_status_text({ kind = "warn", text = "" }), "lock mismatch")
  MiniTest.expect.equality(render_lines.format_status_text({ kind = "error", text = "" }), "yanked")
  MiniTest.expect.equality(render_lines.format_status_text({ kind = "inactive", text = "" }), "inactive")
  MiniTest.expect.equality(render_lines.format_status_text({ kind = "unknown", text = "" }), "unknown")
end

return T
