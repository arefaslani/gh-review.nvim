local M = {}
local exec = require("gh-review.gh.exec")

--- Module-level contributors cache keyed by "owner/repo".
local _contributors_cache = {}

local PR_FIELDS = table.concat({
  "number", "title", "body", "state", "url",
  "author", "headRefName", "baseRefName", "headRefOid", "baseRefOid",
  "isDraft", "mergeable", "reviewDecision",
  "additions", "deletions", "changedFiles",
  "createdAt", "updatedAt",
}, ",")

--- List PRs for a repository.
--- @param owner string
--- @param repo string
--- @param opts? {state?: "open"|"closed"|"all", limit?: integer, author?: string, search?: string}
--- @param callback fun(err: string|nil, prs: GhPR[]|nil)
function M.list(owner, repo, opts, callback)
  opts = opts or {}
  local args = {
    "pr", "list",
    "--repo", owner .. "/" .. repo,
    "--state", opts.state or "open",
    "--limit", tostring(opts.limit or 50),
    "--json", PR_FIELDS,
  }
  if opts.author then
    table.insert(args, "--author")
    table.insert(args, opts.author)
  end
  if opts.search then
    table.insert(args, "--search")
    table.insert(args, opts.search)
  end
  exec.run_json(args, nil, callback)
end

--- List contributor logins for a repository. Results are cached per repo.
--- @param owner string
--- @param repo string
--- @param callback fun(err: string|nil, logins: string[]|nil)
function M.list_contributors(owner, repo, callback)
  local key = owner .. "/" .. repo
  if _contributors_cache[key] then
    callback(nil, _contributors_cache[key])
    return
  end
  exec.run(
    { "api", "repos/" .. owner .. "/" .. repo .. "/contributors", "--jq", ".[].login" },
    nil,
    function(err, stdout)
      if err then callback(err, nil); return end
      local logins = {}
      for _, line in ipairs(vim.split(vim.trim(stdout or ""), "\n", { plain = true })) do
        local login = vim.trim(line)
        if login ~= "" then
          table.insert(logins, login)
        end
      end
      _contributors_cache[key] = logins
      callback(nil, logins)
    end
  )
end

--- Get a single PR by number.
--- @param owner string
--- @param repo string
--- @param pr_number integer
--- @param callback fun(err: string|nil, pr: GhPR|nil)
function M.get(owner, repo, pr_number, callback)
  exec.run_json({
    "pr", "view", tostring(pr_number),
    "--repo", owner .. "/" .. repo,
    "--json", PR_FIELDS,
  }, nil, callback)
end

--- Get the unified diff text for a PR.
--- @param owner string
--- @param repo string
--- @param pr_number integer
--- @param callback fun(err: string|nil, diff_text: string|nil)
function M.get_diff(owner, repo, pr_number, callback)
  exec.run({
    "pr", "diff", tostring(pr_number),
    "--repo", owner .. "/" .. repo,
  }, nil, callback)
end

return M
