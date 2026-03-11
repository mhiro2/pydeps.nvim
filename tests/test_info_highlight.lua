local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local info_helpers = require("tests.info_helpers")

local T = helpers.create_test_set()

---@param view_overrides? table
---@param opts? PyDepsRenderOptions
---@return integer, integer
local function apply_highlight(view_overrides, opts)
  info_helpers.stub_cache()

  local render_lines = info_helpers.require_render_lines()
  local highlight = info_helpers.require_highlight()
  local view = info_helpers.view(view_overrides)
  local lines = render_lines.build_lines(view, opts or {})
  local status = render_lines.determine_status(view)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  highlight.apply(buf, view.dep, lines, status)
  return buf, highlight.namespace()
end

T["highlight marks package title"] = function()
  local buf, ns = apply_highlight()
  MiniTest.expect.equality(info_helpers.has_highlight(buf, ns, "PyDepsInfoPackage"), true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["highlight marks description and labels"] = function()
  local buf, ns = apply_highlight()
  MiniTest.expect.equality(info_helpers.has_highlight(buf, ns, "PyDepsInfoDescription"), true)
  MiniTest.expect.equality(info_helpers.has_highlight(buf, ns, "PyDepsInfoLabel"), true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["highlight marks extras as pills"] = function()
  local dep = info_helpers.dep({
    spec = "testpkg[fast]>=1.0",
    group = "optional:security",
  })
  local buf, ns = apply_highlight({
    dep = dep,
    spec = dep.spec,
    group = dep.group,
  })

  MiniTest.expect.equality(info_helpers.has_highlight(buf, ns, "PyDepsInfoPill"), true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["highlight marks status value with kind-specific group"] = function()
  local buf, ns = apply_highlight({
    status_kind = "update",
    status_text = "update available",
  })

  MiniTest.expect.equality(info_helpers.has_highlight(buf, ns, "PyDepsInfoStatusUpdate"), true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["highlight marks PyPI URLs"] = function()
  local buf, ns = apply_highlight()
  MiniTest.expect.equality(info_helpers.has_highlight(buf, ns, "PyDepsInfoUrl"), true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["highlight marks ok suffixes"] = function()
  local buf, ns = apply_highlight()
  MiniTest.expect.equality(info_helpers.has_highlight(buf, ns, "PyDepsInfoSuffixOk"), true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["highlight marks warn suffixes"] = function()
  local buf, ns = apply_highlight({
    latest = "2.0.0",
    status_kind = "update",
    status_text = "update available",
    show_latest_warning = true,
    lock_status = nil,
  })

  MiniTest.expect.equality(info_helpers.has_highlight(buf, ns, "PyDepsInfoSuffixWarn"), true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["highlight marks error suffixes for missing values"] = function()
  local buf, ns = apply_highlight({ resolved = vim.NIL }, { lockfile_missing = true })

  MiniTest.expect.equality(info_helpers.has_highlight(buf, ns, "PyDepsInfoSuffixError"), true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T
