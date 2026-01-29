local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

-- Check if Tree-sitter is available
local function is_treesitter_available()
  local ok, ts_toml = pcall(require, "pydeps.treesitter.toml")
  if not ok then
    return false
  end
  return ts_toml.is_available()
end

T["get_comment_col detects comment position"] = function()
  if not is_treesitter_available() then
    MiniTest.skip("Tree-sitter toml parser not available")
    return
  end

  local ts_toml = require("pydeps.treesitter.toml")

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    'dependencies = ["requests>=2.0"] # comment',
    'other = "value"',
  })
  vim.bo[bufnr].filetype = "toml"

  local col = ts_toml.get_comment_col(bufnr, 0)
  MiniTest.expect.equality(col, 34) -- Position of '#'

  local col2 = ts_toml.get_comment_col(bufnr, 1)
  MiniTest.expect.equality(col2, nil) -- No comment on line 2

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["parse_buffer extracts dependencies with Tree-sitter"] = function()
  if not is_treesitter_available() then
    MiniTest.skip("Tree-sitter toml parser not available")
    return
  end

  local ts_toml = require("pydeps.treesitter.toml")

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "[project]",
    "dependencies = [",
    '  "requests>=2.0", # core',
    '  "rich",',
    "]",
    "",
    "[project.optional-dependencies]",
    'dev = ["pytest>=7", "ruff"]',
  })
  vim.bo[bufnr].filetype = "toml"

  local deps = ts_toml.parse_buffer(bufnr)

  MiniTest.expect.equality(#deps, 4)

  -- Check first dependency
  MiniTest.expect.equality(deps[1].name, "requests")
  MiniTest.expect.equality(deps[1].spec, "requests>=2.0")
  MiniTest.expect.equality(deps[1].line, 3)
  MiniTest.expect.equality(deps[1].group, "project")
  MiniTest.expect.no_equality(deps[1].comment_col, nil) -- Should detect comment

  -- Check second dependency
  MiniTest.expect.equality(deps[2].name, "rich")
  MiniTest.expect.equality(deps[2].line, 4)
  MiniTest.expect.equality(deps[2].group, "project")

  -- Check optional dependencies
  MiniTest.expect.equality(deps[3].name, "pytest")
  MiniTest.expect.equality(deps[3].group, "optional:dev")

  MiniTest.expect.equality(deps[4].name, "ruff")
  MiniTest.expect.equality(deps[4].group, "optional:dev")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["parse_buffer handles dependency-groups"] = function()
  if not is_treesitter_available() then
    MiniTest.skip("Tree-sitter toml parser not available")
    return
  end

  local ts_toml = require("pydeps.treesitter.toml")

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "[dependency-groups]",
    'lint = ["ruff", "mypy"]',
    'test = ["pytest"]',
  })
  vim.bo[bufnr].filetype = "toml"

  local deps = ts_toml.parse_buffer(bufnr)

  MiniTest.expect.equality(#deps, 3)

  MiniTest.expect.equality(deps[1].name, "ruff")
  MiniTest.expect.equality(deps[1].group, "group:lint")

  MiniTest.expect.equality(deps[2].name, "mypy")
  MiniTest.expect.equality(deps[2].group, "group:lint")

  MiniTest.expect.equality(deps[3].name, "pytest")
  MiniTest.expect.equality(deps[3].group, "group:test")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["parse_buffer comment_col matches get_comment_col"] = function()
  if not is_treesitter_available() then
    MiniTest.skip("Tree-sitter toml parser not available")
    return
  end

  local ts_toml = require("pydeps.treesitter.toml")

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "[project]",
    "dependencies = [",
    '  "requests>=2.0", # http client',
    '  "rich",',
    '  "click>=8.0", # cli framework',
    "]",
  })
  vim.bo[bufnr].filetype = "toml"

  local deps = ts_toml.parse_buffer(bufnr)

  -- requests (line 3, 0-indexed 2) has a comment
  MiniTest.expect.equality(deps[1].name, "requests")
  local expected1 = ts_toml.get_comment_col(bufnr, 2)
  MiniTest.expect.equality(deps[1].comment_col, expected1)

  -- rich (line 4, 0-indexed 3) has no comment
  MiniTest.expect.equality(deps[2].name, "rich")
  local expected2 = ts_toml.get_comment_col(bufnr, 3)
  MiniTest.expect.equality(deps[2].comment_col, expected2)

  -- click (line 5, 0-indexed 4) has a comment
  MiniTest.expect.equality(deps[3].name, "click")
  local expected3 = ts_toml.get_comment_col(bufnr, 4)
  MiniTest.expect.equality(deps[3].comment_col, expected3)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["get_section_ranges identifies table sections"] = function()
  if not is_treesitter_available() then
    MiniTest.skip("Tree-sitter toml parser not available")
    return
  end

  local ts_toml = require("pydeps.treesitter.toml")

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "[project]",
    "name = 'test'",
    "dependencies = []",
    "",
    "[project.optional-dependencies]",
    "dev = []",
  })
  vim.bo[bufnr].filetype = "toml"

  local ranges = ts_toml.get_section_ranges(bufnr)

  MiniTest.expect.no_equality(ranges["project"], nil)
  MiniTest.expect.no_equality(ranges["project.optional-dependencies"], nil)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return T
