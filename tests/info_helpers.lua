local helpers = require("tests.test_helpers")

local M = {}

---@param target table
---@param overrides? table
---@return nil
local function apply_overrides(target, overrides)
  for key, value in pairs(overrides or {}) do
    if key ~= "dep" then
      if value == vim.NIL then
        target[key] = nil
      elseif type(value) == "table" and type(target[key]) == "table" and not vim.islist(value) then
        apply_overrides(target[key], value)
      else
        target[key] = vim.deepcopy(value)
      end
    end
  end
end

---@param overrides? table
---@return PyDepsDependency
function M.dep(overrides)
  return vim.tbl_deep_extend("force", {
    name = "testpkg",
    line = 2,
    col_start = 3,
    col_end = 10,
    spec = ">=1.0",
    group = "project",
  }, overrides or {})
end

---@param overrides? table
---@return PyDepsDependencyView
function M.view(overrides)
  local dep = M.dep(overrides and overrides.dep or nil)
  local base = {
    dep = dep,
    name = dep.name,
    spec = dep.spec,
    group = dep.group,
    marker = nil,
    current_env = { python_version = "3.11" },
    resolved = "1.0.0",
    latest = "1.0.0",
    meta = {
      info = {
        version = "1.0.0",
        summary = "HTTP library",
      },
      releases = {},
    },
    pending = nil,
    missing_lockfile = false,
    missing_lockfile_text = "missing uv.lock",
    lockfile_loading = false,
    unresolved = false,
    active = true,
    yanked = false,
    class = "ok",
    pinned_version = nil,
    base_class = "ok",
    base_pinned_version = nil,
    status_kind = "ok",
    status_text = "active",
    status_icon = "",
    lock_status = "(up-to-date)",
    show_latest_warning = false,
  }

  apply_overrides(base, overrides)
  return base
end

---@param meta? PyDepsPyPIMeta
---@param is_yanked? boolean
---@return nil
function M.stub_pypi(meta, is_yanked)
  local result = meta
    or {
      info = {
        version = "1.0.0",
        summary = "HTTP library",
      },
      releases = {},
    }

  helpers.stub_module("pydeps.providers.pypi", {
    get = function(_, cb)
      cb(result)
    end,
    is_yanked = function()
      return is_yanked == true
    end,
  })
end

---@return nil
function M.stub_pypi_not_found()
  helpers.stub_module("pydeps.providers.pypi", {
    get = function(_, cb)
      cb(nil)
    end,
    is_yanked = function()
      return false
    end,
  })
end

--- Stub PyPI so each `get` waits until the test releases its callback.
---@return { name: string, resolve: fun(meta: PyDepsPyPIMeta?) }[]
function M.stub_pypi_deferred()
  local requests = {}
  helpers.stub_module("pydeps.providers.pypi", {
    get = function(name, cb)
      table.insert(requests, { name = name, resolve = cb })
    end,
    is_yanked = function()
      return false
    end,
  })
  return requests
end

--- Parse uv.lock text with the real lockfile parser.
---@param lines string[]
---@return PyDepsLockfileData
function M.lock_data(lines)
  local path = vim.fn.tempname()
  vim.fn.writefile(lines, path)
  local data = require("pydeps.sources.lockfile").parse_full(path)
  vim.fn.delete(path)
  return data
end

---@param name string
---@param version string
---@param dependencies? string[]
---@return string[]
function M.lock_package_lines(name, version, dependencies)
  local lines = {
    "[[package]]",
    'name = "' .. name .. '"',
    'version = "' .. version .. '"',
    'source = { registry = "https://pypi.org/simple" }',
  }
  if dependencies and #dependencies > 0 then
    table.insert(lines, "dependencies = [")
    for _, dep in ipairs(dependencies) do
      table.insert(lines, '    { name = "' .. dep .. '" },')
    end
    table.insert(lines, "]")
  end
  table.insert(lines, "")
  return lines
end

---@param opts? { dep?: PyDepsDependency, lock_data?: PyDepsLockfileData, missing_lockfile?: boolean, lockfile_loading?: boolean }
---@return nil
function M.stub_cache(opts)
  opts = opts or {}
  local dep = opts.dep or M.dep()
  local lock_data = opts.lock_data
    or M.lock_data(vim.list_extend({ "version = 1", "" }, M.lock_package_lines(dep.name, "1.0.0")))

  helpers.stub_module("pydeps.core.cache", {
    get_pyproject = function()
      return { dep }
    end,
    get_lockfile = function()
      return lock_data, opts.missing_lockfile == true, opts.lockfile_loading == true
    end,
  })
  helpers.stub_module("pydeps.core.env", {
    get = function()
      return {}
    end,
  })
end

---@return nil
function M.reset_info_modules()
  package.loaded["pydeps.ui.info"] = nil
  package.loaded["pydeps.ui.info.render_lines"] = nil
  package.loaded["pydeps.ui.info.highlight"] = nil
  package.loaded["pydeps.ui.info.hover_lifecycle"] = nil
end

---@return table
function M.require_info()
  M.reset_info_modules()
  return require("pydeps.ui.info")
end

---@return table
function M.require_render_lines()
  package.loaded["pydeps.ui.info.render_lines"] = nil
  return require("pydeps.ui.info.render_lines")
end

---@return table
function M.require_highlight()
  package.loaded["pydeps.ui.info.highlight"] = nil
  return require("pydeps.ui.info.highlight")
end

---@param lines string[]
---@return nil
function M.setup_project_buffer(lines)
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = "toml"
  -- buffer_context.is_pyproject_buf matches on the buffer name suffix, so
  -- assign a unique path ending in `pyproject.toml` to make show_at_cursor
  -- recognise the buffer.
  if not vim.api.nvim_buf_get_name(bufnr):match("pyproject%.toml$") then
    pcall(vim.api.nvim_buf_set_name, bufnr, vim.fn.tempname() .. "/pyproject.toml")
  end
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

---@return integer?
function M.find_hover_win()
  -- Ask the info module directly so we never confuse an unrelated float for
  -- the hover window.
  return require("pydeps.ui.info").get_hover_win()
end

---@return integer?
function M.find_hover_buf()
  local win = M.find_hover_win()
  if not win then
    return nil
  end
  return vim.api.nvim_win_get_buf(win)
end

---@return string[]
function M.hover_lines()
  local buf = M.find_hover_buf()
  if not buf then
    return {}
  end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param bufnr integer
---@param lhs string
---@param desc string
---@return boolean
function M.has_keymap(bufnr, lhs, desc)
  for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if keymap.lhs == lhs and keymap.desc == desc then
      return true
    end
  end
  return false
end

---@param buf integer
---@param ns integer
---@return { row: integer, start_col: integer, end_col: integer, group: string }[]
function M.highlights(buf, ns)
  local result = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local details = mark[4] or {}
    if details.hl_group then
      table.insert(result, {
        row = mark[2],
        start_col = mark[3],
        end_col = details.end_col,
        group = details.hl_group,
      })
    end
  end
  return result
end

--- Return the highlight groups covering exactly `text` on the first line that contains it.
---@param buf integer
---@param ns integer
---@param text string
---@param line_pattern? string Lua pattern selecting the line; defaults to the text itself
---@return string[]
function M.groups_on(buf, ns, text, line_pattern)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(line_pattern or vim.pesc(text)) then
      local start = line:find(text, 1, true)
      local groups = {}
      if start then
        for _, hl in ipairs(M.highlights(buf, ns)) do
          if hl.row == row - 1 and hl.start_col == start - 1 and hl.end_col == start - 1 + #text then
            table.insert(groups, hl.group)
          end
        end
      end
      table.sort(groups)
      return groups
    end
  end
  return {}
end

return M
