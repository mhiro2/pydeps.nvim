local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local tree_ui = require("pydeps.ui.tree")

local T = helpers.create_test_set()

T["extract packages from simple tree"] = function()
  local lines = {
    "requests 2.31.0",
    "├── charset-normalizer 3.3.2",
    "├── idna 3.6",
    "└── urllib3 2.0.7",
  }

  local packages = tree_ui.extract_packages(lines)

  MiniTest.expect.equality(packages[1], "requests")
  MiniTest.expect.equality(packages[2], "charset-normalizer")
  MiniTest.expect.equality(packages[3], "idna")
  MiniTest.expect.equality(packages[4], "urllib3")
end

T["extract packages from complex tree"] = function()
  local lines = {
    "requests 2.31.0",
    "│   ├── certifi 2023.7.22",
    "│   └── urllib3 2.0.7",
    "└── (*)",
  }

  local packages = tree_ui.extract_packages(lines)

  MiniTest.expect.equality(packages[1], "requests")
  MiniTest.expect.equality(packages[2], "certifi")
  MiniTest.expect.equality(packages[3], "urllib3")
  -- Line 4 has (*) which should be skipped
  MiniTest.expect.equality(packages[4], nil)
end

T["handle lines without packages"] = function()
  local lines = {
    "requests 2.31.0",
    "    ",
    "├── Some text without package",
    "└── urllib3 2.0.7",
  }

  local packages = tree_ui.extract_packages(lines)

  MiniTest.expect.equality(packages[1], "requests")
  MiniTest.expect.equality(packages[2], nil) -- empty line
  MiniTest.expect.equality(packages[3], nil) -- no package
  MiniTest.expect.equality(packages[4], "urllib3")
end

T["extract package with underscores"] = function()
  local lines = {
    "some_package_name 1.0.0",
  }

  local packages = tree_ui.extract_packages(lines)

  MiniTest.expect.equality(packages[1], "some_package_name")
end

T["extract package with hyphens"] = function()
  local lines = {
    "some-package-name 1.0.0",
  }

  local packages = tree_ui.extract_packages(lines)

  MiniTest.expect.equality(packages[1], "some-package-name")
end

T["extract package with dots"] = function()
  local lines = {
    "some.package.name 1.0.0",
  }

  local packages = tree_ui.extract_packages(lines)

  MiniTest.expect.equality(packages[1], "some.package.name")
end

T["skip pure asterisk lines"] = function()
  local lines = {
    "requests 2.31.0",
    "(*)",
  }

  local packages = tree_ui.extract_packages(lines)

  MiniTest.expect.equality(packages[1], "requests")
  MiniTest.expect.equality(packages[2], nil)
end

T["handle deeply nested tree"] = function()
  local lines = {
    "requests 2.31.0",
    "│   ├── certifi 2023.7.22",
    "│   │   └── urllib3 2.0.7",
    "│   └── idna 3.6",
  }

  local packages = tree_ui.extract_packages(lines)

  MiniTest.expect.equality(packages[1], "requests")
  MiniTest.expect.equality(packages[2], "certifi")
  MiniTest.expect.equality(packages[3], "urllib3")
  MiniTest.expect.equality(packages[4], "idna")
end

-- Tests for version strings with "v" prefix (uv output format)
T["extract package with v prefix version"] = function()
  local lines = {
    "pydantic v2.12.5",
  }

  local packages = tree_ui.extract_packages(lines)

  MiniTest.expect.equality(packages[1], "pydantic")
end

T["extract packages from tree with v prefix versions"] = function()
  local lines = {
    "pydantic v2.12.5",
    "├── annotated-types v0.7.0",
    "├── pydantic-core v2.41.5",
    "│   └── typing-extensions v4.15.0",
  }

  local packages = tree_ui.extract_packages(lines)

  MiniTest.expect.equality(packages[1], "pydantic")
  MiniTest.expect.equality(packages[2], "annotated-types")
  MiniTest.expect.equality(packages[3], "pydantic-core")
  MiniTest.expect.equality(packages[4], "typing-extensions")
end

T["extract packages with mixed version formats"] = function()
  local lines = {
    "package-old 1.0.0",
    "package-new v2.0.0",
  }

  local packages = tree_ui.extract_packages(lines)

  MiniTest.expect.equality(packages[1], "package-old")
  MiniTest.expect.equality(packages[2], "package-new")
end

T["extract package with complex v prefix version"] = function()
  local lines = {
    "pydantic-core v2.41.5",
  }

  local packages = tree_ui.extract_packages(lines)

  MiniTest.expect.equality(packages[1], "pydantic-core")
end

-- Tests for estimate_width function
T["estimate_width without root returns max line width plus padding"] = function()
  local lines = {
    "short",
    "medium length line here",
    "this is a very long line that should determine the width",
  }

  local width = tree_ui.estimate_width(lines, nil, nil)

  local max_line_width = vim.fn.strdisplaywidth("this is a very long line that should determine the width")
  MiniTest.expect.equality(width, max_line_width + 2) -- 2 for padding
end

T["estimate_width with deps includes badge width"] = function()
  local lines = {
    "requests v2.31.0",
  }

  local direct_deps = { requests = true }
  local deps_list =
    { { name = "requests", spec = "requests>=2.31.0", line = 1, col_start = 1, col_end = 1, group = "project" } }

  local width = tree_ui.estimate_width(lines, direct_deps, deps_list)

  -- Width should be at least line width + badge width + space + padding
  local line_width = vim.fn.strdisplaywidth("requests v2.31.0")
  -- [direct] badge is 8 characters, plus 1 space before it
  local expected_min_width = line_width + 1 + 8 + 2
  MiniTest.expect.equality(width >= expected_min_width, true)
end

T["estimate_width with empty lines"] = function()
  local lines = {
    "",
    "single line",
    "",
  }

  local width = tree_ui.estimate_width(lines, nil, nil)

  local line_width = vim.fn.strdisplaywidth("single line")
  MiniTest.expect.equality(width, line_width + 2)
end

T["tree badges mark direct and transitive deps"] = function()
  local direct_deps = { requests = true }
  local deps_list =
    { { name = "requests", spec = "requests>=2.31.0", line = 1, col_start = 1, col_end = 1, group = "project" } }

  local badges = require("pydeps.core.tree_badges")
  local info_direct = badges.get_package_info("requests", direct_deps, deps_list)
  local info_transitive = badges.get_package_info("urllib3", direct_deps, deps_list)

  local direct_badge = badges.build_badges(info_direct)[1]
  local transitive_badge = badges.build_badges(info_transitive)[1]

  MiniTest.expect.equality(info_direct.direct, true)
  MiniTest.expect.equality(info_transitive.direct, false)
  MiniTest.expect.equality(direct_badge.text, "[direct]")
  MiniTest.expect.equality(transitive_badge.text, "[transitive]")
end

return T
