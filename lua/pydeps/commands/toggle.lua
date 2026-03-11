local state = require("pydeps.core.state")

local M = {}

---@return nil
function M.run()
  state.toggle()
end

return M
