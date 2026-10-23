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
---@param callback fun(result: table)
function source:get_completions(ctx, callback)
  local bufnr = ctx and ctx.bufnr or vim.api.nvim_get_current_buf()
  -- blink.cmp passes a 1-indexed row and 0-indexed byte column, like nvim_win_get_cursor().
  local cursor = ctx and ctx.cursor or vim.api.nvim_win_get_cursor(0)
  completion.complete(bufnr, { cursor[1], cursor[2] }, function(res)
    callback({
      items = res.items or {},
      is_incomplete_forward = res.isIncomplete or false,
      is_incomplete_backward = res.isIncomplete or false,
    })
  end)
end

return source
