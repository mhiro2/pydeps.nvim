local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

local function stub_env()
  package.loaded["pydeps.core.env"] = {
    get = function()
      return {}
    end,
  }
end

local function stub_pypi()
  package.loaded["pydeps.providers.pypi"] = {
    get_cached = function()
      return nil
    end,
    get = function(_, cb)
      if cb then
        cb({ releases = {} })
      end
    end,
    is_yanked = function()
      return false
    end,
  }
end

local function setup_virtual_text()
  stub_env()
  stub_pypi()
  package.loaded["pydeps.ui.virtual_text"] = nil
  local config = require("pydeps.config")
  config.setup({
    show_missing_virtual_text = false,
    ui = {
      section_padding = 2,
      icons = { enabled = false },
      show = {
        resolved = true,
        latest = false,
      },
    },
  })
  return require("pydeps.ui.virtual_text")
end

T["inline badge moves after comment"] = function()
  local virtual_text = setup_virtual_text()
  local pyproject = require("pydeps.sources.pyproject")
  local util = require("pydeps.util")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "short>=1.0",        # comment',
    '  "averyverylongpackage>=1.0",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local resolved = {
    short = "1.0.0",
    averyverylongpackage = "1.0.0",
  }

  virtual_text.render(bufnr, deps, resolved, { lockfile_missing = false })

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, virtual_text.ns, 0, -1, { details = true })
  local by_line = {}
  for _, mark in ipairs(marks) do
    local row = mark[2]
    local details = mark[4] or {}
    if details.virt_text_win_col then
      by_line[row] = { col = details.virt_text_win_col, virt_text = details.virt_text }
    end
  end

  local comment_row = 2
  local plain_row = 3

  MiniTest.expect.equality(by_line[comment_row] ~= nil, true)
  MiniTest.expect.equality(by_line[plain_row] ~= nil, true)

  local comment_line = vim.api.nvim_buf_get_lines(bufnr, comment_row, comment_row + 1, false)[1]
  local comment_col = util.find_comment_pos(comment_line)
  MiniTest.expect.equality(comment_col ~= nil, true)

  local comment_end = vim.fn.strdisplaywidth(comment_line)

  MiniTest.expect.equality(by_line[comment_row].col >= comment_end + 1, true)
  MiniTest.expect.equality(by_line[comment_row].col > by_line[plain_row].col, true)
end

T["inline badge moves after wide comment"] = function()
  local virtual_text = setup_virtual_text()
  local pyproject = require("pydeps.sources.pyproject")
  local util = require("pydeps.util")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "wide>=1.0", #\tcomment',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local resolved = { wide = "1.0.0" }

  virtual_text.render(bufnr, deps, resolved, { lockfile_missing = false })

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, virtual_text.ns, 0, -1, { details = true })
  local row = marks[1] and marks[1][2]
  MiniTest.expect.equality(row ~= nil, true)

  local comment_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  local comment_col = util.find_comment_pos(comment_line)
  MiniTest.expect.equality(comment_col ~= nil, true)

  local comment_end = vim.fn.strdisplaywidth(comment_line)
  local col = marks[1][4].virt_text_win_col
  MiniTest.expect.equality(col >= comment_end + 1, true)
end

T["inline badge aligns without comments"] = function()
  local virtual_text = setup_virtual_text()
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "short>=1.0",',
    '  "averyverylongpackage>=1.0",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local resolved = {
    short = "1.0.0",
    averyverylongpackage = "1.0.0",
  }

  virtual_text.render(bufnr, deps, resolved, { lockfile_missing = false })

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, virtual_text.ns, 0, -1, { details = true })
  local cols = {}
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    if details.virt_text_win_col then
      table.insert(cols, details.virt_text_win_col)
    end
  end

  MiniTest.expect.equality(#cols, 2)
  MiniTest.expect.equality(cols[1] == cols[2], true)
end

T["lock mismatch shows pinned version in badge"] = function()
  local virtual_text = setup_virtual_text()
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "pinnedpkg==1.0.0",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local resolved = {
    pinnedpkg = "1.1.0",
  }

  virtual_text.render(bufnr, deps, resolved, { lockfile_missing = false })

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, virtual_text.ns, 0, -1, { details = true })
  MiniTest.expect.equality(#marks, 1)

  local details = marks[1][4] or {}
  local virt_text = details.virt_text or {}

  -- Should show resolved version and lock mismatch icon with pinned version
  local text = ""
  for _, chunk in ipairs(virt_text) do
    text = text .. chunk[1]
  end

  -- Should contain resolved version "1.1.0" and pinned version "1.0.0"
  MiniTest.expect.equality(string.find(text, "1.1.0") ~= nil, true)
  MiniTest.expect.equality(string.find(text, "1.0.0") ~= nil, true)
end

T["pin not found shows message when version not on PyPI"] = function()
  stub_env()
  package.loaded["pydeps.providers.pypi"] = {
    get_cached = function(name)
      if name == "notfoundpkg" then
        return {
          releases = {
            ["1.0.0"] = {},
            ["1.2.0"] = {},
          },
        }
      end
      return nil
    end,
    get = function(_, cb)
      cb({})
    end,
    is_yanked = function()
      return false
    end,
  }
  package.loaded["pydeps.ui.virtual_text"] = nil
  local config = require("pydeps.config")
  config.setup({
    show_missing_virtual_text = false,
    ui = {
      section_padding = 2,
      icons = { enabled = false },
      show = {
        resolved = true,
        latest = false,
      },
    },
  })
  local virtual_text = require("pydeps.ui.virtual_text")
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "notfoundpkg==1.1.0",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local resolved = {
    notfoundpkg = "1.1.0",
  }

  virtual_text.render(bufnr, deps, resolved, { lockfile_missing = false })

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, virtual_text.ns, 0, -1, { details = true })
  MiniTest.expect.equality(#marks, 1)

  local details = marks[1][4] or {}
  local virt_text = details.virt_text or {}

  -- Should show "not on public PyPI" message
  local text = ""
  for _, chunk in ipairs(virt_text) do
    text = text .. chunk[1]
  end

  MiniTest.expect.equality(string.find(text, "not on public PyPI") ~= nil, true)
end

T["virtual_text: does not leak helper globals"] = function()
  stub_env()
  stub_pypi()
  _G.should_render_virtual_text = nil
  _G.queue_pypi_request = nil
  _G.get_treesitter_ranges = nil
  package.loaded["pydeps.ui.virtual_text"] = nil

  local _ = require("pydeps.ui.virtual_text")

  MiniTest.expect.equality(rawget(_G, "should_render_virtual_text"), nil)
  MiniTest.expect.equality(rawget(_G, "queue_pypi_request"), nil)
  MiniTest.expect.equality(rawget(_G, "get_treesitter_ranges"), nil)
end

return T
