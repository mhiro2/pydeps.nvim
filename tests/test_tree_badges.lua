local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local badges = require("pydeps.core.tree_badges")

local T = helpers.create_test_set()

T["build badges for direct dependency"] = function()
  local info = {
    direct = true,
    group = nil,
    extras = {},
  }

  local badge_list = badges.build_badges(info)

  MiniTest.expect.equality(badge_list[1].text, "[direct]")
end

T["build badges for transitive dependency"] = function()
  local info = {
    direct = false,
    group = nil,
    extras = {},
  }

  local badge_list = badges.build_badges(info)

  MiniTest.expect.equality(badge_list[1].text, "[transitive]")
end

T["build badges with group"] = function()
  local info = {
    direct = true,
    group = "dev",
    extras = {},
  }

  local badge_list = badges.build_badges(info)

  local has_group = false
  for _, badge in ipairs(badge_list) do
    if badge.text == "[dev]" then
      has_group = true
      break
    end
  end
  MiniTest.expect.equality(has_group, true)
end

T["build badges with optional group"] = function()
  local info = {
    direct = true,
    group = "optional:test",
    extras = {},
  }

  local badge_list = badges.build_badges(info)

  local has_group = false
  for _, badge in ipairs(badge_list) do
    if badge.text == "[test]" then
      has_group = true
      break
    end
  end
  MiniTest.expect.equality(has_group, true)
end

T["build badges with extras"] = function()
  local info = {
    direct = true,
    group = nil,
    extras = { "security", "testing" },
  }

  local badge_list = badges.build_badges(info)

  local has_security = false
  local has_testing = false
  for _, badge in ipairs(badge_list) do
    if badge.text == "[extra:security]" then
      has_security = true
    end
    if badge.text == "[extra:testing]" then
      has_testing = true
    end
  end
  MiniTest.expect.equality(has_security, true)
  MiniTest.expect.equality(has_testing, true)
end

T["build badges with all fields"] = function()
  local info = {
    direct = true,
    group = "dev",
    extras = { "test" },
  }

  local badge_list = badges.build_badges(info)

  -- Should have: direct, group, extra
  MiniTest.expect.equality(#badge_list >= 3, true)
end

T["build badges highlights"] = function()
  local info = {
    direct = true,
    group = nil,
    extras = {},
  }

  local badge_list = badges.build_badges(info)

  MiniTest.expect.equality(badge_list[1].highlight, "PyDepsBadgeDirect")
end

T["build badges transitive highlight"] = function()
  local info = {
    direct = false,
    group = nil,
    extras = {},
  }

  local badge_list = badges.build_badges(info)

  MiniTest.expect.equality(badge_list[1].highlight, "PyDepsBadgeTransitive")
end

T["get_package_info marks direct packages correctly"] = function()
  local direct_deps = {
    ["requests"] = true,
    ["rich"] = false,
  }
  local deps_list = {
    { name = "requests", spec = "requests>=2.0", line = 1, col_start = 1, col_end = 1, group = "project" },
  }

  -- Direct package
  local info1 = badges.get_package_info("requests", direct_deps, deps_list)
  MiniTest.expect.equality(info1.direct, true)

  -- Transitive package
  local info2 = badges.get_package_info("rich", direct_deps, deps_list)
  MiniTest.expect.equality(info2.direct, false)
end

T["get_package_info retrieves group from deps_list"] = function()
  local direct_deps = {
    ["testpkg"] = true,
  }
  local deps_list = {
    { name = "testpkg", spec = "testpkg>=1.0", line = 1, col_start = 1, col_end = 1, group = "optional:dev" },
  }

  local info = badges.get_package_info("testpkg", direct_deps, deps_list)
  MiniTest.expect.equality(info.direct, true)
  MiniTest.expect.equality(info.group, "optional:dev")
end

T["get_package_info does not create buffers"] = function()
  local direct_deps = { ["pkg"] = true }
  local deps_list = {
    { name = "pkg", spec = "pkg>=1.0", line = 1, col_start = 1, col_end = 1, group = "project" },
  }

  local buf_count_before = #vim.api.nvim_list_bufs()
  badges.get_package_info("pkg", direct_deps, deps_list)
  local buf_count_after = #vim.api.nvim_list_bufs()

  MiniTest.expect.equality(buf_count_after, buf_count_before)
end

return T
