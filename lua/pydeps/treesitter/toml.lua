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

---Check if Tree-sitter and toml parser are available
---@return boolean
function M.is_available()
  -- Check if vim.treesitter is available
  if not vim.treesitter then
    return false
  end

  -- Return cached result if available
  if M._available ~= nil then
    return M._available
  end

  -- Try to create a test parser to verify toml is available
  local ok = pcall(function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].filetype = "toml"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "test = 1" })
    local parser = vim.treesitter.get_parser(bufnr, "toml")
    local tree = parser:parse()
    vim.api.nvim_buf_delete(bufnr, { force = true })
    return tree ~= nil
  end)

  M._available = ok
  return ok
end

---Get the Tree-sitter parser for a buffer
---@param bufnr integer
---@return table|nil parser
local function get_parser(bufnr)
  if not M.is_available() then
    return nil
  end
  local ok, ts_parsers = pcall(require, "vim.treesitter")
  if not ok then
    return nil
  end
  local ok2, parser = pcall(ts_parsers.get_parser, bufnr, "toml")
  if not ok2 then
    return nil
  end
  return parser
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

---Get comment column for a line
---@param bufnr integer
---@param line integer 0-indexed line number
---@return integer|nil comment_col 1-indexed column, or nil if no comment
function M.get_comment_col(bufnr, line)
  local parser = get_parser(bufnr)
  if not parser then
    return nil
  end

  local tree = parser:parse()[1]
  if not tree then
    return nil
  end

  local root = tree:root()

  local query = ensure_comment_query()
  if not query then
    return nil
  end

  for _, node in query:iter_captures(root, bufnr, line, line + 1) do
    local start_row, start_col = node:range()
    if start_row == line then
      return start_col + 1 -- Convert to 1-indexed
    end
  end

  return nil
end

---Get section info for dependencies
---@param bufnr integer
---@return table<string, {start_line: integer, end_line: integer}> section_ranges
function M.get_section_ranges(bufnr)
  local parser = get_parser(bufnr)
  if not parser then
    return {}
  end

  local tree = parser:parse()[1]
  if not tree then
    return {}
  end

  local root = tree:root()
  local sections = {}

  for node in root:iter_children() do
    if node:type() == "table" or node:type() == "table_array_element" then
      local key_node = find_key_node(node)
      if key_node then
        local start_row, _, end_row, _ = node:range()
        local key_text = vim.treesitter.get_node_text(key_node, bufnr)
        sections[key_text] = {
          start_line = start_row + 1, -- Convert to 1-indexed
          end_line = end_row + 1,
        }
      end
    end
  end

  return sections
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

  for node in root:iter_children() do
    if node:type() == "table" or node:type() == "table_array_element" then
      local table_key_node = find_key_node(node)
      if table_key_node then
        local table_key = vim.treesitter.get_node_text(table_key_node, bufnr)
        for child in node:iter_children() do
          if child:type() == "pair" then
            local key_node, array_node = find_pair_key_and_array(child)
            if key_node and array_node then
              local key_name = vim.treesitter.get_node_text(key_node, bufnr)
              local section = nil
              if table_key == "project" and key_name == "dependencies" then
                section = "project"
              elseif table_key == "project.optional-dependencies" then
                section = "optional:" .. key_name
              elseif table_key == "dependency-groups" then
                section = "group:" .. key_name
              end
              if section then
                local parsed = parse_array_dependencies(bufnr, array_node, section, comment_map)
                vim.list_extend(deps, parsed)
              end
            end
          end
        end
      end
    end
  end

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

  for node in root:iter_children() do
    if node:type() == "table" or node:type() == "table_array_element" then
      local table_key_node = find_key_node(node)
      if table_key_node then
        local table_key = vim.treesitter.get_node_text(table_key_node, bufnr)
        for child in node:iter_children() do
          if child:type() == "pair" then
            local key_node, array_node = find_pair_key_and_array(child)
            if key_node and array_node then
              local key_name = vim.treesitter.get_node_text(key_node, bufnr)
              local section = nil
              if table_key == "project" and key_name == "dependencies" then
                section = "project"
              elseif table_key == "project.optional-dependencies" then
                section = "optional:" .. key_name
              elseif table_key == "dependency-groups" then
                section = "group:" .. key_name
              end
              if section then
                local start_row, _, end_row, _ = array_node:range()
                ranges[section] = {
                  start_line = start_row + 1,
                  end_line = end_row + 1,
                }
              end
            end
          end
        end
      end
    end
  end

  return ranges
end

---Parse dependencies from file path using Tree-sitter
---@param path string
---@return PyDepsDependency[]
function M.parse_file(path)
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end

  -- Create a temporary buffer to parse the file
  local bufnr = vim.api.nvim_create_buf(false, true)
  local lines = vim.fn.readfile(path)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = "toml"

  local deps = M.parse_buffer(bufnr)

  -- Clean up temporary buffer
  vim.api.nvim_buf_delete(bufnr, { force = true })

  return deps
end

return M
