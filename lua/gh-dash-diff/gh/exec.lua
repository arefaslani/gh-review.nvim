local M = {}

--- Execute a gh CLI command asynchronously.
--- @param args string[] Command arguments (without "gh" prefix)
--- @param opts? {cwd?: string, stdin?: string} Extra options
--- @param callback fun(err: string|nil, stdout: string|nil) Callback
--- @return vim.SystemObj Process handle
function M.run(args, opts, callback)
  opts = opts or {}
  local cmd = vim.list_extend({ "gh" }, args)
  local sys_opts = { text = true, cwd = opts.cwd }
  if opts.stdin then sys_opts.stdin = opts.stdin end

  return vim.system(cmd, sys_opts, function(result)
    vim.schedule(function()
      if result.code == 0 then
        callback(nil, result.stdout)
      else
        local err = vim.trim(result.stderr or "")
        if err == "" then err = "gh exited with code " .. result.code end
        callback(err, nil)
      end
    end)
  end)
end

--- Execute a gh CLI command and parse the output as JSON.
--- @param args string[] Command arguments
--- @param opts? {cwd?: string, stdin?: string}
--- @param callback fun(err: string|nil, data: any)
function M.run_json(args, opts, callback)
  M.run(args, opts, function(err, stdout)
    if err then callback(err, nil); return end
    local ok, data = pcall(vim.json.decode, stdout, { luanil = { object = true, array = true } })
    if not ok then callback("JSON parse error: " .. tostring(data), nil); return end
    callback(nil, data)
  end)
end

--- Run a gh GraphQL query asynchronously.
--- @param query string GraphQL query or mutation string
--- @param variables table<string, any> GraphQL variables
--- @param callback fun(err: string|nil, data: table|nil)
function M.graphql(query, variables, callback)
  local args = { "api", "graphql", "-f", "query=" .. query }
  for key, val in pairs(variables or {}) do
    if type(val) == "number" then
      table.insert(args, "-F"); table.insert(args, key .. "=" .. tostring(val))
    else
      table.insert(args, "-f"); table.insert(args, key .. "=" .. tostring(val))
    end
  end
  M.run_json(args, nil, function(err, data)
    if err then callback(err, nil); return end
    if data and data.errors then
      local msgs = {}
      for _, e in ipairs(data.errors) do table.insert(msgs, e.message or "unknown GraphQL error") end
      callback(table.concat(msgs, "; "), nil); return
    end
    callback(nil, data and data.data)
  end)
end

--- Check if gh is installed and authenticated.
--- @param callback fun(err: string|nil)
function M.check_auth(callback)
  M.run({ "auth", "status" }, nil, function(err, _)
    if err then
      if err:find("not logged") or err:find("authentication") then
        callback("gh is not authenticated. Run `gh auth login` first.")
      elseif err:find("command not found") or err:find("executable file not found") then
        callback("gh CLI is not installed. See https://cli.github.com")
      elseif err:find("rate limit") or err:find("429") then
        callback("GitHub API rate limit exceeded. Try again later.")
      elseif err:find("connection refused") or err:find("no such host") then
        callback("Network error. Check your internet connection.")
      else
        callback("gh error: " .. err)
      end
      return
    end
    callback(nil)
  end)
end

return M
