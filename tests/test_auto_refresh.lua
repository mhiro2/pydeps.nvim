local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      helpers.close_extra_windows()
      vim.cmd("enew!")
      package.loaded["pydeps.core.env"] = {
        get = function()
          return {}
        end,
      }
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
        sorted_versions = function()
          return {}
        end,
      }
      package.loaded["pydeps.ui.virtual_text"] = nil
      package.loaded["pydeps.ui.diagnostics"] = nil
      require("pydeps").setup({
        auto_refresh = true,
        refresh_debounce_ms = 10,
        enable_diagnostics = false,
        notify_on_missing_lockfile = false,
        show_missing_virtual_text = false,
        show_missing_lockfile_virtual_text = true,
        ui = {
          section_padding = 2,
          icons = { enabled = false },
          show = {
            resolved = true,
            latest = false,
          },
        },
      })
    end,
    post_case = function()
      require("pydeps.core.state").disable()
    end,
  },
})

local function create_project(lines, packages)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/pyproject.toml"
  vim.fn.writefile(lines, path)
  helpers.create_uv_lock(dir, packages)
  vim.cmd("edit " .. path)
  helpers.setup_buffer(lines)
  return dir
end

local function cleanup(dir)
  if dir then
    vim.fn.delete(dir, "rf")
  end
end

T["auto_refresh updates virtual text on TextChanged"] = function()
  local dir = create_project({
    "[project]",
    "dependencies = [",
    '  "requests>=2",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local virtual_text = require("pydeps.ui.virtual_text")
  local state = require("pydeps.core.state")

  state.refresh(bufnr)

  local function count_marks()
    return #vim.api.nvim_buf_get_extmarks(bufnr, virtual_text.ns, 0, -1, {})
  end

  local ok_initial = vim.wait(200, function()
    return count_marks() == 1
  end, 10)
  MiniTest.expect.equality(ok_initial, true)

  vim.api.nvim_buf_set_lines(bufnr, 3, 3, false, { '  "rich==13.7.0",' })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })

  local ok = vim.wait(200, function()
    return count_marks() == 2
  end, 10)

  MiniTest.expect.equality(ok, true)
  cleanup(dir)
end

return T
