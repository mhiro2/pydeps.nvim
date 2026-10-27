local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local T = helpers.create_test_set()

---Write a project to disk and open its saved pyproject.toml.
---@param dependencies string[]
---@param packages? table<string, string>
---@return integer bufnr, string path
local function open_project(dependencies, packages)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  helpers.defer(function()
    vim.fn.delete(dir, "rf")
  end)
  -- The comment on the header checks requires-python is still found after it.
  local lines = { "[project]  # package metadata", 'requires-python = ">=3.9"', "dependencies = [" }
  for _, spec in ipairs(dependencies) do
    table.insert(lines, '  "' .. spec .. '",')
  end
  table.insert(lines, "]")
  local path = dir .. "/pyproject.toml"
  vim.fn.writefile(lines, path)
  helpers.create_uv_lock(dir, packages or { requests = "2.31.0" })
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf(), path
end

---@class PyDepsUpdateSpy
---@field pypi string[]
---@field uv table[]
---@field menu? PyDepsSelectOpts
---@field messages string[]
---@field diffs integer
---@field respond fun(meta: table?, dry_run: PyDepsUvResolveResult)

---@return PyDepsUpdateSpy
local function stub_update()
  local spy = { pypi = {}, uv = {}, messages = {}, diffs = 0 }
  local pending = {}
  helpers.stub_module("pydeps.providers.pypi", {
    get = function(name, cb)
      table.insert(spy.pypi, name)
      table.insert(pending, cb)
    end,
    is_yanked = require("pydeps.providers.pypi").is_yanked,
  })
  helpers.stub_module("pydeps.providers.uv", {
    resolve = function(opts)
      table.insert(spy.uv, opts)
    end,
  })
  helpers.stub_module("pydeps.core.update_plan", nil)
  helpers.stub_module("pydeps.commands.resolve", nil)
  helpers.stub_module("pydeps.commands.update", nil)
  helpers.stub(require("pydeps.ui.select_menu"), "show", function(opts)
    spy.menu = opts
  end)
  helpers.stub(require("pydeps.ui.lock_diff"), "show", function()
    spy.diffs = spy.diffs + 1
  end)
  helpers.stub(require("pydeps.core.state"), "refresh_all", function() end)
  helpers.stub(vim, "notify", function(msg)
    table.insert(spy.messages, msg)
  end)
  spy.respond = function(meta, dry_run)
    for _, cb in ipairs(pending) do
      cb(meta)
    end
    pending = {}
    spy.uv[#spy.uv].on_finish(dry_run)
    helpers.drain(20)
  end
  return spy
end

---@param spy PyDepsUpdateSpy
---@param pattern string
---@return boolean
local function notified(spy, pattern)
  for _, msg in ipairs(spy.messages) do
    if msg:find(pattern) then
      return true
    end
  end
  return false
end

---@param versions table<string, string?>
---@return table
local function meta(versions)
  local releases = {}
  for name, requires_python in pairs(versions) do
    releases[name] = { { requires_python = requires_python ~= "" and requires_python or nil } }
  end
  return { info = {}, releases = releases }
end

---@param bufnr integer
---@return string[]
local function dependency_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 3, -2, false)
end

T["update refuses direct references without fetching or editing"] = function()
  for _, spec in ipairs({
    "package @ git+https://github.com/user/repo.git",
    "package @ https://example.com/package.tar.gz",
    "package @ file:///path/to/package",
    "package @ ./local/package",
  }) do
    local spy = stub_update()
    local bufnr = open_project({ spec })

    require("pydeps.commands.update").run("package")

    MiniTest.expect.equality(notified(spy, "direct reference"), true)
    MiniTest.expect.equality(spy.pypi, {})
    MiniTest.expect.equality(spy.uv, {})
    MiniTest.expect.equality(dependency_lines(bufnr), { '  "' .. spec .. '",' })
    helpers.restore_all()
  end
end

T["update asks for a saved pyproject.toml because uv plans from disk"] = function()
  local spy = stub_update()
  local bufnr = open_project({ "requests>=2" })
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "# unsaved" })

  require("pydeps.commands.update").run("requests")

  MiniTest.expect.equality(notified(spy, "save pyproject.toml"), true)
  MiniTest.expect.equality(spy.pypi, {})
  MiniTest.expect.equality(spy.uv, {})
end

T["update shows every candidate with its consequences in one menu"] = function()
  local spy = stub_update()
  open_project({ "rich>=13", "requests>=2,<3" }, { requests = "2.31.0", rich = "13.7.0" })

  require("pydeps.commands.update").run("requests")

  MiniTest.expect.equality(spy.pypi, { "requests" })
  MiniTest.expect.equality(#spy.uv, 1)
  MiniTest.expect.equality(spy.uv[1].args, { "--dry-run", "--upgrade-package", "requests" })
  MiniTest.expect.equality(spy.menu, nil)

  spy.respond(
    meta({ ["2.31.0"] = "", ["2.33.0"] = ">=3.8", ["3.0.0"] = ">=3.9", ["3.1.0"] = ">=3.11" }),
    { ok = true, code = 0, stderr = "Resolved 5 packages in 10ms\nUpdate requests v2.31.0 -> v2.32.3\nAdd idna v3.7" }
  )

  MiniTest.expect.equality(spy.menu.prompt, "update requests")
  MiniTest.expect.equality(spy.menu.header, {
    "declared  requests>=2,<3",
    "locked    2.31.0",
    "latest 3.1.0 requires Python >=3.11 (project supports 3.9)",
  })
  local items = vim.tbl_map(function(item)
    return { label = item.label, details = item.details }
  end, spy.menu.items)
  MiniTest.expect.equality(items, {
    {
      label = "2.31.0 -> 2.32.3  keep declaration (resolved by uv)",
      details = { "~ requests 2.31.0 -> 2.32.3", "+ idna 3.7" },
    },
    { label = "2.31.0 -> 2.33.0  keep declaration (latest in range; uv resolves 2.32.3)" },
    {
      label = "2.31.0 -> 3.0.0  change declaration (newest for Python 3.9)",
      details = { "requests>=2,<3  =>  requests>=3.0.0,<4" },
    },
  })
end

T["choosing uv's upgrade locks it without touching the declaration"] = function()
  local spy = stub_update()
  local bufnr = open_project({ "requests>=2,<3" })
  require("pydeps.commands.update").run("requests")
  spy.respond(nil, { ok = true, code = 0, stderr = "Update requests v2.31.0 -> v2.32.3" })

  spy.menu.on_select(spy.menu.items[1])

  MiniTest.expect.equality(#spy.uv, 2)
  MiniTest.expect.equality(spy.uv[2].args, { "--upgrade-package", "requests" })
  MiniTest.expect.equality(notified(spy, "running uv lock %-%-upgrade%-package requests$"), true)
  spy.uv[2].on_finish({ ok = true, code = 0 })
  MiniTest.expect.equality(spy.diffs, 1)
  MiniTest.expect.equality(vim.bo[bufnr].modified, false)
  MiniTest.expect.equality(dependency_lines(bufnr), { '  "requests>=2,<3",' })
end

T["choosing a declaration change saves it and locks that version"] = function()
  local spy = stub_update()
  local bufnr, path = open_project({ "requests>=2,<3" })
  require("pydeps.commands.update").run("requests")
  spy.respond(meta({ ["3.0.0"] = "" }), { ok = true, code = 0 })
  MiniTest.expect.equality(#spy.menu.items, 1)
  MiniTest.expect.equality(spy.menu.items[1].label, "2.31.0 -> 3.0.0  change declaration (latest)")

  spy.menu.on_select(spy.menu.items[1])

  MiniTest.expect.equality(dependency_lines(bufnr), { '  "requests>=3.0.0,<4",' })
  MiniTest.expect.equality(vim.bo[bufnr].modified, false)
  MiniTest.expect.equality(vim.fn.readfile(path)[4], '  "requests>=3.0.0,<4",')
  MiniTest.expect.equality(spy.uv[2].args, { "--upgrade-package", "requests==3.0.0" })
  spy.uv[2].on_finish({ ok = true, code = 0 })
  MiniTest.expect.equality(dependency_lines(bufnr), { '  "requests>=3.0.0,<4",' })
end

T["a declaration change is undone when uv cannot lock it"] = function()
  local spy = stub_update()
  local bufnr, path = open_project({ "requests>=2,<3" })
  require("pydeps.commands.update").run("requests")
  spy.respond(meta({ ["3.0.0"] = "" }), { ok = true, code = 0 })
  spy.menu.on_select(spy.menu.items[1])

  spy.uv[2].on_finish({ ok = false, code = 1, reason = "exit", stderr = "error: No solution found" })

  MiniTest.expect.equality(notified(spy, "uv lock failed"), true)
  MiniTest.expect.equality(notified(spy, "restored declaration requests>=2,<3"), true)
  MiniTest.expect.equality(dependency_lines(bufnr), { '  "requests>=2,<3",' })
  MiniTest.expect.equality(vim.bo[bufnr].modified, false)
  MiniTest.expect.equality(vim.fn.readfile(path)[4], '  "requests>=2,<3",')
  MiniTest.expect.equality(spy.diffs, 0)
end

T["a declaration moved by a formatter on save is not restored over another line"] = function()
  local spy = stub_update()
  local bufnr, path = open_project({ "requests>=2,<3" })
  require("pydeps.commands.update").run("requests")
  spy.respond(meta({ ["3.0.0"] = "" }), { ok = true, code = 0 })
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = bufnr,
    once = true,
    callback = function()
      vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "# formatted" })
    end,
  })
  spy.menu.on_select(spy.menu.items[1])

  spy.uv[2].on_finish({ ok = false, code = 1, reason = "exit" })

  MiniTest.expect.equality(notified(spy, "declaration left as requests>=3.0.0,<4"), true)
  MiniTest.expect.equality(vim.fn.readfile(path), {
    "# formatted",
    "[project]  # package metadata",
    'requires-python = ">=3.9"',
    "dependencies = [",
    '  "requests>=3.0.0,<4",',
    "]",
  })
end

T["a failing write autocommand after the save still locks the saved declaration"] = function()
  local spy = stub_update()
  local bufnr, path = open_project({ "requests>=2,<3" })
  require("pydeps.commands.update").run("requests")
  spy.respond(meta({ ["3.0.0"] = "" }), { ok = true, code = 0 })
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = bufnr,
    once = true,
    callback = function()
      error("hook failed")
    end,
  })

  spy.menu.on_select(spy.menu.items[1])

  MiniTest.expect.equality(vim.fn.readfile(path)[4], '  "requests>=3.0.0,<4",')
  MiniTest.expect.equality(vim.bo[bufnr].modified, false)
  MiniTest.expect.equality(spy.uv[2].args, { "--upgrade-package", "requests==3.0.0" })
end

T["a declaration that cannot be written is rolled back without locking"] = function()
  local spy = stub_update()
  local bufnr, path = open_project({ "requests>=2,<3" })
  require("pydeps.commands.update").run("requests")
  spy.respond(meta({ ["3.0.0"] = "" }), { ok = true, code = 0 })
  vim.bo[bufnr].readonly = true
  helpers.stub(vim.o, "writeany", false)

  spy.menu.on_select(spy.menu.items[1])

  MiniTest.expect.equality(notified(spy, "failed to write pyproject.toml"), true)
  MiniTest.expect.equality(dependency_lines(bufnr), { '  "requests>=2,<3",' })
  MiniTest.expect.equality(vim.fn.readfile(path)[4], '  "requests>=2,<3",')
  MiniTest.expect.equality(#spy.uv, 1)
end

T["update explains why nothing newer can be offered"] = function()
  local spy = stub_update()
  open_project({ "requests==2.31.0" })
  require("pydeps.commands.update").run("requests")

  spy.respond(
    meta({ ["2.31.0"] = "", ["3.0.0"] = ">=3.12" }),
    { ok = false, code = 1, reason = "exit", stderr = "Resolved\nerror: No solution found\n  hint: pinned" }
  )

  MiniTest.expect.equality(spy.menu, nil)
  MiniTest.expect.equality(
    spy.messages[#spy.messages],
    table.concat({
      "pydeps: no update available for requests (locked 2.31.0)",
      "latest 3.0.0 requires Python >=3.12 (project supports 3.9)",
      "uv lock --dry-run failed: error: No solution found\n  hint: pinned",
    }, "\n")
  )
end

local mutations = {
  insert = function(buf)
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { 'description = "KEEP THIS TEXT"' })
  end,
  delete = function(buf)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
  end,
  rewrite = function(buf)
    vim.api.nvim_buf_set_lines(buf, 3, 4, false, { '  "requests==3",' })
  end,
  undo = function(buf)
    vim.cmd("let &undolevels = &undolevels")
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "# temporary" })
    vim.cmd("undo")
  end,
  unchanged = function() end,
}

for name, mutate in pairs(mutations) do
  T["a pending update preserves " .. name] = function()
    local spy = stub_update()
    local bufnr = open_project({ "requests==1" }, { requests = "1" })
    require("pydeps.commands.update").run("requests")
    spy.respond(meta({ ["1"] = "", ["2"] = "" }), { ok = true, code = 0 })

    mutate(bufnr)
    local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    spy.menu.on_select(spy.menu.items[1])
    local after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    if name == "unchanged" then
      before[4] = '  "requests==2",'
      MiniTest.expect.equality(after, before)
      MiniTest.expect.equality(spy.uv[2].args, { "--upgrade-package", "requests==2" })
    else
      MiniTest.expect.equality(after, before)
      MiniTest.expect.equality(notified(spy, "buffer changed"), true)
      MiniTest.expect.equality(#spy.uv, 1)
    end
  end
end

T["deferred package prompt plans for the buffer that asked"] = function()
  local spy = stub_update()
  local origin = open_project({ "requests==1" }, { requests = "1" })
  local other = open_project({ "requests==9" }, { requests = "9" })
  local origin_root = require("pydeps.core.buffer_context").find_root(origin)
  vim.api.nvim_set_current_buf(origin)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local prompt
  helpers.stub(vim.ui, "input", function(_, cb)
    prompt = cb
  end)

  require("pydeps.commands.update").run()
  MiniTest.expect.equality(type(prompt), "function")
  -- The user moves to another project before answering the prompt.
  vim.api.nvim_set_current_buf(other)
  prompt("requests")
  MiniTest.expect.equality(spy.uv[1].root, origin_root)
  spy.respond(meta({ ["2"] = "" }), { ok = true, code = 0 })
  spy.menu.on_select(spy.menu.items[1])
  MiniTest.expect.equality(dependency_lines(origin), { '  "requests==2",' })
  MiniTest.expect.equality(dependency_lines(other), { '  "requests==9",' })

  -- Closing the requesting buffer cancels rather than falling back to the current one.
  vim.api.nvim_set_current_buf(origin)
  require("pydeps.commands.update").run()
  vim.api.nvim_set_current_buf(other)
  vim.api.nvim_buf_delete(origin, { force = true })
  prompt("requests")
  MiniTest.expect.equality(#spy.uv, 2)
  MiniTest.expect.equality(notified(spy, "no longer available"), true)
  MiniTest.expect.equality(dependency_lines(other), { '  "requests==9",' })
end

return T
