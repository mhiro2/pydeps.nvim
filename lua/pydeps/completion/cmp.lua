local completion = require("pydeps.completion.core")
local config = require("pydeps.config")

---@class PyDepsCmpSource
local source = {}
source.__index = source

---@return PyDepsCmpSource
function source.new()
  return setmetatable({}, source)
end

---@return boolean
function source:is_available()
  return config.options.enable_completion
end

---@return string
function source:get_keyword_pattern()
  return [[\k\+]]
end

---@param params table
---@param callback fun(result: table)
function source:complete(params, callback)
  local bufnr = params.context.bufnr
  local cursor = params.context.cursor
  completion.complete(bufnr, cursor, callback)
end

return source
