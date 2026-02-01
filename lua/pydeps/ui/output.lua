local M = {}

---@param lines string[]
---@return integer
local function max_width(lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return width
end

---@param value integer
---@param min integer
---@param max integer
---@return integer
local function clamp(value, min, max)
  if value < min then
    return min
  end
  if value > max then
    return max
  end
  return value
end

---@param width integer
---@param height integer
---@return integer?, integer?, integer?, integer?
local function hover_position(width, height)
  local ok, info = pcall(require, "pydeps.ui.info")
  if not ok or not info.get_hover_win then
    return nil
  end
  local hover_win = info.get_hover_win()
  if not hover_win or not vim.api.nvim_win_is_valid(hover_win) then
    return nil
  end

  local hover_pos = vim.api.nvim_win_get_position(hover_win)
  local hover_cfg = vim.api.nvim_win_get_config(hover_win)
  local hover_width = hover_cfg.width or vim.api.nvim_win_get_width(hover_win)

  local row = hover_pos[1]
  local col = hover_pos[2] + hover_width + 1

  if col + width > vim.o.columns then
    col = hover_pos[2] - width - 1
  end
  if col < 0 then
    col = hover_pos[2]
  end

  if row + height > vim.o.lines - 1 then
    row = math.max(0, vim.o.lines - height - 1)
  end

  return row, col, width, height
end

---@param width integer
---@param height integer
---@param anchor string
---@return integer, integer, integer, integer
local function float_position(width, height, anchor)
  local max_w = math.max(1, vim.o.columns - 4)
  local max_h = math.max(1, vim.o.lines - 4)
  width = clamp(width, 20, max_w)
  height = clamp(height, 1, max_h)

  if anchor == "hover" then
    local row, col = hover_position(width, height)
    if row and col then
      return row, col, width, height
    end
    anchor = "cursor"
  end

  if anchor == "cursor" then
    local win_pos = vim.api.nvim_win_get_position(0)
    local cursor_row = win_pos[1] + vim.fn.winline() - 1
    local cursor_col = win_pos[2] + vim.fn.wincol() - 1

    local row = cursor_row + 1
    if row + height > vim.o.lines - 1 then
      row = cursor_row - height - 1
    end
    if row < 0 then
      row = 0
    end

    local col = cursor_col
    if col + width > vim.o.columns then
      col = vim.o.columns - width
    end
    if col < 0 then
      col = 0
    end

    return row, col, width, height
  end

  local row = math.max(0, math.floor((vim.o.lines - height) * 0.5 - 1))
  local col = math.max(0, math.floor((vim.o.columns - width) * 0.5))
  return row, col, width, height
end

---@param lines? string[]
---@return string[]
local function sanitize_lines(lines)
  if not lines then
    return {}
  end
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

---@param title string
---@param lines string[]
---@param opts? { mode?: "split"|"float", border?: string, width?: integer, height?: integer, anchor?: "center"|"cursor"|"hover", on_close?: fun(), on_show?: fun(buf: integer, lines: string[]), enter?: boolean, highlight?: fun(buf: integer, lines: string[]) }
function M.show(title, lines, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "pydeps"
  if opts.highlight then
    opts.highlight(buf, lines)
  end

  -- Call on_show callback after buffer is set up
  if opts.on_show then
    opts.on_show(buf, lines)
  end

  if opts.mode == "float" then
    local enter = opts.enter ~= false
    local row, col, width, height =
      float_position(opts.width or (max_width(lines) + 2), opts.height or #lines, opts.anchor or "center")

    local win = vim.api.nvim_open_win(buf, enter, {
      relative = "editor",
      row = row,
      col = col,
      width = width,
      height = height,
      style = "minimal",
      border = opts.border or "rounded",
    })
    vim.api.nvim_set_option_value("wrap", false, { win = win })

    -- Ensure focus is moved to the float window
    if enter then
      vim.api.nvim_set_current_win(win)
    end

    local closed = false
    local function close()
      if closed then
        return
      end
      closed = true
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if opts.on_close then
        opts.on_close()
      end
    end

    vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, silent = true })

    -- Close window when focus leaves
    vim.api.nvim_create_autocmd("WinLeave", {
      buffer = buf,
      once = true,
      callback = close,
    })

    -- Call on_close when buffer is wiped
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        if not closed and opts.on_close then
          closed = true
          opts.on_close()
        end
      end,
    })
  else
    local win = vim.api.nvim_open_win(buf, true, {
      split = "right",
      win = 0,
    })
    vim.api.nvim_set_option_value("wrap", false, { win = win })
  end
  vim.api.nvim_buf_set_name(buf, title)
end

---@class PyDepsOutputOptions
---@field cwd? string
---@field title? string
---@field on_show? fun(buf: integer, lines: string[])
---@field on_close? fun()
---@field mode? "split"|"float"
---@field anchor? "center"|"cursor"|"hover"
---@field width? integer
---@field height? integer
---@field width_calc? fun(lines: string[]):integer

---@param cmd string[]
---@param opts PyDepsOutputOptions
---@return nil
function M.run_command(cmd, opts)
  local stdout = {}
  local stderr = {}

  local job_id = vim.fn.jobstart(cmd, {
    cwd = opts.cwd,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        stdout = data
      end
    end,
    on_stderr = function(_, data)
      if data then
        stderr = data
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        local message = "pydeps: command failed"
        if #stderr > 0 then
          message = message .. "\n" .. table.concat(sanitize_lines(stderr), "\n")
        end
        vim.notify(message, vim.log.levels.ERROR)
        return
      end
      local lines = sanitize_lines(stdout)
      if #lines == 0 then
        lines = { "(no output)" }
      end
      local width = opts.width
      if width == nil and opts.width_calc then
        width = opts.width_calc(lines)
      end
      M.show(opts.title or table.concat(cmd, " "), lines, {
        on_show = opts.on_show,
        on_close = opts.on_close,
        anchor = opts.anchor,
        mode = opts.mode,
        width = width,
        height = opts.height,
      })
    end,
  })

  if job_id <= 0 then
    vim.notify("pydeps: failed to start command: " .. table.concat(cmd, " "), vim.log.levels.ERROR)
  end
end

return M
