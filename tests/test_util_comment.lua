local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

T["find_comment_pos ignores hashes inside strings"] = function()
  local util = require("pydeps.util")

  MiniTest.expect.equality(util.find_comment_pos('name = "requests"'), nil)
  MiniTest.expect.equality(util.find_comment_pos('name = "req#uests"'), nil)
  MiniTest.expect.equality(util.find_comment_pos("name = 'req#uests'"), nil)
  MiniTest.expect.equality(util.find_comment_pos('name = "req\\"#uests"'), nil)
end

T["find_comment_pos returns comment column"] = function()
  local util = require("pydeps.util")

  MiniTest.expect.equality(util.find_comment_pos('name = "requests" # core'), 19)
  MiniTest.expect.equality(util.find_comment_pos("name = 'requests'  # core"), 20)
  MiniTest.expect.equality(util.find_comment_pos("# only comment"), 1)
end

T["find_comment_pos handles mixed quotes"] = function()
  local util = require("pydeps.util")

  MiniTest.expect.equality(util.find_comment_pos("name = \"req'#'uests\" # ok"), 22)
  MiniTest.expect.equality(util.find_comment_pos("name = 'req\"#\"uests' # ok"), 22)
end

return T
