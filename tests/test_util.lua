local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

T["parse_requirement_name extracts name"] = function()
  local util = require("pydeps.util")
  MiniTest.expect.equality(util.parse_requirement_name("requests>=2.0"), "requests")
  MiniTest.expect.equality(util.parse_requirement_name("Foo-Bar[extra]>=1.0; python_version>='3.11'"), "foo-bar")
  MiniTest.expect.equality(util.parse_requirement_name(""), nil)
end

T["parse_requirement_extras extracts extras"] = function()
  local util = require("pydeps.util")
  MiniTest.expect.equality(util.parse_requirement_extras("requests[security, socks]>=2.0"), { "security", "socks" })
  MiniTest.expect.equality(util.parse_requirement_extras("Foo-Bar[extra]>=1.0; python_version>='3.11'"), { "extra" })
  MiniTest.expect.equality(util.parse_requirement_extras("requests>=2.0"), {})
  MiniTest.expect.equality(util.parse_requirement_extras(""), {})
end

T["now returns current time in seconds"] = function()
  local util = require("pydeps.util")
  local t1 = util.now()
  MiniTest.expect.equality(type(t1), "number")
  MiniTest.expect.equality(t1 > 0, true)
  -- now() should return time in seconds (uv.now() / 1000)
  -- uv.now() returns milliseconds since Neovim started
  local t2 = util.now()
  MiniTest.expect.equality(t2 >= t1, true)
end

T["safe_close_timer handles nil"] = function()
  local util = require("pydeps.util")
  -- Should not error on nil
  util.safe_close_timer(nil)
end

T["safe_close_timer closes active timer"] = function()
  local util = require("pydeps.util")
  local uv = vim.uv
  local timer = uv.new_timer()
  timer:start(10000, 0, function() end)
  MiniTest.expect.equality(timer:is_closing(), false)
  util.safe_close_timer(timer)
  MiniTest.expect.equality(timer:is_closing(), true)
end

T["safe_close_timer handles already closing timer"] = function()
  local util = require("pydeps.util")
  local uv = vim.uv
  local timer = uv.new_timer()
  timer:start(10000, 0, function() end)
  timer:stop()
  timer:close()
  -- Should not error when timer is already closing
  util.safe_close_timer(timer)
end

T["create_lru_cache basic operations"] = function()
  local util = require("pydeps.util")
  local cache = util.create_lru_cache(3)

  -- Set and get
  cache:set("a", 1)
  MiniTest.expect.equality(cache:get("a"), 1)

  -- Get non-existent key
  MiniTest.expect.equality(cache:get("nonexistent"), nil)

  -- Set multiple values
  cache:set("b", 2)
  cache:set("c", 3)
  MiniTest.expect.equality(cache:get("a"), 1)
  MiniTest.expect.equality(cache:get("b"), 2)
  MiniTest.expect.equality(cache:get("c"), 3)
end

T["create_lru_cache evicts least recently used"] = function()
  local util = require("pydeps.util")
  local cache = util.create_lru_cache(3)

  cache:set("a", 1)
  cache:set("b", 2)
  cache:set("c", 3)

  -- Access "a" to make it most recently used
  MiniTest.expect.equality(cache:get("a"), 1)

  -- Add "d" - should evict "b" (least recently used)
  cache:set("d", 4)

  MiniTest.expect.equality(cache:get("a"), 1)
  MiniTest.expect.equality(cache:get("b"), nil) -- evicted
  MiniTest.expect.equality(cache:get("c"), 3)
  MiniTest.expect.equality(cache:get("d"), 4)
end

T["create_lru_cache update existing key"] = function()
  local util = require("pydeps.util")
  local cache = util.create_lru_cache(3)

  cache:set("a", 1)
  cache:set("b", 2)
  cache:set("c", 3)

  -- Update "a" - should move it to most recently used
  cache:set("a", 10)

  -- Add "d" - should evict "b" (now least recently used)
  cache:set("d", 4)

  MiniTest.expect.equality(cache:get("a"), 10)
  MiniTest.expect.equality(cache:get("b"), nil) -- evicted
  MiniTest.expect.equality(cache:get("c"), 3)
  MiniTest.expect.equality(cache:get("d"), 4)
end

T["create_lru_cache respects max_size"] = function()
  local util = require("pydeps.util")
  local cache = util.create_lru_cache(2)

  cache:set("a", 1)
  cache:set("b", 2)
  cache:set("c", 3)
  cache:set("d", 4)

  -- Only last 2 entries should remain
  MiniTest.expect.equality(cache:get("a"), nil)
  MiniTest.expect.equality(cache:get("b"), nil)
  MiniTest.expect.equality(cache:get("c"), 3)
  MiniTest.expect.equality(cache:get("d"), 4)
end

T["create_lru_cache ignores nil values"] = function()
  local util = require("pydeps.util")
  local cache = util.create_lru_cache(2)

  cache:set("a", 1)
  cache:set("b", 2)

  -- Setting nil should remove the key and not consume capacity
  cache:set("a", nil)
  cache:set("c", 3)

  MiniTest.expect.equality(cache:get("a"), nil)
  MiniTest.expect.equality(cache:get("b"), 2)
  MiniTest.expect.equality(cache:get("c"), 3)
end

return T
