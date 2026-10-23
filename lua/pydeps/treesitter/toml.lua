---Tree-sitter based TOML parser for accurate dependency extraction
---@class PyDepsTreesitterToml

---@class PyDepsDependency
---@field name string
---@field spec string
---@field line integer
---@field col_start integer
---@field col_end integer
---@field comment_col? integer
---@field group? string

local util = require("pydeps.util")

local M = {}

-- Cached query for comment detection
local comment_query = nil

local key_node_types = {
  bare_key = true,
  dotted_key = true,
  quoted_key = true,
}

---@param node table
---@return table|nil
local function find_key_node(node)
  for child in node:iter_children() do
    if key_node_types[child:type()] then
      return child
    end
  end
  return nil
end

---@param node table
---@return table|nil, table|nil
local function find_pair_key_and_array(node)
  local key_node = nil
  local array_node = nil
  for child in node:iter_children() do
    local t = child:type()
    if t == "array" then
      array_node = child
    elseif key_node_types[t] then
      key_node = child
    end
  end
  return key_node, array_node
end

---Resolve the dependency section that a `key = [...]` pair declares.
---@param table_key string
---@param key_name string
---@return string|nil section
local function dependency_section(table_key, key_name)
  if table_key == "project" and key_name == "dependencies" then
    return "project"
  elseif table_key == "project.optional-dependencies" then
    return "optional:" .. key_name
  elseif table_key == "dependency-groups" then
    return "group:" .. key_name
  end
  return nil
end

---Section of the array node when it is the value of a dependency pair.
---@param bufnr integer
---@param array_node table
---@return string|nil section
local function array_section(bufnr, array_node)
  local pair = array_node:parent()
  if not pair or pair:type() ~= "pair" then
    return nil
  end
  local table_node = pair:parent()
  if not table_node or (table_node:type() ~= "table" and table_node:type() ~= "table_array_element") then
    return nil
  end
  local key_node, value_node = find_pair_key_and_array(pair)
  local table_key_node = find_key_node(table_node)
  if not key_node or not table_key_node or value_node ~= array_node then
    return nil
  end
  return dependency_section(
    vim.treesitter.get_node_text(table_key_node, bufnr),
    vim.treesitter.get_node_text(key_node, bufnr)
  )
end

---Call `fn` for every dependency array in the document.
---@param bufnr integer
---@param root table
---@param fn fun(section: string, array_node: table)
local function each_dependency_array(bufnr, root, fn)
  for node in root:iter_children() do
    if node:type() == "table" or node:type() == "table_array_element" then
      for child in node:iter_children() do
        if child:type() == "pair" then
          local _, array_node = find_pair_key_and_array(child)
          local section = array_node and array_section(bufnr, array_node)
          if section then
            fn(section, array_node)
          end
        end
      end
    end
  end
end

---Check if Tree-sitter and toml parser are available
---@return boolean
function M.is_available()
  if not vim.treesitter or not vim.treesitter.language then
    return false
  end

  if M._available ~= nil then
    return M._available
  end

  local ok_add = pcall(vim.treesitter.language.add, "toml")
  if not ok_add then
    M._available = false
    return false
  end

  local inspect_language = vim.treesitter.language.inspect
  if type(inspect_language) ~= "function" then
    M._available = false
    return false
  end

  local ok_inspect, info = pcall(inspect_language, "toml")
  if not ok_inspect or not info then
    M._available = false
    return false
  end

  M._available = true
  return true
end

---Get the Tree-sitter parser for a buffer
---@param bufnr integer
---@return table|nil parser
local function get_parser(bufnr)
  if not M.is_available() then
    return nil
  end

  return vim.treesitter.get_parser(bufnr, "toml")
end

---Ensure the comment query is initialised
---@return table|nil query
local function ensure_comment_query()
  if not comment_query then
    local query_str = [[(comment) @comment]]
    local ok, query = pcall(vim.treesitter.query.parse, "toml", query_str)
    if not ok then
      return nil
    end
    comment_query = query
  end
  return comment_query
end

---Build a map of 0-indexed line number → 1-indexed comment column for all
---comment nodes under the given tree root.  This avoids re-parsing the buffer
---once per dependency.
---@param bufnr integer
---@param tree_root table Tree-sitter root node
---@return table<integer, integer> comment_map line (0-indexed) → col (1-indexed)
local function build_comment_map(bufnr, tree_root)
  local map = {}
  local query = ensure_comment_query()
  if not query then
    return map
  end

  for _, node in query:iter_captures(tree_root, bufnr, 0, -1) do
    local start_row, start_col = node:range()
    if not map[start_row] then
      map[start_row] = start_col + 1 -- Convert to 1-indexed
    end
  end

  return map
end

---Parse dependencies from an array node
---@param bufnr integer
---@param array_node table Tree-sitter node
---@param section string Section name (e.g., "project", "optional:dev")
---@param comment_map table<integer, integer> 0-indexed line → 1-indexed comment col
---@return PyDepsDependency[]
local function parse_array_dependencies(bufnr, array_node, section, comment_map)
  local deps = {}

  for child in array_node:iter_children() do
    if child:type() == "string" then
      local start_row, start_col, _, end_col = child:range()
      local value = vim.treesitter.get_node_text(child, bufnr)

      -- Remove quotes
      local unquoted = value:match("^[\"'](.+)[\"']$") or value

      local name = util.parse_requirement_name(unquoted)
      if name then
        local comment_col = comment_map[start_row]
        table.insert(deps, {
          name = name,
          spec = unquoted,
          line = start_row + 1, -- Convert to 1-indexed
          col_start = start_col + 1,
          col_end = end_col,
          comment_col = comment_col,
          group = section,
        })
      end
    end
  end

  return deps
end

---Parse dependencies using Tree-sitter
---@param bufnr integer
---@return PyDepsDependency[]
function M.parse_buffer(bufnr)
  local parser = get_parser(bufnr)
  if not parser then
    return {}
  end

  local tree = parser:parse()[1]
  if not tree then
    return {}
  end

  local root = tree:root()
  local comment_map = build_comment_map(bufnr, root)
  local deps = {}

  each_dependency_array(bufnr, root, function(section, array_node)
    vim.list_extend(deps, parse_array_dependencies(bufnr, array_node, section, comment_map))
  end)

  return deps
end

---Get dependency array ranges (dependencies / optional-dependencies / dependency-groups)
---@param bufnr integer
---@return table<string, {start_line: integer, end_line: integer}> ranges
function M.get_dependency_array_ranges(bufnr)
  local parser = get_parser(bufnr)
  if not parser then
    return {}
  end

  local tree = parser:parse()[1]
  if not tree then
    return {}
  end

  local root = tree:root()
  local ranges = {}

  each_dependency_array(bufnr, root, function(section, array_node)
    local start_row, _, end_row, _ = array_node:range()
    ranges[section] = {
      start_line = start_row + 1,
      end_line = end_row + 1,
    }
  end)

  return ranges
end

---Return the dependency section whose array directly holds the string at a position.
---Strings nested in inline tables (e.g. `{ include-group = "dev" }`) are not dependencies.
---@param bufnr integer
---@param row integer 0-indexed line
---@param col integer 0-indexed byte column of the string's opening quote
---@return string|nil section
function M.dependency_section_at(bufnr, row, col)
  local parser = get_parser(bufnr)
  if not parser then
    return nil
  end

  local tree = parser:parse()[1]
  if not tree then
    return nil
  end

  local node = tree:root():descendant_for_range(row, col, row, col)
  while node do
    local node_type = node:type()
    if node_type == "array" then
      return array_section(bufnr, node)
    end
    if node_type == "comment" or node_type == "pair" or node_type == "inline_table" or node_type == "table" then
      return nil
    end
    node = node:parent()
  end
  return nil
end

return M
