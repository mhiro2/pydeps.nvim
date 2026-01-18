local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

local function wait_features(uv)
  local done = false
  uv.detect_tree_features(function()
    done = true
  end)
  vim.wait(200, function()
    return done or uv.tree_features_ready()
  end, 10)
end

T["feature detection caches results"] = function()
  local uv = require("pydeps.providers.uv")

  -- Clear cache
  uv._clear_tree_features_cache()

  wait_features(uv)

  -- First call after cache
  local supports1 = uv.supports_tree_flag("depth")

  -- Second call should use cache
  local supports2 = uv.supports_tree_flag("depth")

  MiniTest.expect.equality(supports1, supports2)
end

T["feature detection handles unknown flags"] = function()
  local uv = require("pydeps.providers.uv")
  uv._clear_tree_features_cache()

  wait_features(uv)

  local supports = uv.supports_tree_flag("definitely-not-a-real-flag")
  MiniTest.expect.equality(supports, false)
end

T["feature detection returns boolean for known flags"] = function()
  local uv = require("pydeps.providers.uv")
  uv._clear_tree_features_cache()

  wait_features(uv)

  local invert = uv.supports_tree_flag("invert")
  MiniTest.expect.equality(type(invert), "boolean")

  local depth = uv.supports_tree_flag("depth")
  MiniTest.expect.equality(type(depth), "boolean")

  local universal = uv.supports_tree_flag("universal")
  MiniTest.expect.equality(type(universal), "boolean")

  local show_sizes = uv.supports_tree_flag("show_sizes")
  MiniTest.expect.equality(type(show_sizes), "boolean")

  local all_groups = uv.supports_tree_flag("all_groups")
  MiniTest.expect.equality(type(all_groups), "boolean")

  local group = uv.supports_tree_flag("group")
  MiniTest.expect.equality(type(group), "boolean")

  local no_group = uv.supports_tree_flag("no_group")
  MiniTest.expect.equality(type(no_group), "boolean")

  local package = uv.supports_tree_flag("package")
  MiniTest.expect.equality(type(package), "boolean")
end

T["feature detection skips uv tree --help when uv not found"] = function()
  local uv = require("pydeps.providers.uv")
  uv._clear_tree_features_cache()

  -- Mock vim.fn.executable to simulate uv not being found
  local original_executable = vim.fn.executable
  vim.fn.executable = function(cmd)
    if cmd == "uv" then
      return 0
    end
    return original_executable(cmd)
  end

  -- Clear the uv_notified flag to simulate first call
  uv._clear_tree_features_cache()

  wait_features(uv)

  -- This should not execute uv tree --help
  local result = uv.supports_tree_flag("depth")
  MiniTest.expect.equality(result, false)

  -- Restore original function
  vim.fn.executable = original_executable
end

T["feature detection notifies only once when uv not found"] = function()
  -- Mock vim.fn.executable BEFORE calling uv module
  local original_executable = vim.fn.executable
  local notify_count = 0
  local original_notify = vim.notify

  vim.fn.executable = function(cmd)
    if cmd == "uv" then
      return 0
    end
    return original_executable(cmd)
  end

  vim.notify = function(msg, _)
    if msg:match("uv not found") then
      notify_count = notify_count + 1
    end
  end

  -- Now require and test uv module
  local uv = require("pydeps.providers.uv")
  uv._clear_tree_features_cache()

  wait_features(uv)

  -- First call should notify
  uv.supports_tree_flag("depth")
  MiniTest.expect.equality(notify_count, 1)

  -- Second call should NOT notify (already cached)
  uv.supports_tree_flag("invert")
  MiniTest.expect.equality(notify_count, 1)

  -- Restore original functions
  vim.fn.executable = original_executable
  vim.notify = original_notify
end

return T
