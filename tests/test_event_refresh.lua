local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      helpers.close_extra_windows()
      vim.cmd("enew!")

      package.loaded["pydeps"] = nil
      package.loaded["pydeps.core.state"] = nil

      package.loaded["pydeps.core.cache"] = {
        get_pyproject = function()
          return {
            { name = "requests", spec = "requests", line = 1, col_start = 1, col_end = 1 },
          }
        end,
        get_lockfile = function()
          return { resolved = { requests = "2.0.0" } }, false
        end,
        invalidate_pyproject = function() end,
        invalidate_lockfile = function() end,
      }
      package.loaded["pydeps.core.project"] = {
        find_root = function()
          return "/tmp"
        end,
        clear_cache = function() end,
        clear_all_caches = function() end,
      }
      package.loaded["pydeps.ui.virtual_text"] = {
        ns = vim.api.nvim_create_namespace("pydeps-test-vt"),
        setup_highlights = function() end,
        clear = function() end,
        clear_debounce_state = function() end,
        render = function(bufnr)
          vim.b[bufnr].render_count = (vim.b[bufnr].render_count or 0) + 1
        end,
      }
      package.loaded["pydeps.ui.diagnostics"] = {
        clear = function() end,
        render = function() end,
      }
      package.loaded["pydeps.ui.info"] = {
        show_at_cursor = function() end,
        close_hover = function() end,
        should_close_hover = function()
          return true
        end,
      }

      require("pydeps").setup({
        auto_refresh = true,
        refresh_debounce_ms = 0,
        enable_diagnostics = false,
        notify_on_missing_lockfile = false,
        show_missing_virtual_text = false,
      })
    end,
    post_case = function()
      require("pydeps.core.state").disable()
    end,
  },
})

local function make_pyproject_buf(name)
  vim.cmd("edit " .. name)
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "toml"
  return buf
end

T["event refresh updates all buffers"] = function()
  local buf1 = make_pyproject_buf("/tmp/a/pyproject.toml")
  local buf2 = make_pyproject_buf("/tmp/b/pyproject.toml")

  vim.b[buf1].render_count = 0
  vim.b[buf2].render_count = 0

  local state = require("pydeps.core.state")
  state.refresh(buf1)
  state.refresh(buf2)

  MiniTest.expect.equality(vim.b[buf1].render_count, 1)
  MiniTest.expect.equality(vim.b[buf2].render_count, 1)

  vim.api.nvim_exec_autocmds("User", { pattern = "PyDepsPyPIUpdated", data = { name = "requests" } })

  local ok = vim.wait(200, function()
    return (vim.b[buf1].render_count or 0) == 2 and (vim.b[buf2].render_count or 0) == 2
  end, 10)

  MiniTest.expect.equality(ok, true)

  vim.api.nvim_exec_autocmds("User", { pattern = "PyDepsEnvUpdated", data = { root = "/tmp" } })

  local ok2 = vim.wait(200, function()
    return (vim.b[buf1].render_count or 0) == 3 and (vim.b[buf2].render_count or 0) == 3
  end, 10)

  MiniTest.expect.equality(ok2, true)
end

return T
