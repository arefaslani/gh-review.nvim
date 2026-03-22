local M = {}
M._initialized = false
M._dash_buf = nil

function M.setup(opts)
  local config = require("gh-dash-diff.config")
  M.config = config.apply(opts)
  config.validate(M.config)

  -- Initialize namespaces once
  local state = require("gh-dash-diff.state")
  state.state.ns.comments = vim.api.nvim_create_namespace("gh-pr-comments")
  state.state.ns.signs = vim.api.nvim_create_namespace("gh-pr-signs")
  state.state.ns.eol = vim.api.nvim_create_namespace("gh-pr-eol")

  require("gh-dash-diff.ui.highlights").setup()

  -- Autocmds for cleanup when user closes the tab/windows externally
  local group = vim.api.nvim_create_augroup("GhDashDiff", { clear = true })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      local s = require("gh-dash-diff.state").state
      if s.layout.tab and not vim.api.nvim_tabpage_is_valid(s.layout.tab) then
        require("gh-dash-diff.state").reset()
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local s = require("gh-dash-diff.state").state
      local closed = tonumber(ev.match)
      if closed == s.layout.left_win or closed == s.layout.right_win then
        vim.schedule(function()
          M.close()
        end)
      end
    end,
  })

  M._initialized = true
end

function M.open_pr(pr_number)
  if not M._initialized then M.setup({}) end

  -- Close gh-dash terminal if it's open
  if M._dash_buf and vim.api.nvim_buf_is_valid(M._dash_buf) then
    vim.api.nvim_buf_delete(M._dash_buf, { force = true })
    M._dash_buf = nil
  end

  if not pr_number then
    vim.notify("gh-dash-diff: PR number required. Use :GhDashDiff <number>", vim.log.levels.WARN)
    return
  end

  local State = require("gh-dash-diff.state").state
  local repo_mod = require("gh-dash-diff.gh.repo")
  local prs_mod = require("gh-dash-diff.gh.prs")
  local files_mod = require("gh-dash-diff.gh.files")
  local reviews_mod = require("gh-dash-diff.gh.reviews")

  repo_mod.detect(nil, function(err, owner, name)
    if err then vim.notify("gh-dash-diff: " .. err, vim.log.levels.ERROR); return end
    State.repo.owner = owner
    State.repo.name = name

    prs_mod.get(owner, name, pr_number, function(err2, pr)
      if err2 then vim.notify("gh-dash-diff: " .. err2, vim.log.levels.ERROR); return end
      State.pr.number = pr.number
      State.pr.title = pr.title
      State.pr.head_ref = pr.headRefName
      State.pr.base_ref = pr.baseRefName
      State.pr.head_sha = pr.headRefOid
      State.pr.base_sha = pr.baseRefOid

      files_mod.list(owner, name, pr_number, function(err3, files)
        if err3 then vim.notify("gh-dash-diff: " .. err3, vim.log.levels.ERROR); return end
        State.pr.files = files

        -- Open the review layout: Snacks sidebar + diff windows
        require("gh-dash-diff.ui").open(pr, files)

        -- Fetch comments in background
        reviews_mod.fetch_threads(owner, name, pr_number, function(_, threads)
          State.review.threads = threads or {}
          require("gh-dash-diff.ui.comments").render_all(threads or {})
        end)
      end)
    end)
  end)
end

function M.close()
  require("gh-dash-diff.ui.layout").close()
  require("gh-dash-diff.state").reset()
end

--- Open gh-dash inside a Neovim terminal buffer.
--- gh-dash is configured to send :GhDashDiff <pr_number> back to this Neovim instance.
function M.open_dash()
  if not M._initialized then M.setup({}) end

  local server = vim.v.servername
  if not server or server == "" then
    vim.notify("gh-dash-diff: No Neovim server address. Start Neovim with --listen or ensure it has a server.", vim.log.levels.ERROR)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  M._dash_buf = buf
  vim.api.nvim_set_current_buf(buf)
  vim.fn.termopen("gh dash", {
    env = { NVIM_SERVER = server },
    on_exit = function(_, _)
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      if M._dash_buf == buf then
        M._dash_buf = nil
      end
    end,
  })
  vim.cmd("startinsert")
end

return M
