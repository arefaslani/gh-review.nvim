local M = {}
M._initialized = false
M._resume = nil  -- saved state for resuming a PR review

function M.setup(opts)
  local config = require("gh-review.config")
  M.config = config.apply(opts)
  config.validate(M.config)

  -- Initialize namespaces once
  local state = require("gh-review.state")
  state.state.ns.comments    = vim.api.nvim_create_namespace("gh-pr-comments")
  state.state.ns.signs       = vim.api.nvim_create_namespace("gh-pr-signs")
  state.state.ns.eol         = vim.api.nvim_create_namespace("gh-pr-eol")
  state.state.ns.ai_findings = vim.api.nvim_create_namespace("gh-pr-ai-findings")

  require("gh-review.ui.highlights").setup()

  -- Autocmds for cleanup when user closes the tab/windows externally
  local group = vim.api.nvim_create_augroup("GhReview", { clear = true })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      local s = require("gh-review.state").state
      if s.layout.tab and not vim.api.nvim_tabpage_is_valid(s.layout.tab) then
        require("gh-review.state").reset()
      end
    end,
  })

  -- WinClosed guard: only tear down if layout is fully ready
  -- (layout.ready is set after layout.open() completes)
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local s = require("gh-review.state").state
      if not s.layout.ready then return end
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

function M.open_pr(pr_number, open_opts)
  if not M._initialized then M.setup({}) end
  open_opts = open_opts or {}

  if not pr_number then
    vim.ui.input({ prompt = "PR number: " }, function(input)
      if not input or input == "" then return end
      local n = tonumber(input)
      if not n then
        vim.notify("gh-review: Invalid PR number", vim.log.levels.WARN)
        return
      end
      M.open_pr(n, open_opts)
    end)
    return
  end

  -- Show loading indicator before closing terminal (so user sees feedback immediately)
  vim.notify("gh-review: Loading PR #" .. pr_number .. "…", vim.log.levels.INFO)
  vim.cmd("redraw")

  local State = require("gh-review.state").state
  local repo_mod = require("gh-review.gh.repo")
  local prs_mod = require("gh-review.gh.prs")
  local files_mod = require("gh-review.gh.files")
  local reviews_mod = require("gh-review.gh.reviews")

  repo_mod.detect(nil, function(err, owner, name)
    if err then vim.notify("gh-review: " .. err, vim.log.levels.ERROR); return end
    State.repo.owner = owner
    State.repo.name = name

    -- Get git root (needed by diff.lua for git show)
    repo_mod.git_root(nil, function(root_err, root)
      if root_err then vim.notify("gh-review: " .. root_err, vim.log.levels.ERROR); return end
      State.repo.root = root

    prs_mod.get(owner, name, pr_number, function(err2, pr)
      if err2 then vim.notify("gh-review: " .. err2, vim.log.levels.ERROR); return end
      State.pr.number = pr.number
      State.pr.title = pr.title
      State.pr.head_ref = pr.headRefName
      State.pr.base_ref = pr.baseRefName
      State.pr.head_sha = pr.headRefOid
      State.pr.base_sha = pr.baseRefOid

      files_mod.list(owner, name, pr_number, function(err3, files)
        if err3 then vim.notify("gh-review: " .. err3, vim.log.levels.ERROR); return end
        State.pr.files = files

        -- Fetch both PR head and base refs so git show {sha}:{path} works.
        -- Without this, commits not in the local repo produce empty diff panes.
        local fetch_pending = 2
        local function on_fetch_done()
          fetch_pending = fetch_pending - 1
          if fetch_pending > 0 then return end

          -- Compute merge-base between base and head for correct PR diff.
          -- Using baseRefOid directly would compare against the tip of the
          -- target branch, showing unrelated changes merged into main since
          -- the PR was created. The merge-base is where the branches diverged.
          files_mod.merge_base(State.pr.base_sha, State.pr.head_sha, root, function(mb_err, merge_base_sha)
            if not mb_err and merge_base_sha then
              State.pr.base_sha = merge_base_sha
            end
            -- If merge-base fails, fall back to baseRefOid (better than nothing)

          -- Fire on_open callback (e.g. to close the PR picker loading state)
          if open_opts.on_open then open_opts.on_open() end
          -- Open the review layout: Snacks sidebar + diff windows
          require("gh-review.ui").open(pr, files, {
            start_idx = open_opts.start_idx,
            start_line = open_opts.start_line,
          })

          -- Fetch viewed states in background and populate local state
          files_mod.fetch_viewed_states(owner, name, pr_number, function(vs_err, result)
            if vs_err then
              vim.notify("gh-review: Could not fetch viewed states: " .. vs_err, vim.log.levels.WARN)
            elseif result then
              State.pr.node_id = result.pr_node_id
              State.review.viewed_files = result.viewed_files
              -- Refresh picker to reflect restored viewed indicators
              pcall(require("gh-review.ui.picker").refresh, State)
            end
          end)

          -- Fetch comments in background
          reviews_mod.fetch_threads(owner, name, pr_number, function(_, threads)
            State.review.threads = threads or {}
            local ok, comments_mod = pcall(require, "gh-review.ui.comments")
            if ok then comments_mod.render_all(threads or {}) end
          end)

          -- Fetch commits in background (enables commit review mode)
          local commits_mod = require("gh-review.gh.commits")
          commits_mod.list(owner, name, pr_number, function(_, commits)
            State.pr.commits = commits or {}
          end)
          end) -- merge_base
        end -- on_fetch_done

        -- Fetch PR head ref
        files_mod.fetch_ref("origin", "refs/pull/" .. pr_number .. "/head", root, function(fetch_err)
          if fetch_err then
            vim.notify("gh-review: git fetch warning (head): " .. fetch_err, vim.log.levels.WARN)
          end
          on_fetch_done()
        end)

        -- Fetch base branch so baseRefOid is available locally
        files_mod.fetch_ref("origin", pr.baseRefName, root, function(fetch_err)
          if fetch_err then
            vim.notify("gh-review: git fetch warning (base): " .. fetch_err, vim.log.levels.WARN)
          end
          on_fetch_done()
        end)
      end)
    end)
    end) -- git_root
  end)
end

function M.close()
  local state = require("gh-review.state").state
  -- Guard: nothing to close if no layout tab exists
  if not state.layout.tab then return end
  require("gh-review.ui.layout").close(state)
  require("gh-review.state").reset()
end

--- Jump from diff mode to editing the actual file at the cursor line.
--- Saves resume state so the review can be reopened later.
--- @param state table GhReviewState
function M.edit_file(state)
  local cur_win = vim.api.nvim_get_current_win()
  local line = vim.api.nvim_win_get_cursor(cur_win)[1]
  local file = state.pr.files[state.pr.current_idx]
  if not file then return end

  local root = state.repo.root
  if not root then
    vim.notify("gh-review: git root not available", vim.log.levels.WARN)
    return
  end

  local filepath = root .. "/" .. file.filename

  -- Deleted files don't exist on disk
  if file.status == "removed" then
    vim.notify("gh-review: " .. file.filename .. " was deleted in this PR", vim.log.levels.WARN)
    return
  end

  -- Save resume info before closing (survives state.reset)
  M._resume = {
    pr_number = state.pr.number,
    file_idx  = state.pr.current_idx,
    line      = line,
  }

  -- Close the review
  M.close()

  -- Schedule the edit so the tab close fully settles first
  vim.schedule(function()
    vim.cmd("edit " .. vim.fn.fnameescape(filepath))
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
    vim.notify("gh-review: Editing " .. file.filename .. " — use <leader>ppr to resume review", vim.log.levels.INFO)
  end)
end

--- Resume a previously suspended PR review.
function M.resume_pr()
  if not M._resume then
    vim.notify("gh-review: No PR review to resume", vim.log.levels.WARN)
    return
  end
  local pr_number = M._resume.pr_number
  local file_idx  = M._resume.file_idx
  local line      = M._resume.line
  M._resume = nil
  M.open_pr(pr_number, { start_idx = file_idx, start_line = line })
end

--- Open a Snacks picker to browse and select PRs for the current repo.
function M.open_dash()
  if not M._initialized then M.setup({}) end

  local repo_mod  = require("gh-review.gh.repo")
  local prs_mod   = require("gh-review.gh.prs")
  local pr_picker = require("gh-review.ui.pr_picker")

  -- Open the picker immediately in a loading state so the window appears at once
  local picker = pr_picker.open(nil, { title = "PRs — loading…" })

  repo_mod.detect(nil, function(err, owner, name)
    if err then
      vim.notify("gh-review: " .. err, vim.log.levels.ERROR)
      vim.schedule(function()
        if picker and not picker.closed then picker:close() end
      end)
      return
    end

    prs_mod.list(owner, name, nil, function(err2, prs)
      if err2 then
        vim.notify("gh-review: " .. err2, vim.log.levels.ERROR)
        vim.schedule(function()
          if picker and not picker.closed then picker:close() end
        end)
        return
      end

      if not prs or #prs == 0 then
        vim.notify("gh-review: No open PRs found.", vim.log.levels.INFO)
        vim.schedule(function()
          if picker and not picker.closed then picker:close() end
        end)
        return
      end

      vim.schedule(function()
        if picker and not picker.closed and picker.gh_update then
          picker.gh_update(prs, {
            title = string.format("PRs — %s/%s", owner, name),
            owner = owner,
            repo  = name,
          })
        end
      end)
    end)
  end)
end

return M
