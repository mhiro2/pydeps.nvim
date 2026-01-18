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

  -- Create a temp directory (we won't actually read a file for this unit test)
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")

  -- Direct package
  local info1 = badges.get_package_info(temp_dir, "requests", direct_deps)
  MiniTest.expect.equality(info1.direct, true)

  -- Transitive package
  local info2 = badges.get_package_info(temp_dir, "rich", direct_deps)
  MiniTest.expect.equality(info2.direct, false)

  -- Cleanup
  vim.fn.delete(temp_dir, "rf")
end

T["get_package_info handles unloaded pyproject buffer"] = function()
  local direct_deps = {
    ["testpkg"] = true,
  }

  -- Create a temp directory with a real pyproject.toml
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local pyproject_path = temp_dir .. "/pyproject.toml"
  local pyproject_content = table.concat({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  }, "\n")
  vim.fn.writefile(vim.split(pyproject_content, "\n"), pyproject_path)

  -- Create buffer without loading (bufadd only)
  local pyproject_buf = vim.fn.bufadd(pyproject_path)
  _ = pyproject_buf
  -- Don't call bufload to simulate unloaded state

  -- get_package_info should still work (it calls bufload internally)
  local info = badges.get_package_info(temp_dir, "testpkg", direct_deps)

  -- Should be marked as direct since it's in direct_deps
  MiniTest.expect.equality(info.direct, true)

  -- Cleanup
  vim.fn.delete(pyproject_path, "rf")
end

return T
