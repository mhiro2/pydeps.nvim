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

return T
