local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

-- Drive the hover through the real autocmds registered by state, the real
-- why float and the real output window instead of calling suspend/resume.
local T = helpers.new_set({
  hooks = {
    pre_case = function()
      helpers.close_extra_windows()
      vim.cmd("enew!")
    end,
  },
})

---@return integer bufnr
---@return PyDepsDependency dep
local function open_project_with_hover()
  helpers.stub(require("pydeps.core.env"), "get", function()
    return {}
  end)
  local pypi = require("pydeps.providers.pypi")
  local meta = { info = { version = "2.31.0" }, releases = {} }
  helpers.stub(pypi, "get_cached", function()
    return meta
  end)
  helpers.stub(pypi, "get", function(_, cb)
    if cb then
      cb(meta)
    end
  end)

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "[project]", 'dependencies = ["requests>=2"]' }, dir .. "/pyproject.toml")
  helpers.create_uv_lock(dir)
  helpers.defer(function()
    vim.fn.delete(dir, "rf")
  end)

  require("pydeps").setup({ auto_refresh = true, notify_on_missing_lockfile = false })
  helpers.defer(require("pydeps.core.state").disable)
  vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/pyproject.toml"))
  local bufnr = vim.api.nvim_get_current_buf()
  local dep = require("pydeps.core.buffer_context").get_deps(bufnr)[1]

  local info = require("pydeps.ui.info")
  info.show(dep, "2.31.0", {})
  MiniTest.expect.no_equality(info.get_hover_win(), nil)
  return bufnr, dep
end

T["leaving the pyproject buffer closes its hover"] = function()
  open_project_with_hover()

  vim.cmd("enew")

  MiniTest.expect.equality(require("pydeps.ui.info").get_hover_win(), nil)
end

T["the why float keeps the hover open until it closes"] = function()
  local bufnr, dep = open_project_with_hover()
  local info = require("pydeps.ui.info")
  local source_win = vim.api.nvim_get_current_win()

  -- Opening the float moves focus off the pyproject buffer and fires BufLeave.
  require("pydeps.ui.provenance").show(dep.name, { dep }, { requests = {} })
  local why_buf = vim.api.nvim_get_current_buf()
  MiniTest.expect.no_equality(why_buf, bufnr)
  MiniTest.expect.no_equality(info.get_hover_win(), nil)
  MiniTest.expect.equality(info.should_close_hover(), false)

  for _, map in ipairs(vim.api.nvim_buf_get_keymap(why_buf, "n")) do
    if map.lhs == "q" then
      map.callback()
    end
  end
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(why_buf) and vim.fn.bufwinid(why_buf) ~= -1, false)
  MiniTest.expect.equality(info.should_close_hover(), true)

  -- Once the float is gone, leaving the buffer closes the hover again.
  vim.api.nvim_set_current_win(source_win)
  vim.cmd("enew")
  MiniTest.expect.equality(info.get_hover_win(), nil)
end

return T
