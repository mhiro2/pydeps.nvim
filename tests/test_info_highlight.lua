local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local info_helpers = require("tests.info_helpers")

local T = helpers.create_test_set()

---@param view_overrides? table
---@param opts? PyDepsRenderOptions
---@return integer, integer, string[]
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
  return buf, highlight.namespace(), lines
end

---@param lines string[]
---@param label string
---@return string
local function label_prefix(lines, label)
  for _, line in ipairs(lines) do
    local prefix = line:match("^(%S*%s*" .. label .. ")%s")
    if prefix then
      return prefix
    end
  end
  error("no " .. label .. " line")
end

-- Each check names the exact text a highlight must cover and the line it sits on.
local cases = {
  {
    name = "default view",
    checks = function(lines)
      return {
        { text = lines[1], group = "PyDepsInfoPackage" },
        { text = "HTTP library", group = "PyDepsInfoDescription" },
        { text = label_prefix(lines, "spec"), group = "PyDepsInfoLabel" },
        { text = label_prefix(lines, "lock"), group = "PyDepsInfoLabel" },
        { text = label_prefix(lines, "latest"), group = "PyDepsInfoLabel" },
        { text = label_prefix(lines, "status"), group = "PyDepsInfoLabel" },
        { text = label_prefix(lines, "deps"), group = "PyDepsInfoLabel" },
        { text = label_prefix(lines, "pypi"), group = "PyDepsInfoLabel" },
        { text = "active", group = "PyDepsInfoStatusOk", line = "status" },
        { text = "https://pypi.org/pypi/testpkg", group = "PyDepsInfoUrl" },
        { text = "(up-to-date)", group = "PyDepsInfoSuffixOk" },
      }
    end,
  },
  {
    name = "extras",
    view = function()
      local dep = info_helpers.dep({ spec = "testpkg[fast]>=1.0", group = "optional:security" })
      return { dep = dep, spec = dep.spec, group = dep.group }
    end,
    checks = function(lines)
      return {
        { text = label_prefix(lines, "extras"), group = "PyDepsInfoLabel" },
        { text = "security, fast", group = "PyDepsInfoPill" },
      }
    end,
  },
  {
    name = "update available",
    view = function()
      return {
        latest = "2.0.0",
        status_kind = "update",
        status_text = "update available",
        show_latest_warning = true,
        lock_status = vim.NIL,
      }
    end,
    checks = function()
      return {
        { text = "update available", group = "PyDepsInfoStatusUpdate", line = "status" },
        { text = "(update available)", group = "PyDepsInfoSuffixWarn", line = "latest" },
      }
    end,
  },
  {
    name = "missing lockfile",
    view = function()
      return { resolved = vim.NIL }
    end,
    opts = { lockfile_missing = true },
    checks = function()
      return {
        { text = "(missing)", group = "PyDepsInfoSuffixError", line = "lock" },
      }
    end,
  },
  {
    name = "multibyte description",
    view = function()
      return { meta = { info = { version = "1.0.0", summary = "HTTP ライブラリ" }, releases = {} } }
    end,
    checks = function()
      return {
        { text = "HTTP ライブラリ", group = "PyDepsInfoDescription" },
      }
    end,
  },
}

for _, case in ipairs(cases) do
  T["highlight covers exact ranges: " .. case.name] = function()
    local buf, ns, lines = apply_highlight(case.view and case.view() or nil, case.opts)

    for _, check in ipairs(case.checks(lines)) do
      local line_pattern = check.line and ("%s" .. check.line .. "%s") or nil
      local groups = info_helpers.groups_on(buf, ns, check.text, line_pattern)
      MiniTest.expect.equality({ check.text, groups }, { check.text, { check.group } })
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

T["highlight marks no description without a summary"] = function()
  local buf, ns = apply_highlight({ meta = { info = { version = "1.0.0", summary = "" }, releases = {} } })

  for _, hl in ipairs(info_helpers.highlights(buf, ns)) do
    MiniTest.expect.no_equality(hl.group, "PyDepsInfoDescription")
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T
