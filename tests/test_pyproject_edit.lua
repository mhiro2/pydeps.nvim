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
  return dir, path
end

local function cleanup(dir)
  if dir then
    vim.fn.delete(dir, "rf")
  end
end

T["add dependency inline list"] = function()
  local edit = require("pydeps.sources.pyproject_edit")
  local dir = create_project({
    "[project]",
    'dependencies = ["requests>=2"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  edit.add_dependency(bufnr, "project", "rich==13.7.0")

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(lines[2], 'dependencies = ["requests>=2", "rich==13.7.0"]')
  cleanup(dir)
end

T["add dependency new optional group"] = function()
  local edit = require("pydeps.sources.pyproject_edit")
  local dir = create_project({
    "[project]",
    'dependencies = ["requests"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  edit.add_dependency(bufnr, "optional:dev", "pytest>=7")

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local joined = table.concat(lines, "\n")
  MiniTest.expect.equality(joined:match("%[project%.optional%-dependencies%]") ~= nil, true)
  MiniTest.expect.equality(joined:match('dev%s*=%s*%["pytest>=7"%]') ~= nil, true)
  cleanup(dir)
end

T["replace and remove dependency"] = function()
  local pyproject = require("pydeps.sources.pyproject")
  local edit = require("pydeps.sources.pyproject_edit")
  local dir = create_project({
    "[project]",
    "dependencies = [",
    '  "requests>=2",',
    '  "rich==13.7.0",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local requests = nil
  local rich = nil
  for _, dep in ipairs(deps) do
    if dep.name == "requests" then
      requests = dep
    elseif dep.name == "rich" then
      rich = dep
    end
  end

  edit.replace_dependency(bufnr, requests, "requests==2.32.0")
  edit.remove_dependency(bufnr, rich)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local joined = table.concat(lines, "\n")
  MiniTest.expect.equality(joined:match("requests==2%.32%.0") ~= nil, true)
  MiniTest.expect.equality(joined:match("rich==13%.7%.0") ~= nil, false)
  cleanup(dir)
end

return T
