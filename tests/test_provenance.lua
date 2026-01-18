local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

T["find_paths returns shortest paths per root"] = function()
  local provenance = require("pydeps.core.provenance")
  local graph = {
    requests = { "urllib3", "idna" },
    urllib3 = { "certifi" },
    idna = {},
    certifi = {},
    rich = { "markdown-it-py" },
    ["markdown-it-py"] = {},
  }

  local paths = provenance.find_paths(graph, { "requests", "rich" }, "certifi", 3)
  MiniTest.expect.equality(#paths, 1)
  MiniTest.expect.equality(paths[1][1], "requests")
  MiniTest.expect.equality(paths[1][#paths[1]], "certifi")
end

T["roots_reaching_target marks only reachable roots"] = function()
  local provenance = require("pydeps.core.provenance")
  local graph = {
    requests = { "urllib3", "idna" },
    urllib3 = { "certifi" },
    idna = {},
    certifi = {},
    rich = { "markdown-it-py" },
    ["markdown-it-py"] = {},
  }

  local roots = { "requests", "rich", "certifi" }
  local reachable = provenance.roots_reaching_target(graph, roots, "certifi")

  MiniTest.expect.equality(reachable.requests, true)
  MiniTest.expect.equality(reachable.rich, nil)
  MiniTest.expect.equality(reachable.certifi, true)
end

return T
