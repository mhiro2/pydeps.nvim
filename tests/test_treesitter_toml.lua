local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

-- `make test` builds the TOML parser, so a missing parser is a broken setup
-- rather than a reason to skip.
---@return table
local function load_ts_toml()
  local ts_toml = require("pydeps.treesitter.toml")
  if not ts_toml.is_available() then
    error("Tree-sitter toml parser is not available; run `make deps`", 2)
  end
  return ts_toml
end

---@param lines string[]
---@return integer
local function toml_buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = "toml"
  return bufnr
end

T["parse_buffer records string columns and trailing comment columns"] = function()
  local ts_toml = load_ts_toml()
  local bufnr = toml_buffer({
    "[project]",
    "dependencies = [",
    '  "requests>=2.0", # http client',
    '  "rich",',
    '  "pkg @ https://example.com/pkg.whl#sha256=abc",',
    '  "click>=8.0", # cli # framework',
    "]",
    "",
    "[project.optional-dependencies]",
    'dev = ["pytest>=7", "ruff"] # tools',
  })

  local deps = ts_toml.parse_buffer(bufnr)
  local actual = {}
  for _, dep in ipairs(deps) do
    actual[#actual + 1] = { dep.name, dep.line, dep.col_start, dep.col_end, dep.comment_col or false }
  end

  MiniTest.expect.equality(actual, {
    { "requests", 3, 3, 17, 20 },
    { "rich", 4, 3, 8, false },
    -- `#` inside the string is not a comment
    { "pkg", 5, 3, 48, false },
    -- the first `#` starts the comment
    { "click", 6, 3, 14, 17 },
    -- dependencies sharing a line share its comment
    { "pytest", 10, 8, 18, 29 },
    { "ruff", 10, 21, 26, 29 },
  })
end

T["parse_buffer decodes TOML escapes in the requirement"] = function()
  local ts_toml = load_ts_toml()
  local markers = require("pydeps.core.markers")
  local bufnr = toml_buffer({
    "[project]",
    "dependencies = [",
    '  "kernel; platform_version == \\"#3\\"",',
    "  'win; os_name == \"nt\"',",
    '  "uni\\u0063ode",',
    "]",
  })

  local deps = ts_toml.parse_buffer(bufnr)
  local actual = {}
  for _, dep in ipairs(deps) do
    actual[#actual + 1] = { dep.name, dep.spec, dep.literal }
  end
  MiniTest.expect.equality(actual, {
    { "kernel", 'kernel; platform_version == "#3"', '"kernel; platform_version == \\"#3\\""' },
    -- literal strings keep backslash-free text as written
    { "win", 'win; os_name == "nt"', "'win; os_name == \"nt\"'" },
    { "unicode", "unicode", '"uni\\u0063ode"' },
  })
  -- With the backslashes left in, the marker failed to parse.
  local marker = require("pydeps.ui.shared").extract_marker(deps[1].spec)
  MiniTest.expect.equality(markers.evaluate(marker, { platform_version = "#3" }), true)
end

T["parse_buffer handles dependency-groups"] = function()
  local ts_toml = load_ts_toml()
  local bufnr = toml_buffer({
    "[dependency-groups]",
    'lint = ["ruff", "mypy"]',
    'test = ["pytest"]',
  })

  local deps = ts_toml.parse_buffer(bufnr)

  MiniTest.expect.equality(#deps, 3)

  MiniTest.expect.equality(deps[1].name, "ruff")
  MiniTest.expect.equality(deps[1].group, "group:lint")

  MiniTest.expect.equality(deps[2].name, "mypy")
  MiniTest.expect.equality(deps[2].group, "group:lint")

  MiniTest.expect.equality(deps[3].name, "pytest")
  MiniTest.expect.equality(deps[3].group, "group:test")
end

T["get_dependency_array_ranges spans each dependency array"] = function()
  local ts_toml = load_ts_toml()
  local bufnr = toml_buffer({
    "[project]",
    'name = "demo"',
    "dependencies = [",
    "  # pinned for CI",
    '  "requests",',
    "]",
    "",
    "[project.optional-dependencies]",
    'dev = ["pytest"]',
    "docs = [",
    '  "mkdocs",',
    "]",
    "",
    "[dependency-groups]",
    'lint = ["ruff"]',
    "",
    "[tool.other]",
    'dependencies = ["ignored"]',
  })

  MiniTest.expect.equality(ts_toml.get_dependency_array_ranges(bufnr), {
    project = { start_line = 3, end_line = 6 },
    ["optional:dev"] = { start_line = 9, end_line = 9 },
    ["optional:docs"] = { start_line = 10, end_line = 12 },
    ["group:lint"] = { start_line = 15, end_line = 15 },
  })
end

T["parse_sections lists extras, groups and included groups"] = function()
  local ts_toml = load_ts_toml()
  local bufnr = toml_buffer({
    "[project.optional-dependencies]",
    'postgres = ["psycopg"]',
    "empty = []",
    "",
    "[dependency-groups]",
    'test = ["pytest"]',
    'ci = [{ include-group = "test" }, "coverage", { include-group = "lint" }]',
    "lint = []",
  })

  MiniTest.expect.equality(ts_toml.parse_sections(bufnr), {
    extras = { "postgres", "empty" },
    groups = { "test", "ci", "lint" },
    includes = { test = {}, ci = { "test", "lint" }, lint = {} },
  })
end

return T
