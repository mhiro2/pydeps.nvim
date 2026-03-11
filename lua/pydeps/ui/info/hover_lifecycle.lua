local buffer_context = require("pydeps.core.buffer_context")
local cache = require("pydeps.core.cache")
local config = require("pydeps.config")
local dependency_view = require("pydeps.ui.dependency_view")
local highlight = require("pydeps.ui.info.highlight")
local pypi = require("pydeps.providers.pypi")
local render_lines = require("pydeps.ui.info.render_lines")

local M = {}

---@class PyDepsInfoResources
---@field win_id integer?
---@field buf_id integer?
---@field keymap_buf integer?
---@field saved_keymaps table<string, vim.api.keyset.get_keymap>?

---@class PyDepsInfoHoverWindowOptions
---@field zindex? integer

---@type PyDepsInfoResources
local resources = {
  win_id = nil,
  buf_id = nil,
  keymap_buf = nil,
  saved_keymaps = nil,
}

---@type boolean
local suppress_hover_close = false

---@type integer
local info_generation = 0

---@param lines string[]
---@return integer
local function max_width(lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return width
end

---@param width integer
---@param height integer
---@return integer, integer
local function clamp_window_size(width, height)
  local max_win_width = vim.o.columns - 4
  local max_win_height = vim.o.lines - 4
  return math.min(width, max_win_width), math.min(height, max_win_height)
end

---@param lines string[]
---@return integer, integer
local function hover_window_size(lines)
  return clamp_window_size(max_width(lines) + 2, #lines)
end

---@param width integer
---@param height integer
---@param window_opts? PyDepsInfoHoverWindowOptions
---@return vim.api.keyset.win_config
local function hover_win_config(width, height, window_opts)
  local cfg = {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = config.options.info_window_border or "rounded",
  }

  if window_opts and window_opts.zindex then
    cfg.zindex = window_opts.zindex
  end

  return cfg
end

---@return integer
local function next_generation()
  info_generation = info_generation + 1
  return info_generation
end

---@param value any
---@return boolean?
local function normalize_bool(value)
  if value == nil then
    return nil
  end
  return value == true or value == 1
end

---@param map vim.api.keyset.get_keymap
---@param bufnr integer
---@return nil
local function restore_keymap(map, bufnr)
  local rhs = map.callback or map.rhs
  if rhs == nil then
    return
  end

  local opts = {
    buffer = bufnr,
    desc = map.desc,
    expr = normalize_bool(map.expr),
    noremap = normalize_bool(map.noremap),
    nowait = normalize_bool(map.nowait),
    script = normalize_bool(map.script),
    silent = normalize_bool(map.silent),
  }

  vim.keymap.set("n", map.lhs, rhs, opts)
end

---@param key string
---@param bufnr integer
---@return vim.api.keyset.get_keymap?
local function get_buffer_keymap(key, bufnr)
  local ok, keymaps = pcall(vim.keymap.get, "n", key, { buffer = bufnr })
  if not ok or type(keymaps) ~= "table" then
    return nil
  end

  if keymaps[1] then
    return keymaps[1]
  end

  if keymaps.lhs then
    return keymaps
  end

  return nil
end

---@return nil
local function clear_hover_window()
  if resources.win_id and vim.api.nvim_win_is_valid(resources.win_id) then
    pcall(vim.api.nvim_win_close, resources.win_id, true)
  end
  resources.win_id = nil
  resources.buf_id = nil
end

---@return nil
local function restore_source_keymaps()
  local keymap_buf = resources.keymap_buf
  local saved_keymaps = resources.saved_keymaps

  resources.keymap_buf = nil
  resources.saved_keymaps = nil

  if not keymap_buf or not vim.api.nvim_buf_is_valid(keymap_buf) then
    return
  end

  pcall(vim.keymap.del, "n", "<CR>", { buffer = keymap_buf })
  pcall(vim.keymap.del, "n", "gT", { buffer = keymap_buf })

  for _, map in pairs(saved_keymaps or {}) do
    restore_keymap(map, keymap_buf)
  end
end

---@return nil
local function cleanup_all_resources()
  clear_hover_window()
  restore_source_keymaps()
end

---@param dep PyDepsDependency
---@param source_buf integer
---@return nil
local function setup_source_buffer_keymaps(dep, source_buf)
  resources.keymap_buf = source_buf
  resources.saved_keymaps = {}

  for _, key in ipairs({ "<CR>", "gT" }) do
    local keymap = get_buffer_keymap(key, source_buf)
    if keymap then
      resources.saved_keymaps[key] = keymap
    end
    pcall(vim.keymap.del, "n", key, { buffer = source_buf })
  end

  local function create_handler(command_fn, opts)
    opts = opts or {}
    return function()
      if not resources.win_id or not vim.api.nvim_win_is_valid(resources.win_id) then
        M.close_hover()
        return
      end

      if not opts.keep_hover then
        M.close_hover()
      end
      command_fn()
    end
  end

  vim.keymap.set(
    "n",
    "<CR>",
    create_handler(function()
      require("pydeps.commands").provenance(dep.name)
    end, { keep_hover = true }),
    { buffer = source_buf, desc = "PyDeps: Show why this dependency is needed", nowait = true, silent = true }
  )

  vim.keymap.set(
    "n",
    "gT",
    create_handler(function()
      require("pydeps.commands").tree("", false, { mode = "float", anchor = "cursor" })
    end),
    { buffer = source_buf, desc = "PyDeps: Show dependency tree", nowait = true, silent = true }
  )
end

---@return nil
local function setup_hover_buffer_keymaps()
  if not resources.buf_id or not vim.api.nvim_buf_is_valid(resources.buf_id) then
    return
  end

  vim.keymap.set("n", "q", M.close_hover, { buffer = resources.buf_id, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", M.close_hover, { buffer = resources.buf_id, nowait = true, silent = true })

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = resources.buf_id,
    once = true,
    callback = M.close_hover,
  })
end

---@param dep PyDepsDependency
---@param resolved? string
---@param opts PyDepsRenderOptions
---@param source_buf integer
---@param window_opts? PyDepsInfoHoverWindowOptions
---@return nil
local function render_hover(dep, resolved, opts, source_buf, window_opts)
  M.close_hover()

  local generation = next_generation()
  local view = dependency_view.build(dep, {
    root = opts.root,
    resolved_version = resolved,
    lockfile_missing = opts.lockfile_missing,
  })
  local lines = render_lines.build_lines(view, opts)
  local status = render_lines.determine_status(view)

  resources.buf_id = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(resources.buf_id, 0, -1, false, lines)
  vim.bo[resources.buf_id].bufhidden = "wipe"
  vim.bo[resources.buf_id].modifiable = false

  local buf_id = resources.buf_id
  local width, height = hover_window_size(lines)
  resources.win_id = vim.api.nvim_open_win(resources.buf_id, false, hover_win_config(width, height, window_opts))

  local win_id = resources.win_id
  vim.api.nvim_set_option_value("wrap", false, { win = resources.win_id })

  setup_source_buffer_keymaps(dep, source_buf)
  setup_hover_buffer_keymaps()
  highlight.apply(buf_id, dep, lines, status)

  pypi.get(dep.name, function(meta)
    if generation ~= info_generation then
      return
    end
    if resources.buf_id ~= buf_id or not vim.api.nvim_buf_is_valid(buf_id) then
      return
    end

    local updated_view = dependency_view.build(dep, {
      root = opts.root,
      resolved_version = resolved,
      lockfile_missing = opts.lockfile_missing,
      meta = meta,
    })
    local updated_lines = render_lines.build_lines(updated_view, opts)
    local updated_status = render_lines.determine_status(updated_view)
    local new_width, new_height = hover_window_size(updated_lines)

    vim.bo[buf_id].modifiable = true
    vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, updated_lines)
    vim.bo[buf_id].modifiable = false
    highlight.apply(buf_id, dep, updated_lines, updated_status)

    if resources.win_id == win_id and vim.api.nvim_win_is_valid(win_id) then
      vim.api.nvim_win_set_config(win_id, hover_win_config(new_width, new_height, window_opts))
    end
  end)
end

---@return PyDepsDependency?, string?, PyDepsRenderOptions?, integer?
local function cursor_hover_context()
  local bufnr = buffer_context.current_buf()
  if not buffer_context.is_pyproject_buf(bufnr) then
    return nil, nil, nil, bufnr
  end

  local deps = buffer_context.get_deps(bufnr)
  local dep = buffer_context.dep_under_cursor(deps)
  if not dep then
    return nil, nil, nil, bufnr
  end

  local root = buffer_context.find_root(bufnr)
  local resolved = {}
  local missing_lockfile = false
  if root then
    local lock_data, missing = cache.get_lockfile(root)
    resolved = lock_data.resolved or {}
    missing_lockfile = missing
  end

  return dep, resolved[dep.name], {
    lockfile_missing = missing_lockfile,
    root = root,
  }, bufnr
end

---@param dep? PyDepsDependency
---@param resolved? string
---@param opts? PyDepsRenderOptions
---@return nil
function M.show(dep, resolved, opts)
  if not dep then
    vim.notify("pydeps: dependency not found under cursor", vim.log.levels.WARN)
    return
  end

  render_hover(dep, resolved, opts or {}, vim.api.nvim_get_current_buf())
end

---@return nil
function M.close_hover()
  cleanup_all_resources()
end

---@return integer?
function M.get_hover_win()
  if resources.win_id and vim.api.nvim_win_is_valid(resources.win_id) then
    return resources.win_id
  end
  return nil
end

---@return nil
function M.suspend_close()
  suppress_hover_close = true
end

---@return nil
function M.resume_close()
  suppress_hover_close = false
end

---@return boolean
function M.should_close_hover()
  return not suppress_hover_close
end

---@return nil
function M.show_at_cursor()
  local dep, resolved, opts, source_buf = cursor_hover_context()
  if not dep then
    M.close_hover()
    return
  end

  render_hover(dep, resolved, opts or {}, source_buf or vim.api.nvim_get_current_buf(), {
    zindex = 50,
  })
end

return M
