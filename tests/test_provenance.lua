local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

T["find_path returns the shortest complete path"] = function()
  local provenance = require("pydeps.core.provenance")
  local graph = {
    app = { "web", "cli" },
    web = { "http" },
    http = { "tls" },
    tls = { "certifi" },
    cli = { "certifi" },
    certifi = {},
  }

  MiniTest.expect.equality(provenance.find_path(graph, "app", "certifi"), { "app", "cli", "certifi" })
  MiniTest.expect.equality(provenance.find_path(graph, "web", "certifi"), { "web", "http", "tls", "certifi" })
end

T["find_path handles self, cycles and unreachable targets"] = function()
  local provenance = require("pydeps.core.provenance")
  local graph = {
    a = { "b" },
    b = { "a", "c" },
    c = {},
    island = {},
  }

  MiniTest.expect.equality(provenance.find_path(graph, "a", "a"), { "a" })
  MiniTest.expect.equality(provenance.find_path(graph, "a", "c"), { "a", "b", "c" })
  MiniTest.expect.equality(provenance.find_path(graph, "a", "island"), nil)
  MiniTest.expect.equality(provenance.find_path(graph, "c", "a"), nil)
  MiniTest.expect.equality(provenance.find_path(nil, "a", "b"), nil)
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
