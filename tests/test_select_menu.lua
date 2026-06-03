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

---Run select_menu.show with a stubbed getchar and wait for the callback.
---@param getchar fun():any
---@return boolean called, any choice, integer win_count_after
local function show_with_getchar(getchar)
  local select_menu = require("pydeps.ui.select_menu")

  local original_getchar = vim.fn.getchar
  vim.fn.getchar = getchar

  local called = false
  local choice = "unset"
  select_menu.show({
    prompt = "select package",
    items = {
      { label = "requests", value = "requests" },
      { label = "rich", value = "rich" },
    },
    on_select = function(selected)
      called = true
      choice = selected
    end,
  })

  vim.wait(500, function()
    return called
  end, 10)

  vim.fn.getchar = original_getchar
  return called, choice, #vim.api.nvim_list_wins()
end

T["show cancels when getchar is interrupted"] = function()
  local called, choice, win_count = show_with_getchar(function()
    error("Keyboard interrupt")
  end)

  MiniTest.expect.equality(called, true)
  MiniTest.expect.equality(choice, nil)
  -- The floating menu window must be closed on interrupt.
  MiniTest.expect.equality(win_count, 1)
end

T["show returns the selected item on numeric keypress"] = function()
  local called, choice, win_count = show_with_getchar(function()
    return 49 -- '1'
  end)

  MiniTest.expect.equality(called, true)
  MiniTest.expect.equality(choice ~= nil, true)
  MiniTest.expect.equality(choice.value, "requests")
  MiniTest.expect.equality(win_count, 1)
end

return T
