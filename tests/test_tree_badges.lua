local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local badges = require("pydeps.core.tree_badges")

local T = helpers.create_test_set()

---@param badge_list PyDepsTreeBadge[]
---@return string[][]
local function pairs_of(badge_list)
  local result = {}
  for _, badge in ipairs(badge_list) do
    table.insert(result, { badge.text, badge.highlight })
  end
  return result
end

T["build badges for direct and transitive dependencies"] = function()
  MiniTest.expect.equality(
    pairs_of(badges.build_badges({ direct = true, group = nil, extras = {} })),
    { { "[direct]", "PyDepsBadgeDirect" } }
  )
  MiniTest.expect.equality(
    pairs_of(badges.build_badges({ direct = false, group = nil, extras = {} })),
    { { "[transitive]", "PyDepsBadgeTransitive" } }
  )
end

T["build badges with group"] = function()
  local cases = {
    { group = "dev", text = "[dev]" },
    { group = "optional:test", text = "[test]" },
    { group = "group:lint", text = "[lint]" },
  }
  for _, case in ipairs(cases) do
    MiniTest.expect.equality(
      pairs_of(badges.build_badges({ direct = true, group = case.group, extras = {} })),
      { { "[direct]", "PyDepsBadgeDirect" }, { case.text, "PyDepsBadgeGroup" } }
    )
  end
  -- The main project group carries no badge of its own.
  MiniTest.expect.equality(
    pairs_of(badges.build_badges({ direct = true, group = "project", extras = {} })),
    { { "[direct]", "PyDepsBadgeDirect" } }
  )
end

T["build badges with all fields from declared requirements"] = function()
  local deps_list = {
    { name = "requests", spec = "requests[socks]>=2", line = 1, col_start = 1, col_end = 1, group = "optional:net" },
    {
      name = "requests",
      spec = "requests[security, socks]",
      line = 2,
      col_start = 1,
      col_end = 1,
      group = "group:dev",
    },
  }

  local info = badges.get_package_info("requests", { requests = true }, deps_list)

  MiniTest.expect.equality(info, { direct = true, group = "optional:net", extras = { "socks", "security" } })
  MiniTest.expect.equality(pairs_of(badges.build_badges(info)), {
    { "[direct]", "PyDepsBadgeDirect" },
    { "[net]", "PyDepsBadgeGroup" },
    { "[extra:socks]", "PyDepsBadgeExtra" },
    { "[extra:security]", "PyDepsBadgeExtra" },
  })
end

T["get_package_info marks direct packages correctly"] = function()
  local direct_deps = {
    ["requests"] = true,
    ["rich"] = false,
  }
  local deps_list = {
    { name = "requests", spec = "requests>=2.0", line = 1, col_start = 1, col_end = 1, group = "project" },
  }

  MiniTest.expect.equality(
    badges.get_package_info("requests", direct_deps, deps_list),
    { direct = true, group = "project", extras = {} }
  )
  MiniTest.expect.equality(
    badges.get_package_info("rich", direct_deps, deps_list),
    { direct = false, group = nil, extras = {} }
  )
  MiniTest.expect.equality(
    badges.get_package_info("urllib3", direct_deps, deps_list),
    { direct = false, group = nil, extras = {} }
  )
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
