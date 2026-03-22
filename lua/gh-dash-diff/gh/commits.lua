local M = {}
local exec = require("gh-dash-diff.gh.exec")

--- List all commits in a PR.
--- @param owner string
--- @param repo string
--- @param pr_number integer
--- @param callback fun(err: string|nil, commits: GhCommit[]|nil)
function M.list(owner, repo, pr_number, callback)
  exec.run_json({
    "api",
    string.format("repos/%s/%s/pulls/%d/commits", owner, repo, pr_number),
    "--paginate",
  }, nil, function(err, data)
    if err then callback(err, nil); return end
    local commits = {}
    for _, c in ipairs(data or {}) do
      table.insert(commits, {
        sha     = c.sha,
        message = c.commit and c.commit.message or "",
        author  = {
          login = (c.author and c.author.login)
            or (c.commit and c.commit.author and c.commit.author.name)
            or "",
        },
        date    = c.commit and c.commit.author and c.commit.author.date or "",
      })
    end
    callback(nil, commits)
  end)
end

--- Get files changed in a specific commit.
--- Returns files with same shape as PR files: {filename, status, additions, deletions, previous_filename}
--- @param owner string
--- @param repo string
--- @param sha string Commit SHA
--- @param callback fun(err: string|nil, files: GhFile[]|nil)
function M.get_files(owner, repo, sha, callback)
  exec.run_json({
    "api",
    string.format("repos/%s/%s/commits/%s", owner, repo, sha),
  }, nil, function(err, data)
    if err then callback(err, nil); return end
    callback(nil, data and data.files or {})
  end)
end

return M
