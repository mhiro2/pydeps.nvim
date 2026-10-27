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

T["show draws the menu before waiting for a key"] = function()
  local original_cmd = vim.cmd
  local redrawn = false
  vim.cmd = function(command)
    redrawn = redrawn or command == "redraw"
    return original_cmd(command)
  end
  local drawn_before_key
  local ok, called = pcall(show_with_getchar, function()
    drawn_before_key = redrawn
    return 113 -- 'q'
  end)
  vim.cmd = original_cmd

  MiniTest.expect.equality({ ok, called }, { true, true })
  MiniTest.expect.equality(drawn_before_key, true)
end

T["show renders the header and item details around the choices"] = function()
  local select_menu = require("pydeps.ui.select_menu")
  local original_getchar = vim.fn.getchar
  local lines
  vim.fn.getchar = function()
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    return 113 -- 'q'
  end

  local called = false
  select_menu.show({
    prompt = "update requests",
    header = { "locked    2.31.0" },
    items = {
      { label = "2.31.0 -> 2.32.3", details = { "~ requests 2.31.0 -> 2.32.3" }, value = 1 },
      { label = "2.31.0 -> 3.0.0", value = 2 },
    },
    on_select = function()
      called = true
    end,
  })
  vim.wait(500, function()
    return called
  end, 10)
  vim.fn.getchar = original_getchar

  MiniTest.expect.equality(lines, {
    "pydeps: update requests",
    "",
    "  locked    2.31.0",
    "",
    "1: 2.31.0 -> 2.32.3",
    "     ~ requests 2.31.0 -> 2.32.3",
    "2: 2.31.0 -> 3.0.0",
    "",
    "Type number (1-2) or q to cancel",
  })
end

return T
