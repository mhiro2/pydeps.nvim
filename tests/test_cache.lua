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

return T
