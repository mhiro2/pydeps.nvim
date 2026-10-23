local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local T = helpers.create_test_set()

local mutations = {
  insert = function(buf)
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { 'description = "KEEP THIS TEXT"' })
  end,
  delete = function(buf)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
  end,
  rewrite = function(buf)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'dependencies = ["requests==3"]' })
  end,
  undo = function(buf)
    vim.cmd("let &undolevels = &undolevels")
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "# temporary" })
    vim.cmd("undo")
  end,
  unchanged = function() end,
}

for name, mutate in pairs(mutations) do
  T["pending update preserves " .. name] = function()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/pyproject.toml")
    vim.bo[buf].filetype = "toml"
    helpers.setup_buffer({
      "[project]",
      'dependencies = ["requests==1"]',
      "[project.optional-dependencies]",
      'dev = ["requests==4"]',
    })
    vim.api.nvim_win_set_cursor(0, { 2, 20 })
    helpers.stub(require("pydeps.core.buffer_context"), "get_deps", function()
      return { { name = "requests", spec = "requests==1", line = 2, col_start = 17, col_end = 29 } }
    end)
    local callback, warning, refreshed
    helpers.stub(require("pydeps.providers.pypi"), "get", function(_, cb)
      callback = cb
    end)
    helpers.stub(require("pydeps.core.state"), "refresh", function()
      refreshed = true
    end)
    helpers.stub(vim, "notify", function(msg)
      warning = msg
    end)
    helpers.stub_module("pydeps.commands.update", nil)

    require("pydeps.commands.update").run("requests")
    MiniTest.expect.equality(type(callback), "function")
    mutate(buf)
    local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    callback({ info = { version = "2" } })
    local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if name == "unchanged" then
      before[2] = 'dependencies = ["requests==2"]'
      MiniTest.expect.equality(after, before)
      MiniTest.expect.equality(refreshed, true)
    else
      MiniTest.expect.equality(after, before)
      MiniTest.expect.equality(warning:find("buffer changed", 1, true) ~= nil, true)
      MiniTest.expect.equality(refreshed, nil)
    end
  end
end

T["deferred package prompt updates the buffer that asked"] = function()
  local function pyproject_buf(spec)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/pyproject.toml")
    vim.bo[buf].filetype = "toml"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "[project]", 'dependencies = ["' .. spec .. '"]' })
    return buf
  end

  local origin = pyproject_buf("requests==1")
  local other = pyproject_buf("requests==9")
  vim.api.nvim_set_current_buf(origin)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  local warning
  helpers.stub(vim, "notify", function(msg)
    warning = msg
  end)
  helpers.stub(require("pydeps.core.buffer_context"), "get_deps", function(bufnr)
    local spec = bufnr == origin and "requests==1" or "requests==9"
    return { { name = "requests", spec = spec, line = 2, col_start = 17, col_end = 16 + #spec + 2 } }
  end)
  local prompt
  helpers.stub(vim.ui, "input", function(_, cb)
    prompt = cb
  end)
  local callback
  helpers.stub(require("pydeps.providers.pypi"), "get", function(_, cb)
    callback = cb
  end)
  helpers.stub(require("pydeps.core.state"), "refresh", function() end)
  helpers.stub_module("pydeps.commands.update", nil)

  require("pydeps.commands.update").run()
  MiniTest.expect.equality(type(prompt), "function")
  -- The user moves to another project before answering the prompt.
  vim.api.nvim_set_current_buf(other)
  prompt("requests")
  MiniTest.expect.equality(type(callback), "function")
  callback({ info = { version = "2" } })
  MiniTest.expect.equality(vim.api.nvim_buf_get_lines(origin, 1, 2, false), { 'dependencies = ["requests==2"]' })
  MiniTest.expect.equality(vim.api.nvim_buf_get_lines(other, 1, 2, false), { 'dependencies = ["requests==9"]' })

  -- Closing the requesting buffer cancels rather than falling back to the current one.
  callback, warning = nil, nil
  vim.api.nvim_set_current_buf(origin)
  require("pydeps.commands.update").run()
  vim.api.nvim_set_current_buf(other)
  vim.api.nvim_buf_delete(origin, { force = true })
  prompt("requests")
  MiniTest.expect.equality(callback, nil)
  MiniTest.expect.equality(warning:find("no longer available", 1, true) ~= nil, true)
  MiniTest.expect.equality(vim.api.nvim_buf_get_lines(other, 1, 2, false), { 'dependencies = ["requests==9"]' })
end

return T
