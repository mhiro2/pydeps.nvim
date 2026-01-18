local MiniTest = require("mini.test")
local tree_args = require("pydeps.core.tree_args")

local T = MiniTest.new_set()

T["parse empty args"] = function()
  local result = tree_args.parse("", false)
  MiniTest.expect.equality(result.target, nil)
  MiniTest.expect.equality(result.depth, nil)
  MiniTest.expect.equality(result.reverse, false)
end

T["parse --package flag"] = function()
  local result = tree_args.parse("--package requests", false)
  MiniTest.expect.equality(result.target, "requests")
end

T["parse --target flag"] = function()
  local result = tree_args.parse("--target rich", false)
  MiniTest.expect.equality(result.target, "rich")
end

T["parse positional target"] = function()
  local result = tree_args.parse("requests", false)
  MiniTest.expect.equality(result.target, "requests")
end

T["parse --depth flag"] = function()
  local result = tree_args.parse("--depth 5", false)
  MiniTest.expect.equality(result.depth, 5)
end

T["parse -d short flag"] = function()
  local result = tree_args.parse("-d 3", false)
  MiniTest.expect.equality(result.depth, 3)
end

T["parse --reverse flag"] = function()
  local result = tree_args.parse("--reverse", false)
  MiniTest.expect.equality(result.reverse, true)
end

T["parse --invert flag"] = function()
  local result = tree_args.parse("--invert", false)
  MiniTest.expect.equality(result.reverse, true)
end

T["parse bang as reverse"] = function()
  local result = tree_args.parse("", true)
  MiniTest.expect.equality(result.reverse, true)
end

T["parse bang with other flags"] = function()
  local result = tree_args.parse("--depth 2", true)
  MiniTest.expect.equality(result.depth, 2)
  MiniTest.expect.equality(result.reverse, true)
end

T["parse --universal flag"] = function()
  local result = tree_args.parse("--universal", false)
  MiniTest.expect.equality(result.universal, true)
end

T["parse --show-sizes flag"] = function()
  local result = tree_args.parse("--show-sizes", false)
  MiniTest.expect.equality(result.show_sizes, true)
end

T["parse --all-groups flag"] = function()
  local result = tree_args.parse("--all-groups", false)
  MiniTest.expect.equality(result.all_groups, true)
end

T["parse --group flag"] = function()
  local result = tree_args.parse("--group dev", false)
  MiniTest.expect.equality(result.groups[1], "dev")
end

T["parse multiple --group flags"] = function()
  local result = tree_args.parse("--group dev --group test", false)
  MiniTest.expect.equality(result.groups[1], "dev")
  MiniTest.expect.equality(result.groups[2], "test")
end

T["parse --no-group flag"] = function()
  local result = tree_args.parse("--no-group test", false)
  MiniTest.expect.equality(result.no_groups[1], "test")
end

T["parse multiple --no-group flags"] = function()
  local result = tree_args.parse("--no-group dev --no-group test", false)
  MiniTest.expect.equality(result.no_groups[1], "dev")
  MiniTest.expect.equality(result.no_groups[2], "test")
end

T["parse --group and --no-group together"] = function()
  local result = tree_args.parse("--group dev --no-group test", false)
  MiniTest.expect.equality(result.groups[1], "dev")
  MiniTest.expect.equality(result.no_groups[1], "test")
end

T["parse multiple flags"] = function()
  local result = tree_args.parse("--depth 3 --universal --show-sizes", false)
  MiniTest.expect.equality(result.depth, 3)
  MiniTest.expect.equality(result.universal, true)
  MiniTest.expect.equality(result.show_sizes, true)
end

T["parse package with depth"] = function()
  local result = tree_args.parse("--package requests --depth 2", false)
  MiniTest.expect.equality(result.target, "requests")
  MiniTest.expect.equality(result.depth, 2)
end

T["parse package with reverse"] = function()
  local result = tree_args.parse("--package rich --reverse", false)
  MiniTest.expect.equality(result.target, "rich")
  MiniTest.expect.equality(result.reverse, true)
end

T["parse with quoted package name"] = function()
  local result = tree_args.parse('--package "some-package"', false)
  MiniTest.expect.equality(result.target, "some-package")
end

T["parse with single quoted package name"] = function()
  local result = tree_args.parse("--package 'some-package'", false)
  MiniTest.expect.equality(result.target, "some-package")
end

return T
