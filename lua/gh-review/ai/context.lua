local M = {}

-- ---------------------------------------------------------------------------
-- Upfront context gathering (cheap, included for "standard" and "full")
-- ---------------------------------------------------------------------------

--- Get recent git commit history for a file.
--- @param filename string  path relative to repo root
--- @param limit? integer   max number of commits (default 5)
--- @return string
function M.file_history(filename, limit)
  limit = limit or 5
  local cmd = string.format(
    "git log --oneline -%d -- %s 2>/dev/null",
    limit,
    vim.fn.shellescape(filename)
  )
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 or result == "" then
    return ""
  end
  return vim.trim(result)
end

--- Get the directory listing for a file's parent directory.
--- @param filename string  path relative to repo root
--- @return string
function M.directory_listing(filename)
  local dir = vim.fn.fnamemodify(filename, ":h")
  if dir == "" or dir == "." then dir = "." end
  local cmd = string.format("ls -1 %s 2>/dev/null", vim.fn.shellescape(dir))
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 or result == "" then
    return ""
  end
  return vim.trim(result)
end

--- Extract import/require/include statements from file lines.
--- @param lines string[]
--- @return string[]
function M.extract_imports(lines)
  local imports = {}
  for _, line in ipairs(lines) do
    if line:match("^%s*import%s")
      or line:match("^%s*from%s")
      or line:match("require%s*%(")
      or line:match("^%s*#include")
      or line:match("^%s*use%s")
      or line:match("^%s*using%s")
      or line:match("^%s*package%s")
    then
      table.insert(imports, vim.trim(line))
    end
  end
  return imports
end

--- Build upfront context string for a file (used in "standard" and "full" levels).
--- @param filename string
--- @param head_lines string[]
--- @return string  context text to prepend to the user message (may be empty)
function M.build_upfront_context(filename, head_lines)
  local parts = {}

  -- Recent git history
  local history = M.file_history(filename, 5)
  if history ~= "" then
    table.insert(parts, "Recent git history for this file:")
    table.insert(parts, history)
  end

  -- Import/dependency statements
  local imports = M.extract_imports(head_lines)
  if #imports > 0 then
    table.insert(parts, "\nImports/dependencies:")
    for _, imp in ipairs(imports) do
      table.insert(parts, "  " .. imp)
    end
  end

  -- Sibling files in the same directory
  local listing = M.directory_listing(filename)
  if listing ~= "" then
    table.insert(parts, "\nFiles in the same directory:")
    table.insert(parts, listing)
  end

  if #parts == 0 then return "" end
  return table.concat(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- On-demand context tools (used in "full" level via multi-turn tool use)
-- ---------------------------------------------------------------------------

M.CONTEXT_TOOLS = {
  {
    name = "get_file_history",
    description = "Get recent git commit messages for a file to understand its change history",
    input_schema = {
      type = "object",
      properties = {
        path  = { type = "string",  description = "File path relative to repo root" },
        limit = { type = "integer", description = "Max commits to show (default 10)" },
      },
      required = { "path" },
    },
  },
  {
    name = "read_repo_file",
    description = "Read the contents of a file in the repository. Use this to understand related code, type definitions, or dependencies referenced in the diff.",
    input_schema = {
      type = "object",
      properties = {
        path      = { type = "string",  description = "File path relative to repo root" },
        max_lines = { type = "integer", description = "Max lines to read (default 200)" },
      },
      required = { "path" },
    },
  },
  {
    name = "list_directory",
    description = "List files in a directory to understand project structure",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Directory path relative to repo root" },
      },
      required = { "path" },
    },
  },
}

--- Execute a context tool call and return the result string.
--- @param tool_name string
--- @param tool_input table
--- @return string
function M.execute_tool(tool_name, tool_input)
  if tool_name == "get_file_history" then
    local result = M.file_history(tool_input.path, tool_input.limit or 10)
    return result ~= "" and result or "No git history found for this file."

  elseif tool_name == "read_repo_file" then
    local max_lines = tool_input.max_lines or 200
    local path = tool_input.path or ""
    -- Prevent path traversal
    if path:match("%.%.") then
      return "Error: path traversal not allowed"
    end
    local lines = vim.fn.readfile(path, "", max_lines)
    if not lines or #lines == 0 then
      return "File not found or empty: " .. path
    end
    local numbered = {}
    for i, line in ipairs(lines) do
      table.insert(numbered, string.format("%4d: %s", i, line))
    end
    local result = table.concat(numbered, "\n")
    if #lines >= max_lines then
      result = result .. string.format("\n... (truncated at %d lines)", max_lines)
    end
    return result

  elseif tool_name == "list_directory" then
    local result = M.directory_listing(tool_input.path or ".")
    return result ~= "" and result or "Directory not found or empty: " .. (tool_input.path or "")

  else
    return "Unknown tool: " .. tool_name
  end
end

return M
