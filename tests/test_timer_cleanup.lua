local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.new_set({
  hooks = {
    pre_case = function()
      helpers.close_extra_windows()
      vim.cmd("enew!")
    end,
  },
})

---Record every uv timer created until the case finishes.
---@return uv_timer_t[]
local function spy_timers()
  local created = {}
  local new_timer = vim.uv.new_timer
  helpers.stub(vim.uv, "new_timer", function()
    local timer = new_timer()
    table.insert(created, timer)
    return timer
  end)
  return created
end

---@param lines string[]
---@return integer bufnr
local function open_pyproject(lines)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/pyproject.toml"
  vim.fn.writefile(lines, path)
  helpers.defer(function()
    vim.fn.delete(dir, "rf")
  end)
  local bufnr = vim.fn.bufadd(path)
  -- Load without BufReadPost so only the events a case fires schedule work.
  local eventignore = vim.o.eventignore
  vim.o.eventignore = "all"
  vim.fn.bufload(bufnr)
  vim.o.eventignore = eventignore
  return bufnr
end

---Enable auto refresh and count the refreshes that actually run.
---@param debounce_ms integer
---@return { count: integer }
local function setup_counting_refresh(debounce_ms)
  require("pydeps").setup({ auto_refresh = true, refresh_debounce_ms = debounce_ms })
  local state = require("pydeps.core.state")
  local refreshes = { count = 0 }
  helpers.stub(state, "refresh", function()
    refreshes.count = refreshes.count + 1
  end)
  helpers.defer(state.disable)
  return refreshes
end

local PYPROJECT = { "[project]", "dependencies = [", '  "requests",', "]" }

T["state: wiping a buffer closes its pending refresh timer"] = function()
  local refreshes = setup_counting_refresh(100)
  local bufnr = open_pyproject(PYPROJECT)
  local timers = spy_timers()

  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
  MiniTest.expect.equality(#timers, 1)
  MiniTest.expect.equality(timers[1]:is_active(), true)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  MiniTest.expect.equality(timers[1]:is_closing(), true)

  helpers.drain(200)
  MiniTest.expect.equality(refreshes.count, 0)
end

T["state: pending refresh runs when the buffer is kept"] = function()
  local refreshes = setup_counting_refresh(20)
  local bufnr = open_pyproject(PYPROJECT)

  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
  helpers.wait_for(function()
    return refreshes.count == 1
  end, "debounced refresh")
end

T["state: disable closes refresh timers of every buffer"] = function()
  local refreshes = setup_counting_refresh(100)
  local first = open_pyproject(PYPROJECT)
  local second = open_pyproject(PYPROJECT)
  local timers = spy_timers()

  vim.api.nvim_exec_autocmds("TextChanged", { buffer = first })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = second })
  MiniTest.expect.equality(#timers, 2)

  require("pydeps.core.state").disable()
  MiniTest.expect.equality(timers[1]:is_closing(), true)
  MiniTest.expect.equality(timers[2]:is_closing(), true)

  helpers.drain(200)
  MiniTest.expect.equality(refreshes.count, 0)
end

T["virtual_text: clear_debounce_state cancels the post-fetch render"] = function()
  require("pydeps").setup({ auto_refresh = false })
  local virtual_text = require("pydeps.ui.virtual_text")
  local pypi = require("pydeps.providers.pypi")
  local buffer_context = require("pydeps.core.buffer_context")

  helpers.stub(require("pydeps.core.env"), "get", function()
    return {}
  end)
  local held = {}
  helpers.stub(pypi, "get_cached", function()
    return nil, false
  end)
  helpers.stub(pypi, "get", function(name, cb)
    held[name] = cb
  end)

  local kept = open_pyproject({ "[project]", "dependencies = [", '  "kept-pkg",', "]" })
  local cleared = open_pyproject({ "[project]", "dependencies = [", '  "cleared-pkg",', "]" })
  virtual_text.render(kept, buffer_context.get_deps(kept), {}, {})
  virtual_text.render(cleared, buffer_context.get_deps(cleared), {}, {})
  MiniTest.expect.equality(held["kept-pkg"] ~= nil and held["cleared-pkg"] ~= nil, true)

  local renders = {}
  local render = virtual_text.render
  helpers.stub(virtual_text, "render", function(bufnr, ...)
    renders[bufnr] = (renders[bufnr] or 0) + 1
    return render(bufnr, ...)
  end)

  held["kept-pkg"]({ releases = {} })
  held["cleared-pkg"]({ releases = {} })
  virtual_text.clear_debounce_state(cleared)

  helpers.wait_for(function()
    return renders[kept] == 1
  end, "post-fetch render of the kept buffer")
  helpers.drain(100)
  MiniTest.expect.equality(renders[cleared], nil)
end

T["pypi: request timeout stops the job and closes its timer"] = function()
  package.loaded["pydeps.providers.pypi"] = nil
  package.loaded["pydeps.providers.pypi.metadata"] = nil
  helpers.defer(function()
    package.loaded["pydeps.providers.pypi"] = nil
    package.loaded["pydeps.providers.pypi.metadata"] = nil
  end)

  local shared = require("pydeps.providers.pypi.shared")
  helpers.stub(shared, "REQUEST_TIMEOUT", 50)

  local job_opts
  local stopped = {}
  helpers.stub(vim.fn, "executable", function(cmd)
    return cmd == "curl" and 1 or 0
  end)
  helpers.stub(vim.fn, "jobstart", function(_, opts)
    job_opts = opts
    return 42
  end)
  helpers.stub(vim.fn, "jobstop", function(id)
    table.insert(stopped, id)
    return 1
  end)
  local timers = spy_timers()

  local calls = {}
  require("pydeps.providers.pypi").get("hanging-package", function(data)
    table.insert(calls, { data = data })
  end)
  MiniTest.expect.equality(#timers, 1)

  helpers.wait_for(function()
    return #calls == 1 and #stopped == 1
  end, "timeout callback and jobstop")
  MiniTest.expect.equality(calls[1].data, nil)
  MiniTest.expect.equality(stopped, { 42 })
  MiniTest.expect.equality(timers[1]:is_closing(), true)

  -- The stopped job still exits later; its output must neither reach callers
  -- again nor replace the timed-out result in the cache.
  local pypi = require("pydeps.providers.pypi")
  job_opts.on_stdout(42, { '{"info": {"version": "1.0.0"}, "releases": {}}' })
  job_opts.on_exit(42, 0, "exit")
  helpers.drain(50)
  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(pypi.get_cached("hanging-package"), nil)
end

return T
