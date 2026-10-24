local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local tree_ui = require("pydeps.ui.tree")

local T = helpers.create_test_set()

-- Each row is one uv tree rendering; the expected table maps line numbers to package names.
local extract_cases = {
  {
    name = "simple tree",
    lines = {
      "requests 2.31.0",
      "├── charset-normalizer 3.3.2",
      "├── idna 3.6",
      "└── urllib3 2.0.7",
    },
    expected = { "requests", "charset-normalizer", "idna", "urllib3" },
  },
  {
    name = "complex tree skips (*) markers",
    lines = {
      "requests 2.31.0",
      "│   ├── certifi 2023.7.22",
      "│   └── urllib3 2.0.7",
      "└── (*)",
    },
    expected = { "requests", "certifi", "urllib3" },
  },
  {
    name = "lines without packages",
    lines = {
      "requests 2.31.0",
      "    ",
      "├── Some text without package",
      "└── urllib3 2.0.7",
    },
    expected = { [1] = "requests", [4] = "urllib3" },
  },
  {
    name = "name separators",
    lines = {
      "some_package_name 1.0.0",
      "some-package-name 1.0.0",
      "some.package.name 1.0.0",
    },
    -- uv may print any spelling; all of them name the same package.
    expected = { "some-package-name", "some-package-name", "some-package-name" },
  },
  {
    name = "pure asterisk lines",
    lines = {
      "requests 2.31.0",
      "(*)",
    },
    expected = { "requests" },
  },
  {
    name = "deeply nested tree",
    lines = {
      "requests 2.31.0",
      "│   ├── certifi 2023.7.22",
      "│   │   └── urllib3 2.0.7",
      "│   └── idna 3.6",
    },
    expected = { "requests", "certifi", "urllib3", "idna" },
  },
  {
    name = "v prefix versions",
    lines = {
      "pydantic v2.12.5",
      "├── annotated-types v0.7.0",
      "├── pydantic-core v2.41.5",
      "│   └── typing-extensions v4.15.0",
    },
    expected = { "pydantic", "annotated-types", "pydantic-core", "typing-extensions" },
  },
  {
    name = "mixed version formats",
    lines = {
      "package-old 1.0.0",
      "package-new v2.0.0",
    },
    expected = { "package-old", "package-new" },
  },
}

for _, case in ipairs(extract_cases) do
  T["extract packages: " .. case.name] = function()
    MiniTest.expect.equality(tree_ui.extract_packages(case.lines), case.expected)
  end
end

-- Tests for estimate_width function
T["estimate_width without root returns max line width plus padding"] = function()
  local lines = {
    "short",
    "medium length line here",
    "this is a very long line that should determine the width",
  }

  local width = tree_ui.estimate_width(lines, nil, nil)

  local max_line_width = vim.fn.strdisplaywidth("this is a very long line that should determine the width")
  MiniTest.expect.equality(width, max_line_width + 2) -- 2 for padding
end

T["estimate_width with deps includes badge width"] = function()
  local lines = {
    "requests v2.31.0",
    "└── urllib3 v2.0.7",
  }

  local direct_deps = { requests = true }
  local deps_list = {
    {
      name = "requests",
      spec = "requests[socks]>=2.31.0",
      line = 1,
      col_start = 1,
      col_end = 1,
      group = "optional:net",
    },
  }

  local width = tree_ui.estimate_width(lines, direct_deps, deps_list)

  -- "requests v2.31.0" (16) + space + "[direct] [net] [extra:socks]" (28) + float padding (2)
  MiniTest.expect.equality(width, 16 + 1 + 28 + 2)
end

T["estimate_width with empty lines"] = function()
  local lines = {
    "",
    "single line",
    "",
  }

  local width = tree_ui.estimate_width(lines, nil, nil)

  local line_width = vim.fn.strdisplaywidth("single line")
  MiniTest.expect.equality(width, line_width + 2)
end

---@param buf integer
---@return table<integer, string[][]> virt_text chunks by 0-indexed row
local function badge_marks(buf)
  local ns = vim.api.nvim_create_namespace("pydeps-tree")
  local result = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    MiniTest.expect.equality(mark[4].virt_text_pos, "eol")
    result[mark[2]] = mark[4].virt_text
  end
  return result
end

local tree_lines = {
  "requests v2.31.0",
  "├── charset-normalizer v3.3.2",
  "└── (*)",
}

T["add_badges places badges at the end of package lines"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, tree_lines)
  local deps_list = {
    { name = "requests", spec = "requests[socks]>=2", line = 1, col_start = 1, col_end = 1, group = "project" },
  }

  tree_ui.add_badges(buf, tree_lines, { requests = true }, deps_list)

  MiniTest.expect.equality(badge_marks(buf), {
    [0] = { { "[direct]", "PyDepsBadgeDirect" }, { "[extra:socks]", "PyDepsBadgeExtra" } },
    [1] = { { "[transitive]", "PyDepsBadgeTransitive" } },
  })
end

T["setup_keymaps badges from the project and acts on the package under the cursor"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "[project]", 'dependencies = ["requests>=2"]' }, dir .. "/pyproject.toml")
  helpers.create_uv_lock(dir)
  helpers.defer(function()
    vim.fn.delete(dir, "rf")
  end)
  helpers.stub_module("pydeps.core.env", {
    get = function()
      return {}
    end,
  })
  require("pydeps.core.cache").get_lockfile(dir, { sync = true })

  local why, shown = {}, {}
  helpers.stub_module("pydeps.commands", {
    provenance = function(name)
      table.insert(why, name)
    end,
  })
  helpers.stub_module("pydeps.ui.info", {
    show = function(dep, version, opts)
      table.insert(shown, { dep = dep, version = version, opts = opts })
    end,
  })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, tree_lines)
  vim.api.nvim_set_current_buf(buf)
  tree_ui.setup_keymaps(buf, tree_lines, { root = dir })

  MiniTest.expect.equality(badge_marks(buf), {
    [0] = { { "[direct]", "PyDepsBadgeDirect" } },
    [1] = { { "[transitive]", "PyDepsBadgeTransitive" } },
  })

  local maps = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    maps[map.lhs] = map.callback
  end

  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  maps["<CR>"]()
  MiniTest.expect.equality(why, { "charset-normalizer" })

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  maps["i"]()
  MiniTest.expect.equality(shown, {
    { dep = { name = "requests", spec = "===2.31.0" }, version = "2.31.0", opts = { lockfile_missing = false } },
  })
end

T["setup_keymaps matches declared names to uv's spelling"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({
    "[project]",
    'dependencies = ["Requests>=2", "Charset_Normalizer[unicode_backport]>=3"]',
  }, dir .. "/pyproject.toml")
  helpers.create_uv_lock(dir)
  helpers.defer(function()
    vim.fn.delete(dir, "rf")
  end)
  helpers.stub_module("pydeps.core.env", {
    get = function()
      return {}
    end,
  })
  require("pydeps.core.cache").get_lockfile(dir, { sync = true })
  local shown = {}
  helpers.stub_module("pydeps.ui.info", {
    show = function(dep, version)
      table.insert(shown, { dep.name, version })
    end,
  })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, tree_lines)
  vim.api.nvim_set_current_buf(buf)
  tree_ui.setup_keymaps(buf, tree_lines, { root = dir })

  MiniTest.expect.equality(badge_marks(buf), {
    [0] = { { "[direct]", "PyDepsBadgeDirect" } },
    [1] = { { "[direct]", "PyDepsBadgeDirect" }, { "[extra:unicode_backport]", "PyDepsBadgeExtra" } },
  })

  local info_map
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if map.lhs == "i" then
      info_map = map.callback
    end
  end
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  info_map()
  MiniTest.expect.equality(shown, { { "charset-normalizer", "3.3.2" } })
end

T["setup_keymaps cleans up when the tree buffer is wiped"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, tree_lines)
  tree_ui.setup_keymaps(buf, tree_lines)
  tree_ui.add_badges(buf, tree_lines, {}, {})
  MiniTest.expect.no_equality(badge_marks(buf), {})

  local cleaned = {}
  helpers.stub(tree_ui, "cleanup", function(target)
    table.insert(cleaned, target)
  end)
  vim.api.nvim_buf_delete(buf, { force = true })

  MiniTest.expect.equality(cleaned, { buf })
end

return T
