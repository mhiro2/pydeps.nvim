local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local lock_diff = require("pydeps.ui.lock_diff")

local T = helpers.create_test_set()

-- build_lines (flat) ---------------------------------------------------------

T["build_lines returns no-change message"] = function()
  local lines = lock_diff.build_lines({}, {})
  MiniTest.expect.equality(lines, { "No changes detected in uv.lock." })
end

T["build_lines shows added updated removed"] = function()
  local before = { a = "1.0", b = "1.0", c = "1.0" }
  local after = { a = "1.0", b = "2.0", d = "1.0" }
  local lines = lock_diff.build_lines(before, after)

  MiniTest.expect.equality(lines[1], "Summary: +1 ~1 -1")
  -- Updated section
  MiniTest.expect.equality(lines[3], "Updated:")
  MiniTest.expect.equality(lines[4], "  ~ b 1.0 -> 2.0")
  -- Added section
  MiniTest.expect.equality(lines[6], "Added:")
  MiniTest.expect.equality(lines[7], "  + d 1.0")
  -- Removed section
  MiniTest.expect.equality(lines[9], "Removed:")
  MiniTest.expect.equality(lines[10], "  - c 1.0")
end

-- build_grouped_lines --------------------------------------------------------

T["build_grouped_lines returns no-change message"] = function()
  local deps_list = { { name = "requests", spec = "requests>=2.0", group = "project" } }
  local lines = lock_diff.build_grouped_lines({}, {}, deps_list)
  MiniTest.expect.equality(lines, { "No changes detected in uv.lock." })
end

T["build_grouped_lines classifies direct and transitive"] = function()
  local deps_list = {
    { name = "requests", spec = "requests>=2.0", group = "project" },
  }
  local before = {}
  local after = { requests = "2.31.0", urllib3 = "2.0.0" }
  local lines = lock_diff.build_grouped_lines(before, after, deps_list)

  MiniTest.expect.equality(lines[1], "Summary: +2 ~0 -0")
  -- project group first
  MiniTest.expect.equality(lines[3], "[project]")
  MiniTest.expect.equality(lines[4], "  + requests 2.31.0")
  -- transitive group last
  MiniTest.expect.equality(lines[6], "[transitive]")
  MiniTest.expect.equality(lines[7], "  + urllib3 2.0.0")
end

T["build_grouped_lines handles optional groups"] = function()
  local deps_list = {
    { name = "requests", spec = "requests>=2.0", group = "project" },
    { name = "pytest", spec = "pytest>=7.0", group = "optional:dev" },
  }
  local before = { requests = "2.0.0", pytest = "7.0.0" }
  local after = { requests = "2.1.0", pytest = "8.0.0" }
  local lines = lock_diff.build_grouped_lines(before, after, deps_list)

  MiniTest.expect.equality(lines[1], "Summary: +0 ~2 -0")
  -- project first
  MiniTest.expect.equality(lines[3], "[project]")
  MiniTest.expect.equality(lines[4], "  ~ requests 2.0.0 -> 2.1.0")
  -- optional:dev second
  MiniTest.expect.equality(lines[6], "[dev]  (optional)")
  MiniTest.expect.equality(lines[7], "  ~ pytest 7.0.0 -> 8.0.0")
end

T["build_grouped_lines handles dependency-groups"] = function()
  local deps_list = {
    { name = "ruff", spec = "ruff>=0.1", group = "group:lint" },
  }
  local before = {}
  local after = { ruff = "0.3.0" }
  local lines = lock_diff.build_grouped_lines(before, after, deps_list)

  MiniTest.expect.equality(lines[3], "[lint]  (group)")
  MiniTest.expect.equality(lines[4], "  + ruff 0.3.0")
end

T["build_grouped_lines all transitive"] = function()
  local deps_list = {}
  local before = { foo = "1.0" }
  local after = { bar = "2.0" }
  local lines = lock_diff.build_grouped_lines(before, after, deps_list)

  MiniTest.expect.equality(lines[1], "Summary: +1 ~0 -1")
  MiniTest.expect.equality(lines[3], "[transitive]")
  MiniTest.expect.equality(lines[4], "  + bar 2.0")
  MiniTest.expect.equality(lines[5], "  - foo 1.0")
end

-- show() integration ---------------------------------------------------------

T["show uses grouped lines when root has pyproject.toml"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({
    "[project]",
    'name = "test"',
    'dependencies = ["requests>=2.0"]',
  }, dir .. "/pyproject.toml")

  local captured_lines
  local output = require("pydeps.ui.output")
  local orig_show = output.show
  output.show = function(_, lines)
    captured_lines = lines
  end

  lock_diff.show({}, { requests = "2.31.0", urllib3 = "2.0.0" }, { root = dir })

  output.show = orig_show
  vim.fn.delete(dir, "rf")

  MiniTest.expect.no_equality(captured_lines, nil)
  MiniTest.expect.equality(captured_lines[3], "[project]")
  MiniTest.expect.equality(captured_lines[4], "  + requests 2.31.0")
  MiniTest.expect.equality(captured_lines[6], "[transitive]")
  MiniTest.expect.equality(captured_lines[7], "  + urllib3 2.0.0")
end

T["show uses grouped lines with empty deps_list"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({
    "[project]",
    'name = "test"',
  }, dir .. "/pyproject.toml")

  local captured_lines
  local output = require("pydeps.ui.output")
  local orig_show = output.show
  output.show = function(_, lines)
    captured_lines = lines
  end

  lock_diff.show({}, { foo = "1.0" }, { root = dir })

  output.show = orig_show
  vim.fn.delete(dir, "rf")

  MiniTest.expect.no_equality(captured_lines, nil)
  MiniTest.expect.equality(captured_lines[3], "[transitive]")
  MiniTest.expect.equality(captured_lines[4], "  + foo 1.0")
end

T["build_grouped_lines orders updated before added before removed within group"] = function()
  local deps_list = {
    { name = "a", spec = "a", group = "project" },
    { name = "b", spec = "b", group = "project" },
    { name = "c", spec = "c", group = "project" },
  }
  local before = { a = "1.0", c = "1.0" }
  local after = { a = "2.0", b = "1.0" }
  local lines = lock_diff.build_grouped_lines(before, after, deps_list)

  MiniTest.expect.equality(lines[3], "[project]")
  MiniTest.expect.equality(lines[4], "  ~ a 1.0 -> 2.0") -- updated
  MiniTest.expect.equality(lines[5], "  + b 1.0") -- added
  MiniTest.expect.equality(lines[6], "  - c 1.0") -- removed
end

return T
