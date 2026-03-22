local M = {}
local exec = require("gh-dash-diff.gh.exec")

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
--- @param opts? {state?: "open"|"closed"|"all", limit?: integer, author?: string}
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
  exec.run_json(args, nil, callback)
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
