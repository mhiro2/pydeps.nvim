---@class PyDepsRateLimiter
---@field max integer
---@field active integer
---@field queue fun(done: fun())[]
local M = {}

---@param max integer
---@return PyDepsRateLimiter
function M.new(max)
  local limiter = {
    max = max or 5,
    active = 0,
    queue = {},
  }

  ---@param fn fun(done: fun())
  function limiter:enqueue(fn)
    table.insert(self.queue, fn)
    self:_process()
  end

  function limiter:_process()
    if self.active >= self.max then
      return
    end
    local fn = table.remove(self.queue, 1)
    if fn then
      self.active = self.active + 1
      fn(function()
        self.active = math.max(self.active - 1, 0)
        self:_process()
      end)
    end
  end

  return limiter
end

return M
