local config = require("pydeps.config")

local M = {}

---@class PyDepsSelectOption
---@field label string
---@field value any

---@class PyDepsSelectOpts
---@field prompt string
---@field items PyDepsSelectOption[]
---@field on_select fun(choice: any|nil)

---@param lines string[]
---@return integer
local function max_width(lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return width
end

---Format menu lines with proper spacing
---@param prompt string
---@param items PyDepsSelectOption[]
---@return string[]
local function format_menu_lines(prompt, items)
  local lines = {
    "pydeps: " .. prompt,
    "",
  }

  for i, item in ipairs(items) do
    table.insert(lines, string.format("%d: %s", i, item.label))
  end

  table.insert(lines, "")
  table.insert(lines, string.format("Type number (1-%d) or q to cancel", #items))

  return lines
end

---Handle single keypress input
---@param winid integer
---@param items PyDepsSelectOption[]
---@param callback fun(choice: any|nil)
---@return nil
local function handle_input(winid, items, callback)
  vim.defer_fn(function()
    if not vim.api.nvim_win_is_valid(winid) then
      callback(nil)
      return
    end

    local char = vim.fn.getchar()
    local nr

    -- Convert char code to number
    if type(char) == "number" then
      if char == 27 or char == 113 then -- ESC or 'q'
        if vim.api.nvim_win_is_valid(winid) then
          vim.api.nvim_win_close(winid, true)
        end
        callback(nil)
        return
      end
      if char >= 49 and char <= 57 then -- '1' to '9'
        nr = char - 48
      end
    elseif type(char) == "string" then
      if char == "q" or char == "\27" then
        if vim.api.nvim_win_is_valid(winid) then
          vim.api.nvim_win_close(winid, true)
        end
        callback(nil)
        return
      end
      nr = tonumber(char)
    end

    -- Close window
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end

    -- Execute callback
    if nr and nr >= 1 and nr <= #items then
      callback(items[nr])
    else
      callback(nil)
    end
  end, 0)
end

---Show a floating menu with single-keypress selection
---@param opts PyDepsSelectOpts
---@return nil
function M.show(opts)
  if not opts or not opts.items or #opts.items == 0 then
    error("select_menu: no items provided")
  end
  if #opts.items > 9 then
    error("select_menu: max 9 items supported")
  end

  local lines = format_menu_lines(opts.prompt, opts.items)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  local width = max_width(lines) + 4
  local height = #lines

  local win = vim.api.nvim_open_win(buf, true, {
    relative = config.options.select_menu_relative or "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = config.options.select_menu_border or "rounded",
  })

  vim.api.nvim_win_set_option(win, "wrap", false)

  handle_input(win, opts.items, opts.on_select)
end

return M
