local MiniTest = require("mini.test")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["pydeps.providers.pypi"] = nil
      package.loaded["pydeps.ui.dependency_view"] = nil
    end,
  },
})

---@param opts? table
local function stub_pypi(opts)
  opts = opts or {}
  package.loaded["pydeps.providers.pypi"] = {
    get_cached = function()
      return nil
    end,
    is_yanked = opts.is_yanked or function()
      return false
    end,
    sorted_versions = opts.sorted_versions,
  }
end

T["dependency_view builds lock mismatch status summary"] = function()
  stub_pypi()
  local dependency_view = require("pydeps.ui.dependency_view")

  local view = dependency_view.build({
    name = "pkg",
    spec = "pkg==1.0.0",
  }, {
    current_env = {},
    resolved = {
      pkg = "1.1.0",
    },
    meta = {
      info = { version = "1.2.0" },
      releases = {
        ["1.0.0"] = {},
        ["1.1.0"] = {},
      },
    },
  })

  MiniTest.expect.equality(view.class, "lock_mismatch")
  MiniTest.expect.equality(view.pinned_version, "1.0.0")
  MiniTest.expect.equality(view.status_kind, "warn")
  MiniTest.expect.equality(view.status_text, "lock mismatch")
  MiniTest.expect.equality(view.lock_status, "(lock mismatch)")
end

T["dependency_view marks unresolved dependencies as unknown"] = function()
  stub_pypi()
  local dependency_view = require("pydeps.ui.dependency_view")

  local view = dependency_view.build({
    name = "pkg",
    spec = "pkg>=1.0",
  }, {
    current_env = {},
    meta = {
      info = { version = "1.2.0" },
      releases = {
        ["1.2.0"] = {},
      },
    },
  })

  MiniTest.expect.equality(view.unresolved, true)
  MiniTest.expect.equality(view.class, "unknown")
  MiniTest.expect.equality(view.status_kind, "unknown")
end

T["dependency_view marks yanked releases as error status"] = function()
  stub_pypi({
    is_yanked = function(_meta, version)
      return version == "1.0.0"
    end,
  })
  local dependency_view = require("pydeps.ui.dependency_view")

  local view = dependency_view.build({
    name = "pkg",
    spec = "pkg>=1.0",
  }, {
    current_env = {},
    resolved = {
      pkg = "1.0.0",
    },
    meta = {
      info = { version = "1.0.0" },
      releases = {
        ["1.0.0"] = {
          { yanked = true },
        },
      },
    },
  })

  MiniTest.expect.equality(view.yanked, true)
  MiniTest.expect.equality(view.class, "yanked")
  MiniTest.expect.equality(view.status_kind, "error")
  MiniTest.expect.equality(view.status_text, "yanked")
end

T["dependency_view marks lockfile loading as loading status"] = function()
  stub_pypi()
  local dependency_view = require("pydeps.ui.dependency_view")

  local view = dependency_view.build({
    name = "pkg",
    spec = "pkg>=1.0",
  }, {
    current_env = {},
    lockfile_loading = true,
  })

  MiniTest.expect.equality(view.pending, "loading")
  MiniTest.expect.equality(view.class, "loading")
  MiniTest.expect.equality(view.status_kind, "unknown")
  MiniTest.expect.equality(view.status_text, "Loading")
end

return T
