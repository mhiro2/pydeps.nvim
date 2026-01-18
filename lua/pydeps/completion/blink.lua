local completion = require("pydeps.completion.core")
local config = require("pydeps.config")

---@class PyDepsBlinkSource
local source = {}
source.__index = source

---@return PyDepsBlinkSource
function source.new()
  return setmetatable({}, source)
end

---@return boolean
function source:enabled()
  return config.options.enable_completion
end

---@param ctx table
---@return integer, integer
local function resolve_cursor(ctx)
  local cursor = ctx and (ctx.cursor or ctx.pos or ctx.position) or nil
  if type(cursor) == "table" then
    local line = cursor[1] or cursor.line or cursor.row or cursor.lnum
    local col = cursor[2] or cursor.col or cursor.character or cursor.colnr
    if type(line) == "number" and line == 0 then
      line = line + 1
    end
    if type(line) == "number" and type(col) == "number" then
      return line, col
    end
  end
  local win_cursor = vim.api.nvim_win_get_cursor(0)
  return win_cursor[1], win_cursor[2]
end

---@param ctx table
---@param callback fun(result: table)
function source:get_completions(ctx, callback)
  local bufnr = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
  local line, col = resolve_cursor(ctx or {})
  completion.complete(bufnr, { line, col }, function(res)
    callback({
      items = res.items or {},
      is_incomplete_forward = res.isIncomplete or false,
      is_incomplete_backward = res.isIncomplete or false,
    })
  end)
end

return source
