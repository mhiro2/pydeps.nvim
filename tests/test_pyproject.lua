local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

T["parse dependencies and optional groups"] = function()
  local pyproject = require("pydeps.sources.pyproject")
  local lines = {
    "[project]",
    "dependencies = [",
    '  "requests>=2.0",',
    '  "rich",',
    "]",
    "",
    "[project.optional-dependencies]",
    'dev = ["pytest>=7", "ruff"]',
    "docs = [",
    '  "mkdocs",',
    "]",
  }

  helpers.setup_buffer(lines)
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  MiniTest.expect.equality(#deps, 5)

  MiniTest.expect.equality(deps[1].name, "requests")
  MiniTest.expect.equality(deps[1].spec, "requests>=2.0")
  MiniTest.expect.equality(deps[1].line, 3)
  MiniTest.expect.equality(deps[1].group, "project")

  MiniTest.expect.equality(deps[2].name, "rich")
  MiniTest.expect.equality(deps[2].line, 4)

  MiniTest.expect.equality(deps[3].name, "pytest")
  MiniTest.expect.equality(deps[3].group, "optional:dev")
  MiniTest.expect.equality(deps[3].line, 8)

  MiniTest.expect.equality(deps[4].name, "ruff")
  MiniTest.expect.equality(deps[4].group, "optional:dev")

  MiniTest.expect.equality(deps[5].name, "mkdocs")
  MiniTest.expect.equality(deps[5].group, "optional:docs")
  MiniTest.expect.equality(deps[5].line, 10)
end

T["parse dependencies with comments and empty lines"] = function()
  local pyproject = require("pydeps.sources.pyproject")
  local lines = {
    "[project]",
    "dependencies = [",
    '  "requests>=2.0", # core',
    '  # "ignored>=1.0"',
    "  \"rich[extra] >=1.0 ; python_version >= '3.10'\",",
    "  ",
    "]",
    "",
    "[project.optional-dependencies]",
    "dev = [",
    '  "pytest>=7",  # comment with \\"quotes\\"',
    "",
    '  "ruff"',
    "]",
  }

  helpers.setup_buffer(lines)
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  MiniTest.expect.equality(#deps, 4)

  MiniTest.expect.equality(deps[1].name, "requests")
  MiniTest.expect.equality(deps[1].line, 3)
  MiniTest.expect.equality(deps[2].name, "rich")
  MiniTest.expect.equality(deps[2].line, 5)
  MiniTest.expect.equality(deps[3].name, "pytest")
  MiniTest.expect.equality(deps[3].line, 11)
  MiniTest.expect.equality(deps[4].name, "ruff")
  MiniTest.expect.equality(deps[4].line, 13)
end

return T
