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
    local context = require("pydeps.core.buffer_context")
    local old_deps = context.get_deps
    context.get_deps = function()
      return { { name = "requests", spec = "requests==1", line = 2, col_start = 17, col_end = 29 } }
    end
    local pypi = require("pydeps.providers.pypi")
    local state = require("pydeps.core.state")
    local old_get, old_refresh, old_notify = pypi.get, state.refresh, vim.notify
    local callback, warning, refreshed
    pypi.get = function(_, cb)
      callback = cb
    end
    state.refresh = function()
      refreshed = true
    end
    vim.notify = function(msg)
      warning = msg
    end
    local old_update = package.loaded["pydeps.commands.update"]
    package.loaded["pydeps.commands.update"] = nil
    local ok, err = pcall(function()
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
    end)
    pypi.get, state.refresh, vim.notify = old_get, old_refresh, old_notify
    context.get_deps = old_deps
    package.loaded["pydeps.commands.update"] = old_update
    if not ok then
      error(err)
    end
  end
end

return T
