local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

-- Trimmed `uv tree --help` output: supports everything except --universal
-- and --show-sizes.
local HELP_STDOUT = table.concat({
  "Display the project's dependency tree",
  "",
  "Usage: uv tree [OPTIONS]",
  "",
  "Options:",
  "  -d, --depth <DEPTH>        Maximum display depth of the dependency tree",
  "      --package <PACKAGE>    Display only the specified packages",
  "      --invert               Show the reverse dependencies for the given package",
  "      --frozen               Run without updating the uv.lock file",
  "      --group <GROUP>        Include dependencies from the specified dependency group",
  "      --no-group <NO_GROUP>  Disable the specified dependency group",
  "      --all-groups           Include dependencies from all dependency groups",
}, "\n")

---@param opts? { uv_available?: boolean }
---@return { calls: string[][], finish: fun(stdout: string), notifications: string[] }
local function stub_uv(opts)
  local uv_available = not opts or opts.uv_available ~= false
  local spy = { calls = {}, notifications = {} }
  local pending = {}
  local original_executable = vim.fn.executable
  helpers.stub(vim.fn, "executable", function(cmd)
    if cmd == "uv" then
      return uv_available and 1 or 0
    end
    return original_executable(cmd)
  end)
  helpers.stub(vim, "system", function(cmd, _, on_exit)
    table.insert(spy.calls, cmd)
    table.insert(pending, on_exit)
  end)
  helpers.stub(vim, "notify", function(msg)
    table.insert(spy.notifications, msg)
  end)
  spy.finish = function(stdout)
    for _, on_exit in ipairs(pending) do
      on_exit({ code = 0, stdout = stdout, stderr = "" })
    end
    pending = {}
  end
  return spy
end

---@return table
local function fresh_uv()
  package.loaded["pydeps.providers.uv"] = nil
  local uv = require("pydeps.providers.uv")
  uv._clear_tree_features_cache()
  return uv
end

T["feature detection parses uv tree --help and runs it once"] = function()
  local spy = stub_uv()
  local uv = fresh_uv()

  local received = {}
  uv.detect_tree_features(function(features)
    table.insert(received, features)
  end)
  -- A second caller while detection is in flight joins the same run.
  uv.detect_tree_features(function(features)
    table.insert(received, features)
  end)
  MiniTest.expect.equality(spy.calls, { { "uv", "tree", "--help" } })
  MiniTest.expect.equality(uv.tree_features_ready(), false)
  MiniTest.expect.equality(uv.supports_tree_flag("depth"), false)

  spy.finish(HELP_STDOUT)
  helpers.wait_for(function()
    return #received == 2
  end, "both feature callbacks")

  local expected = {
    invert = true,
    depth = true,
    universal = false,
    show_sizes = false,
    all_groups = true,
    group = true,
    no_group = true,
    package = true,
    frozen = true,
  }
  MiniTest.expect.equality(received[1], expected)
  MiniTest.expect.equality(received[2], expected)
  for flag, supported in pairs(expected) do
    MiniTest.expect.equality(uv.supports_tree_flag(flag), supported)
  end
  MiniTest.expect.equality(uv.supports_tree_flag("definitely-not-a-real-flag"), false)

  -- Cached: neither a lookup nor another detection spawns uv again.
  local cached
  uv.detect_tree_features(function(features)
    cached = features
  end)
  MiniTest.expect.equality(cached, expected)
  MiniTest.expect.equality(#spy.calls, 1)
end

T["feature detection skips uv tree --help when uv not found"] = function()
  local spy = stub_uv({ uv_available = false })
  local uv = fresh_uv()

  local received
  uv.detect_tree_features(function(features)
    received = features
  end)
  helpers.wait_for(function()
    return received ~= nil
  end, "feature callback")

  MiniTest.expect.equality(received, {})
  MiniTest.expect.equality(uv.supports_tree_flag("depth"), false)
  MiniTest.expect.equality(spy.calls, {})
end

T["feature detection notifies only once when uv not found"] = function()
  local spy = stub_uv({ uv_available = false })
  local uv = fresh_uv()

  uv.supports_tree_flag("depth")
  uv.supports_tree_flag("invert")
  helpers.wait_for(function()
    return uv.tree_features_ready()
  end, "feature detection")
  uv.supports_tree_flag("depth")

  MiniTest.expect.equality(spy.notifications, { "pydeps: uv not found in PATH" })
end

return T
