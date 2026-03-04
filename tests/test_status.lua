local MiniTest = require("mini.test")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["pydeps.ui.status"] = nil
    end,
  },
})

T["classify returns lock mismatch with pinned version"] = function()
  local status = require("pydeps.ui.status")
  local result = status.classify({
    spec = "pkg==1.0.0",
    resolved = "1.1.0",
  })

  MiniTest.expect.equality(result.class, "lock_mismatch")
  MiniTest.expect.equality(result.pinned_version, "1.0.0")
end

T["classify prioritizes unknown for unresolved dependency"] = function()
  local status = require("pydeps.ui.status")
  local result = status.classify({
    spec = "pkg==1.0.0",
    unresolved = true,
    resolved = nil,
  })

  MiniTest.expect.equality(result.class, "unknown")
end

T["classify returns pin_not_found when pinned version is missing"] = function()
  local status = require("pydeps.ui.status")
  local result = status.classify({
    spec = "pkg==1.1.0",
    resolved = "1.1.0",
    meta = {
      releases = {
        ["1.0.0"] = {},
      },
    },
  })

  MiniTest.expect.equality(result.class, "pin_not_found")
  MiniTest.expect.equality(result.pinned_version, "1.1.0")
end

T["classify returns major for major updates"] = function()
  local status = require("pydeps.ui.status")
  local result = status.classify({
    resolved = "1.9.0",
    latest = "2.0.0",
  })

  MiniTest.expect.equality(result.class, "major")
end

T["is_active evaluates markers with extra/group context"] = function()
  local status = require("pydeps.ui.status")
  local env = {
    python_version = "3.11",
    sys_platform = "linux",
  }

  local optional_dep = {
    spec = "pkg>=1.0; extra == 'dev'",
    group = "optional:dev",
  }
  MiniTest.expect.equality(status.is_active(optional_dep, env), true)

  local group_dep = {
    spec = "pkg>=1.0; group == 'test'",
    group = "group:test",
  }
  MiniTest.expect.equality(status.is_active(group_dep, env), true)
end

return T
