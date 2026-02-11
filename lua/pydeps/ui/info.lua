local cache = require("pydeps.core.cache")
local config = require("pydeps.config")
local env = require("pydeps.core.env")
local project = require("pydeps.core.project")
local pypi = require("pydeps.providers.pypi")
local ui_shared = require("pydeps.ui.shared")
local util = require("pydeps.util")

local M = {}

---@class PyDepsInfoResources
---@field win_id integer?
---@field buf_id integer?
---@field keymap_buf integer?
---@field saved_keymaps table<string, any>?

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

local info_ns = vim.api.nvim_create_namespace("pydeps-info")

---Clean up all resources (window, buffer, keymaps)
---@return nil
local function cleanup_all_resources()
  -- Window cleanup
  if resources.win_id and vim.api.nvim_win_is_valid(resources.win_id) then
    pcall(vim.api.nvim_win_close, resources.win_id, true)
  end
  resources.win_id = nil
  resources.buf_id = nil

  -- Keymap cleanup
  if resources.keymap_buf and vim.api.nvim_buf_is_valid(resources.keymap_buf) then
    pcall(vim.keymap.del, "n", "<CR>", { buffer = resources.keymap_buf })
    pcall(vim.keymap.del, "n", "gT", { buffer = resources.keymap_buf })

    -- Restore saved keymaps using vim.keymap.set with the saved options
    if resources.saved_keymaps then
      for key, saved in pairs(resources.saved_keymaps) do
        local opts = {
          buffer = resources.keymap_buf,
        }
        if saved.expr ~= nil then
          opts.expr = saved.expr
        end
        if saved.noremap ~= nil then
          opts.noremap = saved.noremap
        end
        if saved.nowait ~= nil then
          opts.nowait = saved.nowait
        end
        if saved.silent ~= nil then
          opts.silent = saved.silent
        end
        if saved.script ~= nil then
          opts.script = saved.script
        end
        if saved.desc ~= nil then
          opts.desc = saved.desc
        end
        if saved.callback ~= nil then
          opts.callback = saved.callback
        end
        pcall(vim.keymap.set, "n", key, saved.rhs, opts)
      end
      resources.saved_keymaps = nil
    end
    resources.keymap_buf = nil
  end
end

---@param kind string
---@return string
local icon_for

local info_labels = {
  deps = true,
  extras = true,
  latest = true,
  lock = true,
  markers = true,
  pypi = true,
  spec = true,
  status = true,
}

---@param kind string
---@return string
local function format_status_text(kind)
  if kind == "ok" then
    return "active"
  elseif kind == "update" then
    return "update available"
  elseif kind == "warn" then
    return "lock mismatch"
  elseif kind == "error" then
    return "yanked"
  elseif kind == "inactive" then
    return "inactive"
  else
    return "unknown"
  end
end

---Get highlight group for status kind
---@param kind string
---@return string
local function status_highlight_group(kind)
  if kind == "ok" then
    return "PyDepsInfoStatusOk"
  elseif kind == "update" then
    return "PyDepsInfoStatusUpdate"
  elseif kind == "warn" then
    return "PyDepsInfoStatusWarn"
  elseif kind == "error" then
    return "PyDepsInfoStatusError"
  elseif kind == "inactive" then
    return "PyDepsInfoStatusInactive"
  else
    return "PyDepsInfoStatusInactive"
  end
end

---@param buf integer
---@param dep PyDepsDependency
---@param lines string[]
---@param status PyDepsStatusResult
---@return nil
local function apply_info_highlights(buf, dep, lines, status)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, info_ns, 0, -1)

  ---@param line string
  ---@return string?
  local function find_label(line)
    for label_name, _ in pairs(info_labels) do
      if line:match("^%s*%S+%s+" .. label_name .. "%s") or line:match("^%s*" .. label_name .. "%s") then
        return label_name
      end
    end
    return nil
  end

  -- Title (package name) - highlight with icon included
  if lines[1] and dep and dep.name then
    local package_icon = icon_for("package")
    local icon_offset = #package_icon + (#package_icon > 0 and 1 or 0)
    vim.api.nvim_buf_add_highlight(buf, info_ns, "PyDepsInfoPackage", 0, 0, icon_offset + #dep.name)
  end

  -- Highlight content
  local description_marked = false
  for idx, line in ipairs(lines) do
    -- Description is the first non-empty non-label line after header
    if not description_marked and idx > 1 and line ~= "" and not find_label(line) then
      vim.api.nvim_buf_add_highlight(buf, info_ns, "PyDepsInfoDescription", idx - 1, 0, -1)
      description_marked = true
    end

    -- Labels (spec, lock, latest, extras, markers, status, deps, pypi)
    -- Match lines that contain label names followed by space and value
    local label = find_label(line)

    if label and info_labels[label] then
      local start_col = line:find(label, 1, true)
      if start_col then
        vim.api.nvim_buf_add_highlight(buf, info_ns, "PyDepsInfoLabel", idx - 1, 0, start_col - 1 + #label)
      end

      -- Extras value highlighting (pill style)
      if label == "extras" then
        local value_start = line:find("%S", (start_col or 1) + #label)
        if value_start then
          vim.api.nvim_buf_add_highlight(buf, info_ns, "PyDepsInfoPill", idx - 1, value_start - 1, -1)
        end
      end

      -- Status value highlighting (color by status type)
      if label == "status" then
        local status_hl = status_highlight_group(status.kind)
        local status_text = format_status_text(status.kind)
        local value_start = line:find(status_text, 1, true)
        if value_start then
          vim.api.nvim_buf_add_highlight(
            buf,
            info_ns,
            status_hl,
            idx - 1,
            value_start - 1,
            value_start - 1 + #status_text
          )
        end
      end

      -- PyPI URL highlighting
      if label == "pypi" and line:match("https?://") then
        local url_start = line:find("https?://")
        if url_start then
          vim.api.nvim_buf_add_highlight(buf, info_ns, "PyDepsInfoUrl", idx - 1, url_start - 1, -1)
        end
      end
    end

    -- Suffix highlighting (comments in parentheses)
    local suffix = line:match("%((.+)%)%s*$")
    if suffix then
      local suffix_start = line:find("%(" .. vim.pesc(suffix) .. "%)%s*$")
      if suffix_start then
        local suffix_hl = "PyDepsInfoSuffixInfo" -- default

        if suffix == "up-to-date" then
          suffix_hl = "PyDepsInfoSuffixOk"
        elseif suffix == "update available" then
          suffix_hl = "PyDepsInfoSuffixWarn"
        elseif suffix == "loading..." then
          suffix_hl = "PyDepsInfoSuffixInfo"
        elseif suffix == "not found" or suffix == "missing" then
          suffix_hl = "PyDepsInfoSuffixError"
        end

        vim.api.nvim_buf_add_highlight(buf, info_ns, suffix_hl, idx - 1, suffix_start - 1, -1)
      end
    end
  end
end

---@class PyDepsRenderOptions
---@field lockfile_missing boolean
---@field root? string

---@class PyDepsStatusResult
---@field kind "ok"|"update"|"warn"|"error"|"inactive"|"unknown"
---@field icon string
---@field lock_status? string
---@field show_latest_warning boolean

---@param lines string[]
---@return integer
local function max_width(lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return width
end

---Clamp window dimensions to screen size
---@param width integer
---@param height integer
---@return integer, integer
local function clamp_window_size(width, height)
  local max_win_width = vim.o.columns - 4
  local max_win_height = vim.o.lines - 4
  return math.min(width, max_win_width), math.min(height, max_win_height)
end

icon_for = ui_shared.icon_for
local extract_marker = ui_shared.extract_marker

-- Column alignment constants
-- Max label width: with icon = ~9 chars (e.g., " spec")
local COL_LABEL_WIDTH = 12

---@param icon string
---@param label string
---@param value string
---@param suffix? string
---@return string
local function format_line(icon, label, value, suffix)
  -- Build label text (with or without icon)
  local label_text
  if icon ~= "" then
    label_text = icon .. " " .. label
  else
    label_text = label
  end

  -- Left-align label, then pad to align values
  local label_width = vim.fn.strdisplaywidth(label_text)
  local padding = string.rep(" ", COL_LABEL_WIDTH - label_width)
  local formatted = label_text .. padding .. value

  if suffix then
    formatted = formatted .. string.rep(" ", 4) .. suffix
  end
  return formatted
end

---@return integer
local function next_generation()
  info_generation = info_generation + 1
  return info_generation
end

---@param dep PyDepsDependency
---@return string?
local function format_extras(dep)
  local extras_icon = icon_for("extras")
  local extras = {}
  if dep.group and dep.group ~= "" and dep.group ~= "project" then
    if dep.group:match("^optional:") then
      table.insert(extras, dep.group:sub(#"optional:" + 1))
    elseif dep.group:match("^group:") then
      table.insert(extras, dep.group:sub(#"group:" + 1))
    else
      table.insert(extras, dep.group)
    end
  end

  local spec_extras = util.parse_requirement_extras(dep.spec)
  for _, extra in ipairs(spec_extras) do
    table.insert(extras, extra)
  end

  if #extras == 0 then
    return nil
  end

  local unique = {}
  local seen = {}
  for _, extra in ipairs(extras) do
    if not seen[extra] then
      seen[extra] = true
      table.insert(unique, extra)
    end
  end

  return format_line(extras_icon, "extras", table.concat(unique, ", "))
end

---@param lock_data PyDepsLockfileData
---@param dep_name string
---@return integer|string
local function get_deps_count(lock_data, dep_name)
  if not lock_data or not lock_data.packages then
    return "?"
  end
  local pkg = lock_data.packages[dep_name]
  if not pkg or not pkg.dependencies then
    return 0
  end
  return #pkg.dependencies
end

---@param dep PyDepsDependency
---@param resolved? string
---@param meta? PyDepsPyPIMeta
---@param root? string
---@return PyDepsStatusResult
local function determine_status(dep, resolved, meta, root)
  local markers = require("pydeps.core.markers")
  local marker_env = vim.tbl_deep_extend("force", {}, env.get(root))

  -- Add extra/group to env for marker evaluation
  if dep.group then
    if dep.group:match("^optional:") then
      marker_env.extra = dep.group:sub(#"optional:" + 1)
    elseif dep.group:match("^group:") then
      marker_env.group = dep.group:sub(#"group:" + 1)
    end
  end

  -- Check inactive (markers)
  local marker = extract_marker(dep.spec)
  if marker and marker_env and marker_env.python_version then
    local is_active = markers.evaluate(marker, marker_env)
    if not is_active then
      return {
        kind = "inactive",
        icon = icon_for("inactive"),
        lock_status = nil,
        show_latest_warning = false,
      }
    end
  end

  -- Check yanked
  if resolved and meta and pypi.is_yanked(meta, resolved) then
    return {
      kind = "error",
      icon = icon_for("yanked"),
      lock_status = "(yanked)",
      show_latest_warning = false,
    }
  end

  -- Check lock mismatch (pinned spec != resolved)
  local pinned_version = dep.spec and dep.spec:match("===%s*([^,%s]+)") or dep.spec:match("==%s*([^,%s]+)")
  local is_pinned = pinned_version ~= nil
  if is_pinned and resolved then
    if pinned_version and pinned_version ~= resolved then
      return {
        kind = "warn",
        icon = icon_for("lock_mismatch"),
        lock_status = "(lock mismatch)",
        show_latest_warning = false,
      }
    end
  end

  -- Check update available
  local latest_version = meta and meta.info and meta.info.version
  if resolved and latest_version and resolved ~= latest_version then
    return {
      kind = "update",
      icon = icon_for("update"),
      lock_status = nil,
      show_latest_warning = true,
    }
  end

  -- Package not found on PyPI (meta is nil)
  if not meta then
    return {
      kind = "unknown",
      icon = icon_for("unknown"),
      lock_status = nil,
      show_latest_warning = false,
    }
  end

  -- OK
  return {
    kind = "ok",
    icon = icon_for("ok"),
    lock_status = resolved and "(up-to-date)" or nil,
    show_latest_warning = false,
  }
end

---@param dep PyDepsDependency
---@param resolved? string
---@param opts? PyDepsRenderOptions
---@param meta? PyDepsPyPIMeta
---@return string[]
local function build_lines(dep, resolved, opts, meta)
  local lines = {}
  local root = opts and opts.root

  -- Get lock data for deps count
  local lock_data = {}
  if root then
    lock_data, _ = cache.get_lockfile(root)
  end

  -- Determine status
  local status = determine_status(dep, resolved, meta, root)

  -- Icons
  local package_icon = icon_for("package")
  local spec_icon = icon_for("spec")
  local lock_icon = icon_for("lock")
  local latest_icon = icon_for("latest")
  local markers_icon = icon_for("markers")
  local status_icon = icon_for("status")
  local deps_icon = icon_for("deps")
  local pypi_icon = icon_for("pypi")

  local description = meta and meta.info and meta.info.summary
  -- Header: package name only (no status icon)
  table.insert(lines, package_icon .. " " .. dep.name)

  -- Description (conditional)
  if description and description ~= "" then
    table.insert(lines, "")
    table.insert(lines, description)
    table.insert(lines, "")
  end

  -- Version section
  -- spec line (always present)
  table.insert(lines, format_line(spec_icon, "spec", dep.spec or "(unknown)"))

  -- lock line
  if resolved then
    local lock_suffix = status.lock_status or ""
    table.insert(lines, format_line(lock_icon, "lock", resolved, lock_suffix))
  elseif opts and opts.lockfile_missing then
    table.insert(lines, format_line(lock_icon, "lock", "(missing)"))
  else
    table.insert(lines, format_line(lock_icon, "lock", "(not found)"))
  end

  -- latest line
  local latest_version = nil
  if meta and meta.info and meta.info.version then
    latest_version = meta.info.version
  elseif meta then
    latest_version = "(not found)"
  else
    latest_version = "(loading...)"
  end

  local latest_suffix = nil
  if status.show_latest_warning then
    latest_suffix = "(update available)"
  end
  table.insert(lines, format_line(latest_icon, "latest", latest_version, latest_suffix))

  -- Environment section (extras, markers, status)
  local extras_line = format_extras(dep)
  local marker = extract_marker(dep.spec)
  local has_env = extras_line or marker

  if has_env then
    if extras_line then
      table.insert(lines, extras_line)
    end

    if marker then
      table.insert(lines, format_line(markers_icon, "markers", marker))
    end
  end

  -- status line (always shown)
  local status_text = format_status_text(status.kind)
  local status_suffix = ""
  if status.kind == "inactive" then
    local runtime_env = env.get(root)
    local python_ver = runtime_env.python_full_version or runtime_env.python_version or "unknown"
    status_suffix = "(python " .. python_ver .. ")"
  end
  table.insert(lines, format_line(status_icon, "status", status_text, status_suffix))

  -- deps count line with shortcuts
  local deps_count = get_deps_count(lock_data, dep.name)
  table.insert(lines, format_line(deps_icon, "deps", tostring(deps_count), "(Enter: Why, gT: Tree)"))

  -- pypi URL
  local pypi_url = config.options.pypi_url .. "/" .. dep.name
  if meta and meta.info and meta.info.version then
    table.insert(lines, format_line(pypi_icon, "pypi", pypi_url))
  else
    table.insert(lines, format_line(pypi_icon, "pypi", "not found on public PyPI"))
  end

  return lines
end

---Set up keybindings on the hover buffer itself
---@return nil
local function setup_hover_buffer_keymaps()
  if not resources.buf_id or not vim.api.nvim_buf_is_valid(resources.buf_id) then
    return
  end

  -- Close keymaps on hover buffer (in case focus moves there)
  vim.keymap.set("n", "q", M.close_hover, { buffer = resources.buf_id, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", M.close_hover, { buffer = resources.buf_id, nowait = true, silent = true })

  -- Close when leaving the hover window
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = resources.buf_id,
    once = true,
    callback = M.close_hover,
  })
end

---Set up keybindings for the source buffer while the hover is open
---@param dep PyDepsDependency
---@param source_buf integer
---@return nil
local function setup_hover_keybindings(dep, source_buf)
  resources.keymap_buf = source_buf
  resources.saved_keymaps = {}

  -- Save existing keybindings before overriding
  local keys_to_save = { "<CR>", "gT" }
  for _, key in ipairs(keys_to_save) do
    local ok, keymap = pcall(vim.keymap.get, "n", key, { buffer = source_buf })
    if ok and keymap then
      resources.saved_keymaps[key] = keymap
    end
  end

  -- Clear any existing keybindings
  pcall(vim.keymap.del, "n", "<CR>", { buffer = source_buf })
  pcall(vim.keymap.del, "n", "gT", { buffer = source_buf })

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

  -- Enter keybinding for :PyDepsWhy
  vim.keymap.set(
    "n",
    "<CR>",
    create_handler(function()
      require("pydeps.commands").provenance(dep.name)
    end, { keep_hover = true }),
    { buffer = source_buf, desc = "PyDeps: Show why this dependency is needed", nowait = true, silent = true }
  )

  -- gT keybinding for :PyDepsTree
  vim.keymap.set(
    "n",
    "gT",
    create_handler(function()
      require("pydeps.commands").tree("", false, { mode = "float", anchor = "cursor" })
    end),
    { buffer = source_buf, desc = "PyDeps: Show dependency tree", nowait = true, silent = true }
  )
end

---@class PyDepsInfoHoverWindowOptions
---@field zindex? integer

---@param lines string[]
---@return integer, integer
local function hover_window_size(lines)
  local width = max_width(lines) + 2
  local height = #lines
  return clamp_window_size(width, height)
end

---@param width integer
---@param height integer
---@param window_opts? PyDepsInfoHoverWindowOptions
---@return table
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

---@param dep PyDepsDependency
---@param resolved? string
---@param opts PyDepsRenderOptions
---@param source_buf integer
---@param window_opts? PyDepsInfoHoverWindowOptions
---@return nil
local function render_hover(dep, resolved, opts, source_buf, window_opts)
  M.close_hover()

  local generation = next_generation()
  local root = opts.root
  local lines = build_lines(dep, resolved, opts, nil)

  resources.buf_id = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(resources.buf_id, 0, -1, false, lines)
  vim.bo[resources.buf_id].bufhidden = "wipe"
  vim.bo[resources.buf_id].modifiable = false
  local buf_id = resources.buf_id

  local width, height = hover_window_size(lines)
  resources.win_id = vim.api.nvim_open_win(resources.buf_id, false, hover_win_config(width, height, window_opts))
  local win_id = resources.win_id
  vim.api.nvim_set_option_value("wrap", false, { win = resources.win_id })

  setup_hover_keybindings(dep, source_buf)
  setup_hover_buffer_keymaps()

  local status = determine_status(dep, resolved, nil, root)
  apply_info_highlights(resources.buf_id, dep, lines, status)

  pypi.get(dep.name, function(meta)
    if generation ~= info_generation then
      return
    end
    if resources.buf_id ~= buf_id or not vim.api.nvim_buf_is_valid(buf_id) then
      return
    end

    local updated = build_lines(dep, resolved, opts, meta)
    vim.bo[buf_id].modifiable = true
    vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, updated)
    vim.bo[buf_id].modifiable = false

    local updated_status = determine_status(dep, resolved, meta, root)
    apply_info_highlights(buf_id, dep, updated, updated_status)

    local new_width, new_height = hover_window_size(updated)
    if resources.win_id == win_id and vim.api.nvim_win_is_valid(win_id) then
      vim.api.nvim_win_set_config(win_id, hover_win_config(new_width, new_height, window_opts))
    end
  end)
end

---@param dep? PyDepsDependency
---@param resolved? string
---@param opts? PyDepsRenderOptions
function M.show(dep, resolved, opts)
  if not dep then
    vim.notify("pydeps: dependency not found under cursor", vim.log.levels.WARN)
    return
  end

  render_hover(dep, resolved, opts or {}, vim.api.nvim_get_current_buf())
end

---Close the hover window if it exists
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

---@return PyDepsDependency?, string?, PyDepsRenderOptions?, integer?
local function cursor_hover_context()
  local bufnr = vim.api.nvim_get_current_buf()

  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name:match("pyproject%.toml$") then
    return nil, nil, nil, bufnr
  end

  local deps = cache.get_pyproject(bufnr)
  local dep = util.dep_under_cursor(deps)
  if not dep then
    return nil, nil, nil, bufnr
  end

  local root = project.find_root(bufnr)
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

---Show hover info for dependency under cursor
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
