local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

local function stub_env()
  helpers.stub_module("pydeps.core.env", {
    get = function()
      return {}
    end,
  })
end

local function stub_pypi()
  helpers.stub_module("pydeps.providers.pypi", {
    get_cached = function()
      return nil
    end,
    get = function(_, cb)
      if cb then
        cb({ releases = {} })
      end
    end,
    is_yanked = function()
      return false
    end,
  })
end

---@param bufnr integer
---@param ns integer
---@return table<integer, integer> badge display column by 0-indexed row
local function badge_cols(bufnr, ns)
  local cols = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
    local details = mark[4] or {}
    if details.virt_text_win_col then
      cols[mark[2]] = details.virt_text_win_col
    end
  end
  return cols
end

local function setup_virtual_text()
  stub_env()
  stub_pypi()
  package.loaded["pydeps.ui.virtual_text"] = nil
  local config = require("pydeps.config")
  config.setup({
    show_missing_virtual_text = false,
    ui = {
      section_padding = 2,
      icons = { enabled = false },
      show = {
        resolved = true,
        latest = false,
      },
    },
  })
  return require("pydeps.ui.virtual_text")
end

T["inline badge moves after comment"] = function()
  local virtual_text = setup_virtual_text()
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "short>=1.0",        # comment',
    '  "averyverylongpackage>=1.0",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local resolved = {
    short = "1.0.0",
    averyverylongpackage = "1.0.0",
  }

  virtual_text.render(bufnr, deps, resolved, { lockfile_missing = false })

  -- The comment line is 32 cells wide, so its badge starts one cell after it;
  -- the plain line aligns to the section anchor (col_end 29 + padding 2 - 1).
  MiniTest.expect.equality(badge_cols(bufnr, virtual_text.ns), { [2] = 33, [3] = 30 })
end

T["inline badge moves after wide comment"] = function()
  local virtual_text = setup_virtual_text()
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "wide>=1.0", #\tcomment',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local resolved = { wide = "1.0.0" }

  virtual_text.render(bufnr, deps, resolved, { lockfile_missing = false })

  -- The tab expands to column 24, so the comment ends at display width 31.
  MiniTest.expect.equality(badge_cols(bufnr, virtual_text.ns), { [2] = 32 })
end

T["inline badge ignores hashes inside strings"] = function()
  local virtual_text = setup_virtual_text()
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "short>=1.0",',
    '  "pkg @ https://x.io/p.whl#md5=0",',
    "]",
    "",
    "[project.optional-dependencies]",
    "kernel = [",
    '  "short>=1.0",',
    "  \"kernel; platform_version == '#1 SMP'\",",
    "]",
    "",
    "[dependency-groups]",
    "esc = [",
    '  "short>=1.0",',
    '  "esc @ https://x.io/e.whl#\\"q\\"",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)

  virtual_text.render(
    bufnr,
    deps,
    { short = "1.0.0", pkg = "1.0.0", kernel = "1.0.0", esc = "1.0.0" },
    { lockfile_missing = false }
  )

  -- Each section aligns to its longest string end (34, 40 and 34) plus padding;
  -- treating `#` inside a string as a comment would push those badges past the line.
  MiniTest.expect.equality(
    badge_cols(bufnr, virtual_text.ns),
    { [2] = 35, [3] = 35, [8] = 41, [9] = 41, [14] = 35, [15] = 35 }
  )
end

T["inline badge aligns without comments"] = function()
  local virtual_text = setup_virtual_text()
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "short>=1.0",',
    '  "averyverylongpackage>=1.0",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local resolved = {
    short = "1.0.0",
    averyverylongpackage = "1.0.0",
  }

  virtual_text.render(bufnr, deps, resolved, { lockfile_missing = false })

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, virtual_text.ns, 0, -1, { details = true })
  local cols = {}
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    if details.virt_text_win_col then
      table.insert(cols, details.virt_text_win_col)
    end
  end

  MiniTest.expect.equality(#cols, 2)
  MiniTest.expect.equality(cols[1] == cols[2], true)
end

T["lock mismatch shows pinned version in badge"] = function()
  local virtual_text = setup_virtual_text()
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "pinnedpkg==1.0.0",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local resolved = {
    pinnedpkg = "1.1.0",
  }

  virtual_text.render(bufnr, deps, resolved, { lockfile_missing = false })

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, virtual_text.ns, 0, -1, { details = true })
  MiniTest.expect.equality(#marks, 1)

  local details = marks[1][4] or {}
  local virt_text = details.virt_text or {}

  -- Should show resolved version and lock mismatch icon with pinned version
  local text = ""
  for _, chunk in ipairs(virt_text) do
    text = text .. chunk[1]
  end

  -- Should contain resolved version "1.1.0" and pinned version "1.0.0"
  MiniTest.expect.equality(string.find(text, "1.1.0") ~= nil, true)
  MiniTest.expect.equality(string.find(text, "1.0.0") ~= nil, true)
end

T["unresolved pinned dependency is not classified as lock mismatch"] = function()
  stub_env()
  package.loaded["pydeps.providers.pypi"] = {
    get_cached = function(name)
      if name == "pendingpkg" then
        return {
          releases = {
            ["1.0.0"] = {},
          },
        }
      end
      return nil
    end,
    get = function(_, cb)
      if cb then
        cb({
          releases = {
            ["1.0.0"] = {},
          },
        })
      end
    end,
    is_yanked = function()
      return false
    end,
  }
  package.loaded["pydeps.ui.virtual_text"] = nil
  local config = require("pydeps.config")
  config.setup({
    show_missing_virtual_text = true,
    ui = {
      section_padding = 2,
      icons = { enabled = false },
      show = {
        resolved = true,
        latest = false,
      },
    },
  })
  local virtual_text = require("pydeps.ui.virtual_text")
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "pendingpkg==1.0.0",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)

  virtual_text.render(bufnr, deps, {}, { lockfile_missing = false })

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, virtual_text.ns, 0, -1, { details = true })
  MiniTest.expect.equality(#marks, 1)

  local details = marks[1][4] or {}
  local virt_text = details.virt_text or {}
  local text = ""
  for _, chunk in ipairs(virt_text) do
    text = text .. chunk[1]
  end

  MiniTest.expect.equality(string.find(text, "unresolved") ~= nil, true)
  MiniTest.expect.equality(string.find(text, "pinned:") == nil, true)
end

T["pin not found shows message when version not on PyPI"] = function()
  stub_env()
  package.loaded["pydeps.providers.pypi"] = {
    get_cached = function(name)
      if name == "notfoundpkg" then
        return {
          releases = {
            ["1.0.0"] = {},
            ["1.2.0"] = {},
          },
        }
      end
      return nil
    end,
    get = function(_, cb)
      cb({})
    end,
    is_yanked = function()
      return false
    end,
  }
  package.loaded["pydeps.ui.virtual_text"] = nil
  local config = require("pydeps.config")
  config.setup({
    show_missing_virtual_text = false,
    ui = {
      section_padding = 2,
      icons = { enabled = false },
      show = {
        resolved = true,
        latest = false,
      },
    },
  })
  local virtual_text = require("pydeps.ui.virtual_text")
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "notfoundpkg==1.1.0",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local resolved = {
    notfoundpkg = "1.1.0",
  }

  virtual_text.render(bufnr, deps, resolved, { lockfile_missing = false })

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, virtual_text.ns, 0, -1, { details = true })
  MiniTest.expect.equality(#marks, 1)

  local details = marks[1][4] or {}
  local virt_text = details.virt_text or {}

  -- Should show "not on public PyPI" message
  local text = ""
  for _, chunk in ipairs(virt_text) do
    text = text .. chunk[1]
  end

  MiniTest.expect.equality(string.find(text, "not on public PyPI") ~= nil, true)
end

T["render survives stale col after buffer edit"] = function()
  local virtual_text = setup_virtual_text()
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "averyverylongpackage>=1.0.0",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local resolved = { averyverylongpackage = "1.0.0" }

  -- Simulate user editing the dependency line to be much shorter than the
  -- col positions captured during the original parse.
  vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "x" })

  MiniTest.expect.no_error(function()
    virtual_text.render(bufnr, deps, resolved, { lockfile_missing = false })
  end)
  MiniTest.expect.equality(badge_cols(bufnr, virtual_text.ns), {})
end

T["render skips deps whose line was deleted"] = function()
  local virtual_text = setup_virtual_text()
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "somepkg>=1.0.0",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local resolved = { somepkg = "1.0.0" }

  -- Truncate the buffer so the dependency row is past its end.
  vim.api.nvim_buf_set_lines(bufnr, 2, -1, false, {})

  MiniTest.expect.no_error(function()
    virtual_text.render(bufnr, deps, resolved, { lockfile_missing = false })
  end)
  MiniTest.expect.equality(vim.api.nvim_buf_get_extmarks(bufnr, virtual_text.ns, 0, -1, {}), {})
end

T["render does not move a stale badge onto the following line"] = function()
  local virtual_text = setup_virtual_text()
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "somepkg>=1.0.0",',
    '  "otherpkg>=1.0.0",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)

  -- Deleting the first dependency shifts otherpkg and the closing bracket up,
  -- while the parsed rows still point at the old positions.
  vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, {})
  virtual_text.render(bufnr, deps, { somepkg = "1.0.0", otherpkg = "1.0.0" }, { lockfile_missing = false })

  MiniTest.expect.equality(badge_cols(bufnr, virtual_text.ns), {})
end

T["render does not move a stale badge onto a row that only mentions the name"] = function()
  local virtual_text = setup_virtual_text()
  local pyproject = require("pydeps.sources.pyproject")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  for _, next_line in ipairs({ '  "requests-toolbelt>=1.0",', "  # requests is pinned for py38" }) do
    helpers.setup_buffer({ "[project]", "dependencies = [", '  "requests>=2.0",', next_line, "]" })
    local deps = pyproject.parse(nil, nil, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, {})
    virtual_text.render(bufnr, deps, { requests = "2.0.0", ["requests-toolbelt"] = "1.0.0" }, {
      lockfile_missing = false,
    })
    MiniTest.expect.equality(badge_cols(bufnr, virtual_text.ns), {})
  end
end

T["a marker keeps its locked version badge while the environment loads"] = function()
  local virtual_text = setup_virtual_text()
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "plain>=1.0",',
    "  \"marked>=1.0; python_version >= '3.8'\",",
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  -- stub_env reports an empty environment, so the marker cannot be evaluated yet.
  virtual_text.render(bufnr, deps, { plain = "1.0.0", marked = "2.0.0" }, { lockfile_missing = false })

  local badges = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, virtual_text.ns, 0, -1, { details = true })) do
    local chunks = (mark[4] or {}).virt_text
    if chunks then
      local text = {}
      for _, chunk in ipairs(chunks) do
        text[#text + 1] = chunk[1]
      end
      badges[mark[2]] = table.concat(text)
    end
  end

  -- Both badges still carry the locked version; the marker only stays unevaluated.
  MiniTest.expect.equality(badges[2] and badges[2]:match("%S+$"), "1.0.0")
  MiniTest.expect.equality(badges[3] and badges[3]:match("%S+$"), "2.0.0")
end

T["a failed PyPI fetch renders once without re-requesting"] = function()
  stub_env()
  local failed = {}
  local get_calls = 0
  package.loaded["pydeps.providers.pypi"] = {
    get_cached = function(name)
      return nil, failed[name] == true
    end,
    get = function(name, cb)
      get_calls = get_calls + 1
      failed[name] = true
      cb(nil)
    end,
    is_yanked = function()
      return false
    end,
  }
  require("pydeps.core.jobs")._reset()
  package.loaded["pydeps.ui.virtual_text"] = nil
  package.loaded["pydeps.ui.diagnostics"] = nil
  require("pydeps.config").setup({ enable_diagnostics = true })
  local virtual_text = require("pydeps.ui.virtual_text")
  local diagnostics = require("pydeps.ui.diagnostics")
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "offline>=1.0",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local original_render = virtual_text.render
  local renders = 0
  virtual_text.render = function(...)
    renders = renders + 1
    return original_render(...)
  end
  virtual_text.render(bufnr, deps, {}, { lockfile_missing = false })
  diagnostics.render(bufnr, deps, {}, { lockfile_missing = false })
  vim.wait(300, function()
    return false
  end, 10)
  virtual_text.render = original_render
  virtual_text.clear(bufnr)

  MiniTest.expect.equality(get_calls, 1)
  MiniTest.expect.equality(renders, 2)
end

return T
