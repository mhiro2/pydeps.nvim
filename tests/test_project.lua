local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local project = require("pydeps.core.project")

local T = helpers.create_test_set()

T["find_root caches result per buffer"] = function()
  local temp_dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(temp_dir, "p")
  vim.fn.writefile({ "[project]" }, temp_dir .. "/pyproject.toml")

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, temp_dir .. "/test.py")
  project.clear_cache(bufnr)

  local root1 = project.find_root(bufnr)
  MiniTest.expect.equality(root1, temp_dir)

  -- Second call should return the same value (cached)
  local root2 = project.find_root(bufnr)
  MiniTest.expect.equality(root2, root1)

  -- Cleanup
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(temp_dir, "rf")
end

T["find_root caches nil result"] = function()
  local temp_dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(temp_dir, "p")
  -- No pyproject.toml or uv.lock

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, temp_dir .. "/test.py")
  project.clear_cache(bufnr)

  local root1 = project.find_root(bufnr)
  MiniTest.expect.equality(root1, nil)

  -- Create the file after the first lookup
  vim.fn.writefile({ "[project]" }, temp_dir .. "/pyproject.toml")

  -- Should still return nil (cached negative result)
  local root2 = project.find_root(bufnr)
  MiniTest.expect.equality(root2, nil)

  -- Cleanup
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(temp_dir, "rf")
end

T["clear_cache invalidates cached root"] = function()
  local temp_dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(temp_dir, "p")

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, temp_dir .. "/test.py")
  project.clear_cache(bufnr)

  -- First lookup: no pyproject.toml
  local root1 = project.find_root(bufnr)
  MiniTest.expect.equality(root1, nil)

  -- Now create the marker file and clear cache
  vim.fn.writefile({ "[project]" }, temp_dir .. "/pyproject.toml")
  project.clear_cache(bufnr)

  -- Should now find the root
  local root2 = project.find_root(bufnr)
  MiniTest.expect.equality(root2, temp_dir)

  -- Cleanup
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(temp_dir, "rf")
end

T["clear_cache allows re-lookup after buffer name change"] = function()
  local dir_a = vim.fn.resolve(vim.fn.tempname())
  local dir_b = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir_a, "p")
  vim.fn.mkdir(dir_b, "p")
  vim.fn.writefile({ "[project]" }, dir_a .. "/pyproject.toml")
  vim.fn.writefile({ "[project]" }, dir_b .. "/pyproject.toml")

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, dir_a .. "/test.py")
  project.clear_cache(bufnr)

  local root_a = project.find_root(bufnr)
  MiniTest.expect.equality(root_a, dir_a)

  -- Simulate buffer name change (:file / :edit reuse)
  vim.api.nvim_buf_set_name(bufnr, dir_b .. "/test.py")

  -- Without clear_cache the stale value would persist
  project.clear_cache(bufnr)

  local root_b = project.find_root(bufnr)
  MiniTest.expect.equality(root_b, dir_b)

  -- Cleanup
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(dir_a, "rf")
  vim.fn.delete(dir_b, "rf")
end

return T
