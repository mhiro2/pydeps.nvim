local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

local function create_project(lines, lock_lines)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/pyproject.toml"
  vim.fn.writefile(lines, path)
  if lock_lines then
    vim.fn.writefile(lock_lines, dir .. "/uv.lock")
  else
    helpers.create_uv_lock(dir)
  end
  vim.cmd("edit " .. path)
  helpers.setup_buffer(lines)
  return dir
end

local function cleanup(dir)
  if dir then
    vim.fn.delete(dir, "rf")
  end
end

---@return nil
local function reset_completion_modules()
  package.loaded["pydeps.completion.core"] = nil
  package.loaded["pydeps.completion.items"] = nil
  package.loaded["pydeps.completion.scan"] = nil
end

local function run_complete(bufnr, line_num, col)
  reset_completion_modules()
  local completion = require("pydeps.completion.core")
  local result = nil
  completion.complete(bufnr, { line_num, col }, function(res)
    result = res
  end)
  return result
end

---@param items table[]?
---@param label string
---@return table|nil
local function find_item(items, label)
  for _, item in ipairs(items or {}) do
    if item.label == label then
      return item
    end
  end
  return nil
end

T["completion contexts"] = function()
  package.loaded["pydeps.providers.pypi"] = {
    search = function(_, cb)
      cb({ "pytest", "requests-toolbelt" })
    end,
    get = function(_, cb)
      cb({
        info = {
          provides_extra = { "security", "socks" },
        },
        releases = {
          ["2.0.0"] = { { upload_time_iso_8601 = "2024-01-01T00:00:00" } },
          ["2.1.0"] = { { upload_time_iso_8601 = "2024-02-01T00:00:00" } },
        },
      })
    end,
    sorted_versions = function()
      return { "2.1.0", "2.0.0" }
    end,
  }
  reset_completion_modules()

  local dir = create_project({
    "[project]",
    "dependencies = [",
    '  "req",',
    '  "requests>=2",',
    '  "requests[sec]",',
    "  \"requests; extra == 'd'\",",
    "  \"requests; group == 't'\",",
    "]",
    "",
    "[project.optional-dependencies]",
    'dev = ["pytest"]',
    "",
    "[dependency-groups]",
    'test = ["coverage"]',
  }, {
    "[[package]]",
    'name = "localdep"',
    'version = "0.1.0"',
  })

  local config = require("pydeps.config")
  config.options.completion = { pypi_search = true, pypi_search_min = 2, max_results = 30 }

  local bufnr = vim.api.nvim_get_current_buf()
  local cache = require("pydeps.core.cache")
  cache.get_lockfile(dir)
  vim.wait(200, function()
    local data = cache.get_lockfile(dir)
    return data.resolved and data.resolved.localdep ~= nil
  end, 10)

  local line = vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1]
  local start = line:find("req")
  local result = run_complete(bufnr, 3, start + 1)
  local labels = {}
  for _, item in ipairs(result.items or {}) do
    labels[item.label] = true
  end
  MiniTest.expect.equality(labels["localdep"] ~= nil, true)
  MiniTest.expect.equality(labels["pytest"] ~= nil, true)

  local local_item = find_item(result.items, "localdep")
  MiniTest.expect.no_equality(local_item, nil)
  MiniTest.expect.equality(local_item.detail, "package")
  MiniTest.expect.equality(local_item.labelDetails.description, "local")

  local pypi_item = find_item(result.items, "requests-toolbelt")
  MiniTest.expect.no_equality(pypi_item, nil)
  MiniTest.expect.equality(pypi_item.detail, "package")
  MiniTest.expect.equality(pypi_item.labelDetails.description, "PyPI")

  local line_version = vim.api.nvim_buf_get_lines(bufnr, 3, 4, false)[1]
  local vpos = line_version:find("2")
  local result_version = run_complete(bufnr, 4, vpos - 1)
  local version_labels = {}
  for _, item in ipairs(result_version.items or {}) do
    version_labels[item.label] = true
  end
  MiniTest.expect.equality(version_labels["2.1.0"] ~= nil, true)

  local version_item = find_item(result_version.items, "2.1.0")
  MiniTest.expect.no_equality(version_item, nil)
  MiniTest.expect.equality(version_item.detail, "version")
  MiniTest.expect.equality(version_item.labelDetails.description, "requests")

  local line_extra = vim.api.nvim_buf_get_lines(bufnr, 4, 5, false)[1]
  local epos = line_extra:find("sec")
  local result_extra = run_complete(bufnr, 5, epos - 1)
  local extra_labels = {}
  for _, item in ipairs(result_extra.items or {}) do
    extra_labels[item.label] = true
  end
  MiniTest.expect.equality(extra_labels["security"] ~= nil, true)

  local extra_item = find_item(result_extra.items, "security")
  MiniTest.expect.no_equality(extra_item, nil)
  MiniTest.expect.equality(extra_item.detail, "extra")
  MiniTest.expect.equality(extra_item.labelDetails.description, "requests")

  local line_marker_extra = vim.api.nvim_buf_get_lines(bufnr, 5, 6, false)[1]
  local mpos = line_marker_extra:find("'d'")
  if mpos then
    mpos = mpos + 1
  end
  local result_marker = run_complete(bufnr, 6, mpos - 1)
  local marker_labels = {}
  for _, item in ipairs(result_marker.items or {}) do
    marker_labels[item.label] = true
  end
  MiniTest.expect.equality(marker_labels["dev"] ~= nil, true)

  local marker_item = find_item(result_marker.items, "dev")
  MiniTest.expect.no_equality(marker_item, nil)
  MiniTest.expect.equality(marker_item.detail, "marker extra")
  MiniTest.expect.equality(marker_item.labelDetails.description, "local")

  local line_marker_group = vim.api.nvim_buf_get_lines(bufnr, 6, 7, false)[1]
  local gpos = line_marker_group:find("'t'")
  if gpos then
    gpos = gpos + 1
  end
  local result_group = run_complete(bufnr, 7, gpos - 1)
  local group_labels = {}
  for _, item in ipairs(result_group.items or {}) do
    group_labels[item.label] = true
  end
  MiniTest.expect.equality(group_labels["test"] ~= nil, true)

  local group_item = find_item(result_group.items, "test")
  MiniTest.expect.no_equality(group_item, nil)
  MiniTest.expect.equality(group_item.detail, "marker group")
  MiniTest.expect.equality(group_item.labelDetails.description, "local")

  cleanup(dir)
end

---@param stub table
---@param fn fun()
local function with_pypi_stub(stub, fn)
  local original = package.loaded["pydeps.providers.pypi"]
  package.loaded["pydeps.providers.pypi"] = stub
  local ok, err = pcall(fn)
  package.loaded["pydeps.providers.pypi"] = original
  reset_completion_modules()
  if not ok then
    error(err, 0)
  end
end

local edit_pypi_stub = {
  search = function(_, cb)
    cb({ "requests" })
  end,
  get = function(_, cb)
    cb({ info = { provides_extra = { "security" } }, releases = {} })
  end,
  sorted_versions = function()
    return { "2.32.0" }
  end,
}

---Complete at the position of `|` in `line` and apply the item labelled `label`.
---@param bufnr integer
---@param line_num integer
---@param marked string line containing a single `|` cursor marker
---@param label string
---@return string
local function complete_and_apply(bufnr, line_num, marked, label)
  local col = marked:find("|", 1, true) - 1
  local line = marked:sub(1, col) .. marked:sub(col + 2)
  vim.api.nvim_buf_set_lines(bufnr, line_num - 1, line_num, false, { line })
  local result = run_complete(bufnr, line_num, col)
  local item = find_item(result and result.items, label)
  if not item then
    error(string.format("no %q item for %q", label, marked), 0)
  end
  vim.lsp.util.apply_text_edits({ item.textEdit }, bufnr, "utf-8")
  return vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1]
end

T["completion edits replace only the token at the cursor"] = function()
  with_pypi_stub(edit_pypi_stub, function()
    local dir = create_project({
      "[project]",
      "dependencies = [",
      '  "requests",',
      "  ",
      "]",
    })
    local config = require("pydeps.config")
    config.options.completion = { pypi_search = true, pypi_search_min = 2, max_results = 30 }
    local bufnr = vim.api.nvim_get_current_buf()

    local cases = {
      { '  "|",', "requests", '  "requests",' },
      { '  "requests>=|",', "2.32.0", '  "requests>=2.32.0",' },
      { '  "requests>=|"', "2.32.0", '  "requests>=2.32.0"' },
      { '  "requests[|",', "security", '  "requests[security",' },
      { '  "requests[|]>=2",', "security", '  "requests[security]>=2",' },
      { '  "req|uests>=2",', "requests", '  "requests>=2",' },
      { '  "requ|",', "requests", '  "requests",' },
      { '  "requests>=1.|0",', "2.32.0", '  "requests>=2.32.0",' },
      { '  "requests>=2,<|",', "2.32.0", '  "requests>=2,<2.32.0",' },
    }
    for _, case in ipairs(cases) do
      MiniTest.expect.equality(complete_and_apply(bufnr, 4, case[1], case[2]), case[3])
    end

    cleanup(dir)
  end)
end

T["completion only runs inside dependency arrays"] = function()
  with_pypi_stub(edit_pypi_stub, function()
    local lines = {
      "[project]",
      'description = "req"',
      "dependencies = [",
      '  # "req"',
      '  "req",',
      "]",
      "",
      "[project.urls]",
      'homepage = "https://req.example"',
      "",
      "[project.optional-dependencies]",
      'dev = ["req"]',
      "",
      "[dependency-groups]",
      'lint = [{ include-group = "req" }, "req"]',
      "",
      "[tool.ruff]",
      'select = ["req"]',
      "",
      "[tool.other]",
      'dependencies = ["req"]',
      "",
      "[project.scripts]",
      'dependencies = "req"',
    }
    local dir = create_project(lines)
    require("pydeps.config").options.completion = { pypi_search = true, pypi_search_min = 2 }
    local bufnr = vim.api.nvim_get_current_buf()

    ---@param line_num integer
    ---@param occurrence? integer
    ---@return integer
    local function count_at(line_num, occurrence)
      local line = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1]
      local col = 0
      for _ = 1, occurrence or 1 do
        col = line:find("req", col + 1, true)
      end
      local result = run_complete(bufnr, line_num, col + 2)
      return #(result.items or {})
    end

    -- positive: dependency arrays in every supported table
    MiniTest.expect.equality(count_at(5) > 0, true)
    MiniTest.expect.equality(count_at(12) > 0, true)
    MiniTest.expect.equality(count_at(15, 2) > 0, true)

    -- negative: other strings, comments, inline tables and unrelated tables
    MiniTest.expect.equality(count_at(2), 0)
    MiniTest.expect.equality(count_at(4), 0)
    MiniTest.expect.equality(count_at(9), 0)
    MiniTest.expect.equality(count_at(15, 1), 0)
    MiniTest.expect.equality(count_at(18), 0)
    MiniTest.expect.equality(count_at(21), 0)
    MiniTest.expect.equality(count_at(24), 0)

    cleanup(dir)
  end)
end

T["completion works in an unterminated dependency string"] = function()
  with_pypi_stub(edit_pypi_stub, function()
    local dir = create_project({
      "[project]",
      "dependencies = [",
      '  "requests",',
      '  "req',
      "]",
      "",
      "[tool.other]",
      'name = "x"',
    })
    require("pydeps.config").options.completion = { pypi_search = true, pypi_search_min = 2 }
    local bufnr = vim.api.nvim_get_current_buf()

    local result = run_complete(bufnr, 4, #'  "req')
    MiniTest.expect.no_equality(find_item(result.items, "requests"), nil)

    cleanup(dir)
  end)
end

T["completion - boundary conditions"] = function()
  reset_completion_modules()
  local completion = require("pydeps.completion.core")

  -- invalid buffer number should return empty result
  local result_invalid_buf = nil
  completion.complete(99999, { 1, 0 }, function(res)
    result_invalid_buf = res
  end)
  MiniTest.expect.equality(#(result_invalid_buf.items or {}), 0)

  -- non-pyproject.toml file should return empty result
  local non_pyproject_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(non_pyproject_buf, "/tmp/test.py")
  vim.api.nvim_buf_set_lines(non_pyproject_buf, 0, -1, false, { "import requests" })
  local result_non_pyproject = nil
  completion.complete(non_pyproject_buf, { 1, 10 }, function(res)
    result_non_pyproject = res
  end)
  MiniTest.expect.equality(#(result_non_pyproject.items or {}), 0)
  vim.api.nvim_buf_delete(non_pyproject_buf, { force = true })
end

T["completion scan_strings - escape sequences"] = function()
  reset_completion_modules()
  -- Create a pyproject.toml buffer for testing
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/pyproject.toml"
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, path)

  -- empty string
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
  local result_empty = nil
  require("pydeps.completion.core").complete(bufnr, { 1, 0 }, function(res)
    result_empty = res
  end)
  MiniTest.expect.equality(#(result_empty.items or {}), 0)

  -- string with no quotes
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "no quotes here" })
  local result_no_quotes = nil
  require("pydeps.completion.core").complete(bufnr, { 1, 5 }, function(res)
    result_no_quotes = res
  end)
  MiniTest.expect.equality(#(result_no_quotes.items or {}), 0)

  -- simple quoted strings - should trigger completion
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "dependencies = [\"hello\", 'world']" })
  local result_simple = nil
  require("pydeps.completion.core").complete(bufnr, { 1, 18 }, function(res)
    result_simple = res
  end)
  -- Should get items since we're inside a string in dependencies
  MiniTest.expect.no_equality(result_simple, nil)

  -- escaped quotes (backslash before quote)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { [[dependencies = ["hello \"world\""]] })
  local result_escaped = nil
  require("pydeps.completion.core").complete(bufnr, { 1, 20 }, function(res)
    result_escaped = res
  end)
  -- Should get items since we're inside a string
  MiniTest.expect.no_equality(result_escaped, nil)

  -- unclosed strings
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'dependencies = ["unclosed string' })
  local result_unclosed = nil
  require("pydeps.completion.core").complete(bufnr, { 1, 25 }, function(res)
    result_unclosed = res
  end)
  -- Should handle gracefully
  MiniTest.expect.no_equality(result_unclosed, nil)

  -- single quotes inside double quotes
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { [[dependencies = ["hello's world"]] })
  local result_nested = nil
  require("pydeps.completion.core").complete(bufnr, { 1, 20 }, function(res)
    result_nested = res
  end)
  MiniTest.expect.no_equality(result_nested, nil)

  -- empty quoted strings
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { [[dependencies = ["", ""]] })
  local result_empty_quotes = nil
  require("pydeps.completion.core").complete(bufnr, { 1, 18 }, function(res)
    result_empty_quotes = res
  end)
  -- Should handle empty strings gracefully
  MiniTest.expect.no_equality(result_empty_quotes, nil)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(dir, "rf")
end

T["completion detect_context - edge cases"] = function()
  reset_completion_modules()
  local completion = require("pydeps.completion.core")

  -- Create a pyproject.toml buffer
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/pyproject.toml"
  vim.fn.writefile({
    "[project]",
    'dependencies = ["requests"]',
  }, path)
  vim.cmd("edit " .. path)

  local bufnr = vim.api.nvim_get_current_buf()

  -- cursor at beginning of line
  local result_beginning = nil
  completion.complete(bufnr, { 2, 0 }, function(res)
    result_beginning = res
  end)
  MiniTest.expect.equality(#(result_beginning.items or {}), 0)

  -- cursor past end of line
  local line = vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1]
  local result_past_end = nil
  completion.complete(bufnr, { 2, #line + 10 }, function(res)
    result_past_end = res
  end)
  MiniTest.expect.equality(#(result_past_end.items or {}), 0)

  -- line with only whitespace
  vim.api.nvim_buf_set_lines(bufnr, 2, 2, false, { "   " })
  local result_whitespace = nil
  completion.complete(bufnr, { 3, 1 }, function(res)
    result_whitespace = res
  end)
  MiniTest.expect.equality(#(result_whitespace.items or {}), 0)

  -- cleanup
  vim.fn.delete(dir, "rf")
end

return T
