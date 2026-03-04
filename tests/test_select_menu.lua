local MiniTest = require("mini.test")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["pydeps.ui.select_menu"] = nil
    end,
  },
})

---@param fn fun()
---@return boolean, string?, string[]
local function run_with_notify(fn)
  local messages = {}
  local original_notify = vim.notify
  vim.notify = function(msg, _level)
    table.insert(messages, msg)
  end

  local ok, err = pcall(fn)
  vim.notify = original_notify
  return ok, err, messages
end

T["show warns when items are missing"] = function()
  local select_menu = require("pydeps.ui.select_menu")

  local ok, err, messages = run_with_notify(function()
    select_menu.show({
      prompt = "select package",
      items = {},
      on_select = function() end,
    })
  end)

  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(#messages, 1)
  MiniTest.expect.equality(messages[1]:match("requires at least one item") ~= nil, true)
end

T["show warns when items exceed supported count"] = function()
  local select_menu = require("pydeps.ui.select_menu")
  local items = {}
  for i = 1, 10 do
    table.insert(items, { label = "item" .. i, value = i })
  end

  local ok, err, messages = run_with_notify(function()
    select_menu.show({
      prompt = "select package",
      items = items,
      on_select = function() end,
    })
  end)

  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(#messages, 1)
  MiniTest.expect.equality(messages[1]:match("supports up to 9 items") ~= nil, true)
end

return T
