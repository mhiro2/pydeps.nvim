local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

T["lock snapshot key is stable across symlinked roots"] = function()
  local cache = require("pydeps.core.cache")

  local real_dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(real_dir, "p")

  -- A symlink that points at the real project directory.
  local link_dir = vim.fn.tempname()
  MiniTest.expect.no_equality(vim.uv.fs_symlink(real_dir, link_dir), nil)

  -- Store the snapshot through the symlinked path and read it back through the
  -- real path: both must resolve to the same canonical cache key.
  cache.set_lock_snapshot(link_dir, { pkg = "1.0.0" })
  local snapshot = cache.get_lock_snapshot(real_dir)
  MiniTest.expect.equality(snapshot ~= nil and snapshot.pkg, "1.0.0")

  -- Cleanup
  vim.uv.fs_unlink(link_dir)
  vim.fn.delete(real_dir, "rf")
end

---@param lines string[]
---@return string dir, string lock_path
local function create_lock_project(lines)
  local dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "[project]" }, dir .. "/pyproject.toml")
  vim.fn.writefile(lines, dir .. "/uv.lock")
  helpers.defer(function()
    vim.fn.delete(dir, "rf")
  end)
  return dir, dir .. "/uv.lock"
end

---Hold lockfile.parse_async callbacks so a case decides when parsing finishes.
---@return { path: string, cb: fun(data: table?) }[]
local function hold_lock_parses()
  local held = {}
  helpers.stub(require("pydeps.sources.lockfile"), "parse_async", function(path, cb)
    table.insert(held, { path = path, cb = cb })
  end)
  return held
end

---@return table[]
local function record_lockfile_events()
  local events = {}
  local id = vim.api.nvim_create_autocmd("User", {
    pattern = "PyDepsLockfileUpdated",
    callback = function(args)
      table.insert(events, args.data)
    end,
  })
  helpers.defer(function()
    vim.api.nvim_del_autocmd(id)
  end)
  return events
end

T["get_pyproject reparses only when the buffer changes"] = function()
  local cache = require("pydeps.core.cache")
  local pyproject = require("pydeps.sources.pyproject")
  local parse = pyproject.parse
  local parses = 0
  helpers.stub(pyproject, "parse", function(...)
    parses = parses + 1
    return parse(...)
  end)

  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. "/pyproject.toml")
  helpers.setup_buffer({ "[project]", "dependencies = [", '  "requests",', "]" })

  MiniTest.expect.equality(#cache.get_pyproject(bufnr), 1)
  MiniTest.expect.equality(#cache.get_pyproject(bufnr), 1)
  MiniTest.expect.equality(parses, 1)

  vim.api.nvim_buf_set_lines(bufnr, 2, 2, false, { '  "rich",' })
  MiniTest.expect.equality(#cache.get_pyproject(bufnr), 2)
  MiniTest.expect.equality(parses, 2)

  cache.invalidate_pyproject(bufnr)
  cache.get_pyproject(bufnr)
  MiniTest.expect.equality(parses, 3)
end

T["get_lockfile shares one async parse and announces the result"] = function()
  local cache = require("pydeps.core.cache")
  local dir, lock_path = create_lock_project({ "version = 1" })
  local held = hold_lock_parses()
  local events = record_lockfile_events()

  local data, missing, loading = cache.get_lockfile(dir)
  MiniTest.expect.equality({ data.resolved, missing, loading }, { {}, false, true })
  cache.get_lockfile(dir)
  MiniTest.expect.equality(#held, 1)

  held[1].cb({ resolved = { requests = "2.31.0" }, packages = {}, graph = {} })
  helpers.wait_for(function()
    return #events == 1
  end, "PyDepsLockfileUpdated")
  MiniTest.expect.equality(events[1], { root = dir, path = lock_path })

  data, missing, loading = cache.get_lockfile(dir)
  MiniTest.expect.equality({ data.resolved, missing, loading }, { { requests = "2.31.0" }, false, false })
  MiniTest.expect.equality(#held, 1)
end

T["get_lockfile serves the old data while a changed lockfile reparses"] = function()
  local cache = require("pydeps.core.cache")
  local dir, lock_path = create_lock_project({ "version = 1" })
  local held = hold_lock_parses()

  cache.get_lockfile(dir)
  held[1].cb({ resolved = { requests = "1.0.0" }, packages = {}, graph = {} })

  -- Same size, different mtime: only the timestamp tells the files apart.
  vim.fn.writefile({ "version = 2" }, lock_path)
  local stat = vim.uv.fs_stat(lock_path)
  vim.uv.fs_utime(lock_path, stat.atime.sec, stat.mtime.sec + 10)

  local data, _, loading = cache.get_lockfile(dir)
  MiniTest.expect.equality(data.resolved, { requests = "1.0.0" })
  MiniTest.expect.equality(loading, true)
  MiniTest.expect.equality(#held, 2)

  held[2].cb({ resolved = { requests = "2.0.0" }, packages = {}, graph = {} })
  data, _, loading = cache.get_lockfile(dir)
  MiniTest.expect.equality(data.resolved, { requests = "2.0.0" })
  MiniTest.expect.equality(loading, false)
end

T["invalidate_lockfile forces a fresh parse"] = function()
  local cache = require("pydeps.core.cache")
  local dir = create_lock_project({ "version = 1" })
  local held = hold_lock_parses()

  cache.get_lockfile(dir)
  held[1].cb({ resolved = { requests = "1.0.0" }, packages = {}, graph = {} })
  cache.invalidate_lockfile(dir)

  local data, _, loading = cache.get_lockfile(dir)
  MiniTest.expect.equality(data.resolved, {})
  MiniTest.expect.equality(loading, true)
  MiniTest.expect.equality(#held, 2)
end

return T
