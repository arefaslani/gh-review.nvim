local M = {}
local exec = require("gh-dash-diff.gh.exec")

--- Detect the GitHub owner and repo name for a directory.
--- Tries gh CLI first (handles SSH, HTTPS, forks, GitHub Enterprise),
--- then falls back to parsing git remote URLs.
--- @param cwd? string Directory to detect from (defaults to vim.uv.cwd())
--- @param callback fun(err: string|nil, owner: string|nil, repo: string|nil)
function M.detect(cwd, callback)
  cwd = cwd or vim.uv.cwd()
  exec.run(
    { "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner" },
    { cwd = cwd },
    function(err, stdout)
      if not err and stdout then
        local full = vim.trim(stdout)
        local owner, repo = full:match("^([^/]+)/(.+)$")
        if owner and repo then
          callback(nil, owner, repo)
          return
        end
      end
      -- Fallback: parse git remote URL manually
      M._detect_from_remote(cwd, callback)
    end
  )
end

--- @private
--- Parse owner/repo from git remote URLs.
--- @param cwd string
--- @param callback fun(err: string|nil, owner: string|nil, repo: string|nil)
function M._detect_from_remote(cwd, callback)
  vim.system(
    { "git", "remote", "-v" },
    { text = true, cwd = cwd },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback("Not a git repository", nil, nil)
          return
        end
        -- Match github.com URLs in SSH or HTTPS format:
        --   SSH:   git@github.com:owner/repo.git
        --   HTTPS: https://github.com/owner/repo.git
        local stdout = result.stdout or ""
        local owner, repo = stdout:match("github%.com[:/]([^/%s]+)/([^/%s%.]+)")
        if owner and repo then
          callback(nil, owner, repo)
        else
          callback("Could not detect GitHub repository from git remotes", nil, nil)
        end
      end)
    end
  )
end

--- Get the current git branch name.
--- @param cwd? string
--- @param callback fun(err: string|nil, branch: string|nil)
function M.current_branch(cwd, callback)
  vim.system(
    { "git", "branch", "--show-current" },
    { text = true, cwd = cwd or vim.uv.cwd() },
    function(result)
      vim.schedule(function()
        if result.code == 0 then
          callback(nil, vim.trim(result.stdout))
        else
          callback("Not in a git repository", nil)
        end
      end)
    end
  )
end

--- Get the git repository root directory.
--- @param cwd? string
--- @param callback fun(err: string|nil, root: string|nil)
function M.git_root(cwd, callback)
  vim.system(
    { "git", "rev-parse", "--show-toplevel" },
    { text = true, cwd = cwd or vim.uv.cwd() },
    function(result)
      vim.schedule(function()
        if result.code == 0 then
          callback(nil, vim.trim(result.stdout))
        else
          callback("Not in a git repository", nil)
        end
      end)
    end
  )
end

return M
