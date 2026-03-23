local M = {}
local exec = require("gh-dash-diff.gh.exec")

-- ---------------------------------------------------------------------------
-- Viewed-state GraphQL queries / mutations
-- ---------------------------------------------------------------------------

local VIEWED_STATES_QUERY = [[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id
      files(first: 100) {
        nodes {
          path
          viewerViewedState
        }
      }
    }
  }
}
]]

--- Fetch PR node ID and viewer-viewed states for all files in a PR.
--- Returns { pr_node_id: string, viewed_files: table<string, boolean> }
--- @param owner string
--- @param repo string
--- @param pr_number integer
--- @param callback fun(err: string|nil, result: {pr_node_id: string, viewed_files: table<string, boolean>}|nil)
function M.fetch_viewed_states(owner, repo, pr_number, callback)
  exec.graphql(VIEWED_STATES_QUERY, {
    owner = owner,
    name = repo,
    number = pr_number,
  }, function(err, data)
    if err then callback(err, nil); return end
    local pr = vim.tbl_get(data, "repository", "pullRequest")
    if not pr then callback("Could not find PR in GraphQL response", nil); return end
    local pr_node_id = pr.id
    local viewed_files = {}
    for _, f in ipairs((pr.files or {}).nodes or {}) do
      if f.viewerViewedState == "VIEWED" then
        viewed_files[f.path] = true
      end
    end
    callback(nil, { pr_node_id = pr_node_id, viewed_files = viewed_files })
  end)
end

--- Mark a file as viewed via GraphQL mutation.
--- @param pr_node_id string GraphQL node ID of the pull request
--- @param path string File path relative to repo root
--- @param callback fun(err: string|nil)
function M.mark_file_as_viewed(pr_node_id, path, callback)
  exec.graphql(
    "mutation($prId: ID!, $path: String!) { markFileAsViewed(input: {pullRequestId: $prId, path: $path}) { pullRequest { id } } }",
    { prId = pr_node_id, path = path },
    function(err, _) callback(err) end
  )
end

--- Unmark a file as viewed via GraphQL mutation.
--- @param pr_node_id string GraphQL node ID of the pull request
--- @param path string File path relative to repo root
--- @param callback fun(err: string|nil)
function M.unmark_file_as_viewed(pr_node_id, path, callback)
  exec.graphql(
    "mutation($prId: ID!, $path: String!) { unmarkFileAsViewed(input: {pullRequestId: $prId, path: $path}) { pullRequest { id } } }",
    { prId = pr_node_id, path = path },
    function(err, _) callback(err) end
  )
end

--- List all files changed in a PR.
--- Uses --paginate to handle PRs with >100 changed files.
--- @param owner string
--- @param repo string
--- @param pr_number integer
--- @param callback fun(err: string|nil, files: GhFile[]|nil)
function M.list(owner, repo, pr_number, callback)
  exec.run_json({
    "api",
    string.format("repos/%s/%s/pulls/%d/files", owner, repo, pr_number),
    "--paginate",
  }, nil, callback)
end

--- Get file content at a git ref via `git show`.
--- Returns nil lines (not an error) when the file does not exist at that ref
--- (e.g. newly added or deleted file) — callers must handle nil.
--- @param ref string Git ref: branch name, commit SHA, "origin/main", etc.
--- @param filepath string Repo-relative path
--- @param cwd string Git repository root
--- @param callback fun(err: string|nil, lines: string[]|nil)
function M.get_content(ref, filepath, cwd, callback)
  vim.system(
    { "git", "show", ref .. ":" .. filepath },
    { text = true, cwd = cwd },
    function(result)
      vim.schedule(function()
        if result.code == 0 then
          local lines = vim.split(result.stdout, "\n", { plain = true })
          -- git show appends a trailing newline; remove the empty last element
          if lines[#lines] == "" then table.remove(lines) end
          callback(nil, lines)
        else
          -- Exit code 128 = path not found in ref (new/deleted file)
          callback(result.stderr, nil)
        end
      end)
    end
  )
end

--- Get the merge-base commit SHA between two refs.
--- @param base_ref string e.g. "origin/main"
--- @param head_ref string e.g. "origin/feature-branch"
--- @param cwd string Git repository root
--- @param callback fun(err: string|nil, sha: string|nil)
function M.merge_base(base_ref, head_ref, cwd, callback)
  vim.system(
    { "git", "merge-base", base_ref, head_ref },
    { text = true, cwd = cwd },
    function(result)
      vim.schedule(function()
        if result.code == 0 then
          callback(nil, vim.trim(result.stdout))
        else
          callback("Could not find merge base: " .. (result.stderr or ""), nil)
        end
      end)
    end
  )
end

--- Fetch a remote ref to ensure the PR branch is available locally.
--- @param remote string e.g. "origin"
--- @param ref string e.g. "refs/pull/123/head"
--- @param cwd string Git repository root
--- @param callback fun(err: string|nil)
function M.fetch_ref(remote, ref, cwd, callback)
  vim.system(
    { "git", "fetch", remote, ref },
    { text = true, cwd = cwd },
    function(result)
      vim.schedule(function()
        if result.code == 0 then
          callback(nil)
        else
          callback("git fetch failed: " .. (result.stderr or ""))
        end
      end)
    end
  )
end

--- Detect if a GhFile represents a binary file.
--- Binary files have no patch and no line changes, yet have changes > 0.
--- @param file GhFile
--- @return boolean
function M.is_binary(file)
  return not file.patch
    and (file.additions or 0) == 0
    and (file.deletions or 0) == 0
    and (file.changes or 0) > 0
end

return M
