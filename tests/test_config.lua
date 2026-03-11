local MiniTest = require("mini.test")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["pydeps.config"] = nil
    end,
  },
})

T["setup accepts empty options"] = function()
  local config = require("pydeps.config")
  MiniTest.expect.no_error(function()
    config.setup({})
  end)
end

T["setup validates top-level option types"] = function()
  local config = require("pydeps.config")
  local ok, err = pcall(config.setup, {
    show_virtual_text = "yes",
  })

  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(type(err), "string")
  MiniTest.expect.equality(err:match("show_virtual_text") ~= nil, true)
end

T["setup validates nested option types"] = function()
  local config = require("pydeps.config")
  local ok, err = pcall(config.setup, {
    completion = {
      pypi_search_min = "2",
    },
  })

  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(type(err), "string")
  MiniTest.expect.equality(err:match("pypi_search_min") ~= nil, true)
end

T["setup validates diagnostic severity option types"] = function()
  local config = require("pydeps.config")
  local ok, err = pcall(config.setup, {
    diagnostic_severity = {
      lock = "warn",
    },
  })

  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(type(err), "string")
  MiniTest.expect.equality(err:match("lock") ~= nil, true)
end

T["setup validates ui icon option types"] = function()
  local config = require("pydeps.config")
  local ok, err = pcall(config.setup, {
    ui = {
      icons = {
        update = false,
      },
    },
  })

  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(type(err), "string")
  MiniTest.expect.equality(err:match("update") ~= nil, true)
end

T["setup validates ui status text option types"] = function()
  local config = require("pydeps.config")
  local ok, err = pcall(config.setup, {
    ui = {
      status_text = {
        loading = 1,
      },
    },
  })

  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(type(err), "string")
  MiniTest.expect.equality(err:match("loading") ~= nil, true)
end

T["setup accepts osv options"] = function()
  local config = require("pydeps.config")
  MiniTest.expect.no_error(function()
    config.setup({
      audit_window_border = "single",
      osv_url = "https://api.osv.dev/v1/querybatch",
      osv_cache_ttl = 7200,
    })
  end)
end

T["setup rejects negative debounce"] = function()
  local config = require("pydeps.config")
  local ok, err = pcall(config.setup, {
    refresh_debounce_ms = -1,
  })

  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(type(err), "string")
  MiniTest.expect.equality(err:match("refresh_debounce_ms") ~= nil, true)
end

T["setup rejects non-positive cache ttl"] = function()
  local config = require("pydeps.config")

  local ok_pypi, err_pypi = pcall(config.setup, {
    pypi_cache_ttl = 0,
  })
  MiniTest.expect.equality(ok_pypi, false)
  MiniTest.expect.equality(type(err_pypi), "string")
  MiniTest.expect.equality(err_pypi:match("pypi_cache_ttl") ~= nil, true)

  local ok_osv, err_osv = pcall(config.setup, {
    osv_cache_ttl = 0,
  })
  MiniTest.expect.equality(ok_osv, false)
  MiniTest.expect.equality(type(err_osv), "string")
  MiniTest.expect.equality(err_osv:match("osv_cache_ttl") ~= nil, true)
end

T["setup rejects invalid completion max_results range"] = function()
  local config = require("pydeps.config")
  local ok, err = pcall(config.setup, {
    completion = {
      max_results = 0,
    },
  })

  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(type(err), "string")
  MiniTest.expect.equality(err:match("max_results") ~= nil, true)
end

T["setup accepts boundary values for numeric ranges"] = function()
  local config = require("pydeps.config")
  MiniTest.expect.no_error(function()
    config.setup({
      refresh_debounce_ms = 0,
      pypi_cache_ttl = 1,
      osv_cache_ttl = 1,
      completion = {
        max_results = 1,
      },
    })
  end)
end

return T
