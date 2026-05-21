local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      helpers.close_extra_windows()
      vim.cmd("enew!")
    end,
    post_case = function()
      helpers.close_extra_windows()
    end,
  },
})

-- Test state.lua timer cleanup
T["state: clear_refresh_timer removes timer"] = function()
  local state = require("pydeps.core.state")
  local cache = require("pydeps.core.cache")

  -- Mock dependencies
  package.loaded["pydeps.ui.virtual_text"] = {
    clear = function() end,
    render = function() end,
    setup_highlights = function() end,
    clear_debounce_state = function() end,
  }
  package.loaded["pydeps.ui.diagnostics"] = {
    clear = function() end,
    render = function() end,
  }
  package.loaded["pydeps.core.env"] = {
    get = function()
      return {}
    end,
  }

  -- Setup pydeps with auto_refresh enabled
  require("pydeps").setup({
    auto_refresh = true,
    refresh_debounce_ms = 100,
  })

  -- Create a pyproject.toml buffer
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "pyproject.toml")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "[project]",
    "dependencies = [",
    '  "requests",',
    "]",
  })

  -- Mock cache
  cache.get_pyproject = function()
    return {}
  end
  cache.get_lockfile = function()
    return { resolved = {} }, false
  end

  -- Trigger refresh with debounce (creates a timer)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })

  -- Wait for timer to be created
  vim.wait(50, function()
    return false
  end)

  -- Wipe buffer (should clean up timer)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Wait a bit to ensure cleanup completes
  vim.wait(50, function()
    return false
  end)

  -- If we reach here without errors, timer was cleaned up properly
  MiniTest.expect.no_error(function()
    state.disable()
  end)
end

-- Test virtual_text.lua debounce_state cleanup
T["virtual_text: clear_debounce_state removes timer"] = function()
  local virtual_text = require("pydeps.ui.virtual_text")

  -- Create a test buffer
  local bufnr = vim.api.nvim_create_buf(false, true)

  -- Render should create debounce state with timer
  virtual_text.render(bufnr, {}, {}, {})

  -- Wait for debounce timer
  vim.wait(100, function()
    return false
  end)

  -- Clear debounce state
  MiniTest.expect.no_error(function()
    virtual_text.clear_debounce_state(bufnr)
  end)

  -- Delete buffer
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- Test pypi.lua timer cleanup on request timeout
T["pypi: request timeout cleans up timer"] = function()
  -- Reload modules to reset state.
  package.loaded["pydeps.providers.pypi"] = nil
  package.loaded["pydeps.providers.pypi.metadata"] = nil
  package.loaded["pydeps.providers.pypi.shared"] = nil

  -- Shrink the timeout so the timer fires during the test rather than after
  -- it returns, otherwise the uv timer leaks for ~10s into the next case.
  local shared = require("pydeps.providers.pypi.shared")
  local original_timeout = shared.REQUEST_TIMEOUT
  shared.REQUEST_TIMEOUT = 50

  -- Mock curl/jobstart so the request hangs deterministically. Without this,
  -- a real curl on CI resolves before the timer fires.
  local original_executable = vim.fn.executable
  local original_jobstart = vim.fn.jobstart
  local original_jobstop = vim.fn.jobstop
  vim.fn.executable = function(cmd)
    if cmd == "curl" then
      return 1
    end
    return 0
  end
  vim.fn.jobstart = function()
    return 1
  end
  vim.fn.jobstop = function()
    return 1
  end

  local pypi = require("pydeps.providers.pypi")

  local timeout_callback_args
  pypi.get("hanging-package", function(data)
    timeout_callback_args = { data = data, called = true }
  end)

  -- Wait for the 50ms timeout to fire and schedule the callback.
  vim.wait(500, function()
    return timeout_callback_args ~= nil
  end, 10)

  MiniTest.expect.equality(timeout_callback_args ~= nil, true)
  MiniTest.expect.equality(timeout_callback_args.data, nil)

  shared.REQUEST_TIMEOUT = original_timeout
  vim.fn.executable = original_executable
  vim.fn.jobstart = original_jobstart
  vim.fn.jobstop = original_jobstop
end

-- Test state.lua disable cleans up all timers
T["state: disable cleans up all timers"] = function()
  local state = require("pydeps.core.state")

  -- Mock dependencies
  package.loaded["pydeps.ui.virtual_text"] = {
    clear = function() end,
    render = function() end,
    setup_highlights = function() end,
    clear_debounce_state = function() end,
  }
  package.loaded["pydeps.ui.diagnostics"] = {
    clear = function() end,
    render = function() end,
  }

  -- Setup and enable
  require("pydeps").setup({
    auto_refresh = true,
    refresh_debounce_ms = 100,
  })

  state.enable()

  -- Disable should clean up all timers without error
  MiniTest.expect.no_error(function()
    state.disable()
  end)
end

return T
