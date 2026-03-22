local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Create a floating scratch buffer + window.
--- @param opts {title?: string, width?: integer, height?: integer, relative?: string, row?: integer, col?: integer, border?: string, filetype?: string, zindex?: integer}
--- @return integer buf, integer win
local function _create_float(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype",   "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe",   { buf = buf })
  vim.api.nvim_set_option_value("swapfile",  false,    { buf = buf })
  if opts.filetype then
    vim.api.nvim_set_option_value("filetype", opts.filetype, { buf = buf })
  end

  local win_cfg = {
    relative  = opts.relative or "cursor",
    row       = opts.row or 1,
    col       = opts.col or 0,
    width     = opts.width or 60,
    height    = opts.height or 8,
    border    = opts.border or "rounded",
    style     = "minimal",
    zindex    = opts.zindex or 50,
  }
  if opts.title then
    win_cfg.title     = opts.title
    win_cfg.title_pos = "center"
  end

  local win = vim.api.nvim_open_win(buf, true, win_cfg)
  vim.api.nvim_set_option_value("wrap",      true,  { win = win })
  vim.api.nvim_set_option_value("linebreak", true,  { win = win })
  return buf, win
end

--- Determine the diff side ("LEFT" or "RIGHT") for the current window.
--- @param state GhDashDiffState
--- @return "LEFT"|"RIGHT"
local function get_side(state)
  return vim.api.nvim_get_current_win() == state.layout.left_win and "LEFT" or "RIGHT"
end

--- Resolve the file path for a comment, honouring renames.
--- GitHub expects the path of the file on the side the comment is on.
--- @param file GhFile
--- @param side "LEFT"|"RIGHT"
--- @return string path
local function comment_path(file, side)
  if side == "LEFT" and file.previous_filename then
    return file.previous_filename
  end
  return file.filename
end

--- Find a review thread close to the given file/line/side.
--- Used by reply_thread() to locate the thread under the cursor.
--- @param state GhDashDiffState
--- @param filepath string
--- @param line integer
--- @param side "LEFT"|"RIGHT"
--- @return GhThread|nil
local function find_thread_near(state, filepath, line, side)
  local best, best_dist = nil, math.huge
  for _, thread in ipairs(state.review.threads or {}) do
    local same_file = (thread.path == filepath)
    local same_side = (thread.side == side or thread.side == nil)
    if same_file and same_side then
      local t_line = thread.line or thread.original_line or 0
      local dist = math.abs(t_line - line)
      if dist < best_dist then
        best, best_dist = thread, dist
      end
    end
  end
  -- Accept threads within ±5 lines of cursor
  return (best_dist <= 5) and best or nil
end

--- Open a simple floating text-input window and call `callback(body)` on submit.
--- Keymaps:  <C-s> (any mode) or <CR> (normal) → submit; q / <Esc> (normal) → cancel.
--- @param title string Window title shown in border
--- @param callback fun(body: string)
local function open_input_float(title, callback)
  local width  = math.min(64, math.max(40, vim.o.columns - 20))
  local height = 8
  local buf, win = _create_float({
    relative = "cursor",
    row      = 1,
    col      = 0,
    width    = width,
    height   = height,
    border   = "rounded",
    filetype = "markdown",
    title    = title,
    zindex   = 50,
  })

  vim.cmd("startinsert")

  local function submit()
    -- Must be on main thread; stopinsert first to avoid cursor issues
    vim.cmd("stopinsert")
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local body  = vim.trim(table.concat(lines, "\n"))
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if body ~= "" then callback(body) end
  end

  local function cancel()
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local o = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, o)
  vim.keymap.set("n",          "<CR>",  submit, o)
  vim.keymap.set("n",          "q",     cancel, o)
  vim.keymap.set("n",          "<Esc>", cancel, o)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Open a floating window for a new inline comment on the current cursor line.
--- The comment is stored as PENDING — not sent to GitHub until `open_review_dialog`.
--- @param state GhDashDiffState
function M.open_comment(state)
  local file = state.pr.files[state.pr.current_idx]
  if not file then
    vim.notify("gh-dash-diff: No file selected", vim.log.levels.WARN)
    return
  end

  -- Capture position before the float changes the current window
  local side = get_side(state)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local path = comment_path(file, side)

  open_input_float(" Add Comment ", function(body)
    local pending = {
      path       = path,
      line       = line,
      side       = side,
      body       = body,
      is_suggestion = false,
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    table.insert(state.review.pending_comments, pending)
    vim.notify(
      string.format("gh-dash-diff: Comment queued (%d pending)", #state.review.pending_comments),
      vim.log.levels.INFO
    )
    -- Ask comments module to refresh signs/EOL indicators if available
    local ok, cm = pcall(require, "gh-dash-diff.ui.comments")
    if ok then pcall(cm.update_pending, state) end
  end)
end

--- Open a floating window for replying to a review thread near the cursor.
--- Replies are sent IMMEDIATELY to GitHub (not queued as pending).
--- @param state GhDashDiffState
function M.reply_thread(state)
  local file = state.pr.files[state.pr.current_idx]
  if not file then
    vim.notify("gh-dash-diff: No file selected", vim.log.levels.WARN)
    return
  end

  local side   = get_side(state)
  local line   = vim.api.nvim_win_get_cursor(0)[1]
  local path   = comment_path(file, side)
  local thread = find_thread_near(state, path, line, side)

  if not thread then
    vim.notify("gh-dash-diff: No thread found near cursor", vim.log.levels.WARN)
    return
  end

  local root_comment = thread.comments and thread.comments[1]
  if not root_comment then
    vim.notify("gh-dash-diff: Thread has no comments", vim.log.levels.WARN)
    return
  end

  open_input_float(" Reply to Thread ", function(body)
    local reviews = require("gh-dash-diff.gh.reviews")
    local owner   = state.repo.owner
    local repo    = state.repo.name

    reviews.reply_to_comment(owner, repo, state.pr.number, root_comment.id, body,
      function(err, _)
        if err then
          vim.notify("gh-dash-diff: Reply failed: " .. err, vim.log.levels.ERROR)
          return
        end
        vim.notify("gh-dash-diff: Reply posted", vim.log.levels.INFO)
        -- Refresh threads and re-render comments for current file
        reviews.fetch_threads(owner, repo, state.pr.number, function(_, threads)
          if not threads then return end
          state.review.threads = threads
          local ok, cm = pcall(require, "gh-dash-diff.ui.comments")
          if ok then pcall(cm.render_for_file, state, file.filename) end
        end)
      end
    )
  end)
end

--- Delete the pending comment nearest to the cursor on the current side.
--- Removes it from state.review.pending_comments and re-renders.
--- @param state GhDashDiffState
function M.delete_pending(state)
  local file = state.pr.files[state.pr.current_idx]
  if not file then
    vim.notify("gh-dash-diff: No file selected", vim.log.levels.WARN)
    return
  end

  local side = get_side(state)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local path = comment_path(file, side)

  -- Find the nearest pending comment within ±5 lines on this file+side
  local best_idx, best_dist = nil, math.huge
  for i, pc in ipairs(state.review.pending_comments or {}) do
    if pc.path == path and pc.side == side then
      local dist = math.abs((pc.line or 0) - line)
      if dist < best_dist then
        best_idx, best_dist = i, dist
      end
    end
  end

  if not best_idx or best_dist > 5 then
    vim.notify("gh-dash-diff: No pending comment near cursor", vim.log.levels.WARN)
    return
  end

  table.remove(state.review.pending_comments, best_idx)
  vim.notify(
    string.format("gh-dash-diff: Pending comment deleted (%d remaining)", #state.review.pending_comments),
    vim.log.levels.INFO
  )

  -- Re-render to clear the deleted comment's virt_lines
  local ok, cm = pcall(require, "gh-dash-diff.ui.comments")
  if ok then pcall(cm.render_for_file, state, file.filename) end
end

--- Open the review submission dialog.
--- Shows pending comment count and event options; on confirm calls
--- `create_review_with_comments()` with all queued comments in a single API call.
--- @param state GhDashDiffState
function M.open_review_dialog(state)
  local owner    = state.repo.owner
  local repo     = state.repo.name
  local pr_number = state.pr.number
  local head_sha = state.pr.head_sha

  if not (owner and repo and pr_number) then
    vim.notify("gh-dash-diff: No active PR session", vim.log.levels.WARN)
    return
  end

  local n_pending = #(state.review.pending_comments or {})

  -- Options table: label + GitHub event string (nil = cancel)
  local options = {
    { label = "  Comment only",    event = "COMMENT" },
    { label = "  Approve",         event = "APPROVE" },
    { label = "  Request Changes", event = "REQUEST_CHANGES" },
    { label = "  Cancel",          event = nil },
  }

  -- Build dialog lines
  local width    = 40
  local sep      = string.rep("─", width - 2)
  local header   = {
    "  Submit Review",
    sep,
    string.format("  %d pending comment%s", n_pending, n_pending == 1 and "" or "s"),
    "",
  }
  local all_lines = vim.deepcopy(header)
  local option_start = #all_lines + 1   -- 1-based line of first option
  for _, opt in ipairs(options) do
    table.insert(all_lines, opt.label)
  end

  local height = #all_lines + 1
  local row    = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col    = math.max(0, math.floor((vim.o.columns - width) / 2))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
  vim.api.nvim_set_option_value("buftype",    "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden",  "wipe",   { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false,    { buf = buf })

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = row,
    col       = col,
    width     = width,
    height    = height,
    border    = "rounded",
    style     = "minimal",
    title     = " Submit Review ",
    title_pos = "center",
    zindex    = 60,
  })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })

  -- Start cursor on first option
  vim.api.nvim_win_set_cursor(win, { option_start, 0 })

  local function close_dialog()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function confirm()
    local cur_line = vim.api.nvim_win_get_cursor(win)[1]
    local opt_idx  = cur_line - option_start + 1
    local opt      = options[opt_idx]
    close_dialog()

    if not opt or not opt.event then return end  -- Cancel selected

    -- Build API comment list from pending comments
    local api_comments = {}
    for _, pc in ipairs(state.review.pending_comments or {}) do
      table.insert(api_comments, {
        path = pc.path,
        line = pc.line,
        side = pc.side,
        body = pc.is_suggestion
          and ("```suggestion\n" .. pc.body .. "\n```")
          or pc.body,
      })
    end

    local reviews = require("gh-dash-diff.gh.reviews")
    reviews.create_review_with_comments(owner, repo, pr_number, {
      commit_sha = head_sha,
      event      = opt.event,
      body       = "",
      comments   = api_comments,
    }, function(err, _)
      if err then
        vim.notify("gh-dash-diff: Review failed: " .. err, vim.log.levels.ERROR)
        return
      end
      state.review.pending_comments = {}
      vim.notify("gh-dash-diff: Review submitted!", vim.log.levels.INFO)

      -- Refresh threads and re-render current file's comments
      reviews.fetch_threads(owner, repo, pr_number, function(_, threads)
        if not threads then return end
        state.review.threads = threads
        local file = state.pr.files[state.pr.current_idx]
        local ok, cm = pcall(require, "gh-dash-diff.ui.comments")
        if ok and file then pcall(cm.render_for_file, state, file.filename) end
      end)
    end)
  end

  -- Keymaps: navigation + confirm + cancel
  local o = { buffer = buf, silent = true, nowait = true }

  vim.keymap.set("n", "j", function()
    local cur = vim.api.nvim_win_get_cursor(win)[1]
    local max = option_start + #options - 1
    if cur < max then vim.api.nvim_win_set_cursor(win, { cur + 1, 0 }) end
  end, o)

  vim.keymap.set("n", "k", function()
    local cur = vim.api.nvim_win_get_cursor(win)[1]
    if cur > option_start then vim.api.nvim_win_set_cursor(win, { cur - 1, 0 }) end
  end, o)

  vim.keymap.set("n", "<CR>",  confirm,      o)
  vim.keymap.set("n", "q",     close_dialog, o)
  vim.keymap.set("n", "<Esc>", close_dialog, o)
end

return M
