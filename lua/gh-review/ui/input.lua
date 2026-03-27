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
  vim.api.nvim_set_option_value("wrap",       true,  { win = win })
  vim.api.nvim_set_option_value("linebreak",  true,  { win = win })
  vim.api.nvim_set_option_value("scrollbind", false, { win = win })
  vim.api.nvim_set_option_value("cursorbind", false, { win = win })
  return buf, win
end

--- Determine the diff side ("LEFT" or "RIGHT") for the current window.
--- @param state GhReviewState
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

--- Find all review threads within ±5 lines of the given file/line/side.
--- @param state GhReviewState
--- @param filepath string
--- @param line integer
--- @param side "LEFT"|"RIGHT"
--- @return GhThread[]
local function find_threads_near(state, filepath, line, side)
  local results = {}
  for _, thread in ipairs(state.review.threads or {}) do
    local same_file = (thread.path == filepath)
    local same_side = (thread.side == side or thread.side == nil)
    if same_file and same_side then
      local t_line = thread.line or thread.original_line or 0
      if math.abs(t_line - line) <= 5 then
        table.insert(results, thread)
      end
    end
  end
  return results
end

--- Find the closest review thread within ±5 lines of the given file/line/side.
--- Used by reply_thread() to locate the thread under the cursor.
--- @param state GhReviewState
--- @param filepath string
--- @param line integer
--- @param side "LEFT"|"RIGHT"
--- @return GhThread|nil
local function find_thread_near(state, filepath, line, side)
  local best, best_dist = nil, math.huge
  for _, thread in ipairs(find_threads_near(state, filepath, line, side)) do
    local t_line = thread.line or thread.original_line or 0
    local dist = math.abs(t_line - line)
    if dist < best_dist then
      best, best_dist = thread, dist
    end
  end
  return best
end

--- Restore cursor position in a window after a float closes.
--- @param win integer Diff window to restore focus/cursor in
--- @param pos integer[] {row, col} cursor position to restore
local function make_restore(win, pos)
  return function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      pcall(vim.api.nvim_win_set_cursor, win, pos)
    end
  end
end

local scrollbind = require("gh-review.ui.scrollbind")

--- Open a simple floating text-input window and call `callback(body)` on submit.
--- Keymaps:  <C-s> (any mode) or <CR> (normal) → submit; q / <Esc> (normal) → cancel.
--- @param title string Window title shown in border
--- @param callback fun(body: string)
--- @param after_close? fun() Optional callback run after the float closes (submit or cancel)
--- @param state? GhReviewState When provided, scrollbind is disabled while the float is open
local function open_input_float(title, callback, after_close, state)
  scrollbind.disable(state)

  local width  = math.min(64, math.max(40, vim.o.columns - 20))
  local height = 8
  local buf, win = _create_float({
    relative = "cursor",
    row      = 1,
    col      = 0,
    width    = width,
    height   = height,
    border   = "rounded",
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
    vim.schedule(function()
      if after_close then after_close() end
      scrollbind.reenable(state)
    end)
    if body ~= "" then callback(body) end
  end

  local function cancel()
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.schedule(function()
      if after_close then after_close() end
      scrollbind.reenable(state)
    end)
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
--- Capture the visual selection range, exit visual mode, and return start/end lines.
--- In normal mode returns nil (single-line comment on cursor line).
--- @return integer|nil start_line, integer|nil end_line
local function capture_visual_range()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil, nil
  end
  local v_start = vim.fn.line("v")
  local v_end   = vim.fn.line(".")
  if v_start > v_end then v_start, v_end = v_end, v_start end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  return v_start, v_end
end

--- The comment is stored as PENDING — not sent to GitHub until `open_review_dialog`.
--- @param state GhReviewState
function M.open_comment(state)
  local file = state.pr.files[state.pr.current_idx]
  if not file then
    vim.notify("gh-review: No file selected", vim.log.levels.WARN)
    return
  end

  -- Detect multi-line selection before anything else
  local sel_start, sel_end = capture_visual_range()

  -- Capture position before the float changes the current window
  local saved_win = vim.api.nvim_get_current_win()
  local saved_pos = vim.api.nvim_win_get_cursor(saved_win)
  local side = get_side(state)
  local line = sel_end or saved_pos[1]
  local start_line = sel_start and sel_start < line and sel_start or nil
  local path = comment_path(file, side)

  open_input_float(" Add Comment ", function(body)
    local pending = {
      path       = path,
      line       = line,
      side       = side,
      body       = body,
      start_line = start_line,
      start_side = start_line and side or nil,
      is_suggestion = false,
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    table.insert(state.review.pending_comments, pending)
    vim.notify(
      string.format("gh-review: Comment queued (%d pending)", #state.review.pending_comments),
      vim.log.levels.INFO
    )
    -- Ask comments module to refresh signs/EOL indicators if available
    local ok, cm = pcall(require, "gh-review.ui.comments")
    if ok then pcall(cm.update_pending, state) end
  end, make_restore(saved_win, saved_pos), state)
end

--- Open a floating window for a new standalone inline comment posted immediately.
--- Unlike open_comment, this posts directly to GitHub without going through a review.
--- @param state GhReviewState
function M.open_single_comment(state)
  local file = state.pr.files[state.pr.current_idx]
  if not file then
    vim.notify("gh-review: No file selected", vim.log.levels.WARN)
    return
  end

  local head_sha = state.pr.head_sha
  if not head_sha then
    vim.notify("gh-review: No commit SHA available", vim.log.levels.WARN)
    return
  end

  -- Detect multi-line selection before anything else
  local sel_start, sel_end = capture_visual_range()

  -- Capture position before the float changes the current window
  local saved_win = vim.api.nvim_get_current_win()
  local saved_pos = vim.api.nvim_win_get_cursor(saved_win)
  local side = get_side(state)
  local line = sel_end or saved_pos[1]
  local start_line = sel_start and sel_start < line and sel_start or nil
  local path = comment_path(file, side)

  open_input_float(" Post Comment (immediate) ", function(body)
    local reviews = require("gh-review.gh.reviews")
    local owner   = state.repo.owner
    local repo    = state.repo.name

    reviews.create_single_comment(owner, repo, state.pr.number, {
      commit_sha = head_sha,
      path       = path,
      line       = line,
      side       = side,
      body       = body,
      start_line = start_line,
      start_side = start_line and side or nil,
    }, function(err, _)
      if err then
        vim.notify("gh-review: Comment failed: " .. err, vim.log.levels.ERROR)
        return
      end
      vim.notify("gh-review: Comment posted", vim.log.levels.INFO)
      -- Refresh threads and re-render comments for current file
      reviews.fetch_threads(owner, repo, state.pr.number, function(_, threads)
        if not threads then return end
        state.review.threads = threads
        local ok, cm = pcall(require, "gh-review.ui.comments")
        if ok then pcall(cm.render_for_file, state, file.filename) end
      end)
    end)
  end, make_restore(saved_win, saved_pos), state)
end

--- Open a floating window for replying to a review thread near the cursor.
--- Replies are sent IMMEDIATELY to GitHub (not queued as pending).
--- When multiple threads exist near the cursor, shows a selection dialog first.
--- @param state GhReviewState
function M.reply_thread(state)
  local file = state.pr.files[state.pr.current_idx]
  if not file then
    vim.notify("gh-review: No file selected", vim.log.levels.WARN)
    return
  end

  local saved_win = vim.api.nvim_get_current_win()
  local saved_pos = vim.api.nvim_win_get_cursor(saved_win)
  local side    = get_side(state)
  local line    = saved_pos[1]
  local path    = comment_path(file, side)
  local threads = find_threads_near(state, path, line, side)

  if #threads == 0 then
    vim.notify("gh-review: No thread found near cursor", vim.log.levels.WARN)
    return
  end

  --- Open the reply input float for a specific thread.
  --- @param thread GhThread
  local function open_reply_for(thread)
    local root_comment = thread.comments and thread.comments[1]
    if not root_comment then
      vim.notify("gh-review: Thread has no comments", vim.log.levels.WARN)
      return
    end

    open_input_float(" Reply to Thread ", function(body)
      local reviews = require("gh-review.gh.reviews")
      local owner   = state.repo.owner
      local repo    = state.repo.name

      reviews.reply_to_comment(owner, repo, state.pr.number, root_comment.id, body,
        function(err, _)
          if err then
            vim.notify("gh-review: Reply failed: " .. err, vim.log.levels.ERROR)
            return
          end
          vim.notify("gh-review: Reply posted", vim.log.levels.INFO)
          -- Refresh threads and re-render comments for current file
          reviews.fetch_threads(owner, repo, state.pr.number, function(_, updated)
            if not updated then return end
            state.review.threads = updated
            local ok, cm = pcall(require, "gh-review.ui.comments")
            if ok then pcall(cm.render_for_file, state, file.filename) end
          end)
        end
      )
    end, make_restore(saved_win, saved_pos), state)
  end

  -- Only one thread — reply directly without a dialog
  if #threads == 1 then
    open_reply_for(threads[1])
    return
  end

  -- Multiple threads — show numbered selection dialog
  local diff_win = saved_win

  -- Build dialog lines with a preview of the first comment per thread
  local lines = { "  Reply to thread:", "" }
  for i, t in ipairs(threads) do
    local first = t.comments and t.comments[1]
    local author  = first and first.user and first.user.login or "unknown"
    local preview = first and (first.body or "") or ""
    preview = preview:gsub("\n", " ")
    if #preview > 40 then preview = preview:sub(1, 40) .. "…" end
    local t_line = t.line or t.original_line or 0
    table.insert(lines, string.format("  %d.  line %d  @%s: %s", i, t_line, author, preview))
  end
  table.insert(lines, "")
  table.insert(lines, "  Press 1-9 to select  |  q/<Esc> to cancel")

  local width  = math.min(80, math.max(50, vim.o.columns - 10))
  local height = #lines
  local row    = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col    = math.max(0, math.floor((vim.o.columns - width) / 2))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("buftype",    "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden",  "wipe",   { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false,    { buf = buf })

  scrollbind.disable(state)
  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = row,
    col       = col,
    width     = width,
    height    = height,
    border    = "rounded",
    style     = "minimal",
    title     = " Reply to Thread ",
    title_pos = "center",
    zindex    = 60,
  })
  vim.api.nvim_set_option_value("scrollbind", false, { win = win })
  vim.api.nvim_set_option_value("cursorbind", false, { win = win })

  -- `and_reenable`: true when closing to cancel (no follow-up float),
  -- false when closing to open the reply input float (which manages scrollbind itself).
  local function close_dialog(and_reenable)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.schedule(function()
      make_restore(diff_win, saved_pos)()
      if and_reenable then scrollbind.reenable(state) end
    end)
  end

  local o = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q",     function() close_dialog(true) end, o)
  vim.keymap.set("n", "<Esc>", function() close_dialog(true) end, o)

  for i = 1, math.min(#threads, 9) do
    vim.keymap.set("n", tostring(i), function()
      close_dialog(false)
      open_reply_for(threads[i])
    end, o)
  end
end

--- Delete a pending or posted comment on the current file.
--- Pending comments are removed from local state; posted comments are deleted via API.
--- Only posted comments authored by the current user are shown.
--- Shows a numbered selection dialog when multiple candidates exist.
--- @param state GhReviewState
function M.delete_pending(state)
  local file = state.pr.files[state.pr.current_idx]
  if not file then
    vim.notify("gh-review: No file selected", vim.log.levels.WARN)
    return
  end

  local reviews = require("gh-review.gh.reviews")

  reviews.get_authenticated_user(function(auth_err, current_login)
    if auth_err then
      vim.notify("gh-review: Could not get current user: " .. auth_err, vim.log.levels.WARN)
    end

    -- Collect pending comments for the current file
    local candidates = {}
    for _, pc in ipairs(state.review.pending_comments or {}) do
      if pc.path == file.filename
        or (file.previous_filename and pc.path == file.previous_filename) then
        local preview = (pc.body or ""):gsub("\n", " ")
        if #preview > 40 then preview = preview:sub(1, 40) .. "…" end
        table.insert(candidates, {
          kind    = "pending",
          label   = string.format("[PENDING] line %d: %s", pc.line or 0, preview),
          pc      = pc,
        })
      end
    end

    -- Collect posted comments authored by the current user on this file
    if current_login then
      for _, thread in ipairs(state.review.threads or {}) do
        local same_file = (thread.path == file.filename)
          or (file.previous_filename and thread.path == file.previous_filename)
        if same_file then
          for _, comment in ipairs(thread.comments or {}) do
            local author = comment.user and comment.user.login
            if author == current_login then
              local preview = (comment.body or ""):gsub("\n", " ")
              if #preview > 40 then preview = preview:sub(1, 40) .. "…" end
              table.insert(candidates, {
                kind    = "posted",
                label   = string.format("[POSTED @%s] line %d: %s",
                  author, comment.line or comment.original_line or 0, preview),
                comment = comment,
              })
            end
          end
        end
      end
    end

    if #candidates == 0 then
      vim.notify("gh-review: No deletable comments on this file", vim.log.levels.WARN)
      return
    end

    local function do_delete(candidate)
      if candidate.kind == "pending" then
        for i, pc in ipairs(state.review.pending_comments) do
          if pc == candidate.pc then
            table.remove(state.review.pending_comments, i)
            break
          end
        end
        vim.notify(
          string.format("gh-review: Pending comment deleted (%d remaining)", #state.review.pending_comments),
          vim.log.levels.INFO
        )
        local ok, cm = pcall(require, "gh-review.ui.comments")
        if ok then pcall(cm.render_for_file, state, file.filename) end
      else
        local owner = state.repo.owner
        local repo  = state.repo.name
        reviews.delete_comment(owner, repo, state.pr.number, candidate.comment.id, function(del_err)
          if del_err then
            vim.notify("gh-review: Delete failed: " .. del_err, vim.log.levels.ERROR)
            return
          end
          vim.notify("gh-review: Comment deleted", vim.log.levels.INFO)
          reviews.fetch_threads(owner, repo, state.pr.number, function(_, threads)
            if not threads then return end
            state.review.threads = threads
            local ok, cm = pcall(require, "gh-review.ui.comments")
            if ok then pcall(cm.render_for_file, state, file.filename) end
          end)
        end)
      end
    end

    local function confirm_delete(candidate)
      vim.ui.select({ "Yes", "No" }, {
        prompt = "Delete comment? " .. candidate.label,
      }, function(choice)
        if choice == "Yes" then
          do_delete(candidate)
        end
      end)
    end

    -- Only one candidate — confirm and delete
    if #candidates == 1 then
      confirm_delete(candidates[1])
      return
    end

    -- Multiple candidates — show numbered selection dialog
    local diff_win = vim.api.nvim_get_current_win()
    local saved_pos = vim.api.nvim_win_get_cursor(diff_win)

    local lines = { "  Delete comment:", "" }
    for i, c in ipairs(candidates) do
      table.insert(lines, string.format("  %d.  %s", i, c.label))
    end
    table.insert(lines, "")
    table.insert(lines, "  Press 1-9 to delete  |  q/<Esc> to cancel")

    local width  = math.min(80, math.max(50, vim.o.columns - 10))
    local height = #lines
    local row    = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
    local col    = math.max(0, math.floor((vim.o.columns - width) / 2))

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("buftype",    "nofile", { buf = buf })
    vim.api.nvim_set_option_value("bufhidden",  "wipe",   { buf = buf })
    vim.api.nvim_set_option_value("modifiable", false,    { buf = buf })

    scrollbind.disable(state)
    local win = vim.api.nvim_open_win(buf, true, {
      relative  = "editor",
      row       = row,
      col       = col,
      width     = width,
      height    = height,
      border    = "rounded",
      style     = "minimal",
      title     = " Delete Comment ",
      title_pos = "center",
      zindex    = 60,
    })
    vim.api.nvim_set_option_value("scrollbind", false, { win = win })
    vim.api.nvim_set_option_value("cursorbind", false, { win = win })

    local function close_dialog()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      vim.schedule(function()
        make_restore(diff_win, saved_pos)()
        scrollbind.reenable(state)
      end)
    end

    local o = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("n", "q",     close_dialog, o)
    vim.keymap.set("n", "<Esc>", close_dialog, o)

    for i = 1, math.min(#candidates, 9) do
      vim.keymap.set("n", tostring(i), function()
        close_dialog()
        confirm_delete(candidates[i])
      end, o)
    end
  end)
end

--- Open a floating window pre-filled with a comment's body for editing.
--- Finds the comment under the cursor (by file path and line proximity),
--- then on submit calls update_comment and refreshes the view.
--- @param state GhReviewState
function M.edit_comment(state)
  local file = state.pr.files[state.pr.current_idx]
  if not file then
    vim.notify("gh-review: No file selected", vim.log.levels.WARN)
    return
  end

  local saved_win = vim.api.nvim_get_current_win()
  local saved_pos = vim.api.nvim_win_get_cursor(saved_win)
  local side      = get_side(state)
  local line      = saved_pos[1]
  local path      = comment_path(file, side)

  local reviews = require("gh-review.gh.reviews")

  -- Get current user so we only edit our own comments
  reviews.get_authenticated_user(function(auth_err, current_login)
    if auth_err then
      vim.notify("gh-review: Could not get current user: " .. auth_err, vim.log.levels.WARN)
    end

    -- Find candidate comments on this file near the cursor line
    local candidates = {}
    for _, thread in ipairs(state.review.threads or {}) do
      local same_file = (thread.path == path)
        or (file.previous_filename and thread.path == file.previous_filename)
      local same_side = (thread.side == side or thread.side == nil)
      if same_file and same_side then
        local t_line = thread.line or thread.original_line or 0
        if math.abs(t_line - line) <= 5 then
          for _, comment in ipairs(thread.comments or {}) do
            if not current_login or (comment.user and comment.user.login == current_login) then
              if comment.node_id then
                local preview = (comment.body or ""):gsub("\n", " ")
                if #preview > 40 then preview = preview:sub(1, 40) .. "…" end
                table.insert(candidates, {
                  comment = comment,
                  thread  = thread,
                  label   = string.format("line %d: %s", t_line, preview),
                })
              end
            end
          end
        end
      end
    end

    if #candidates == 0 then
      vim.notify("gh-review: No editable comment found near cursor", vim.log.levels.WARN)
      return
    end

    local function open_edit_for(candidate)
      local comment = candidate.comment
      scrollbind.disable(state)
      local buf, win = _create_float({
        relative = "cursor",
        row      = 1,
        col      = 0,
        width    = math.min(64, math.max(40, vim.o.columns - 20)),
        height   = 8,
        border   = "rounded",
        title    = " Edit Comment ",
        zindex   = 50,
      })

      -- Pre-fill with existing body
      local existing_lines = vim.split(comment.body or "", "\n", { plain = true })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, existing_lines)
      -- Place cursor at end of last line
      vim.api.nvim_win_set_cursor(win, { #existing_lines, #existing_lines[#existing_lines] })
      vim.cmd("startinsert!")

      local function submit()
        vim.cmd("stopinsert")
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local body  = vim.trim(table.concat(lines, "\n"))
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
        vim.schedule(function()
          make_restore(saved_win, saved_pos)()
          scrollbind.reenable(state)
        end)
        if body == "" then return end

        reviews.update_comment(comment.node_id, body, function(err)
          if err then
            vim.notify("gh-review: Edit failed: " .. err, vim.log.levels.ERROR)
            return
          end
          vim.notify("gh-review: Comment updated", vim.log.levels.INFO)
          -- Update body locally immediately, then refresh from API
          comment.body = body
          local ok, cm = pcall(require, "gh-review.ui.comments")
          if ok then pcall(cm.render_for_file, state, file.filename) end
          -- Refresh threads in background
          reviews.fetch_threads(state.repo.owner, state.repo.name, state.pr.number, function(_, threads)
            if not threads then return end
            state.review.threads = threads
            local ok2, cm2 = pcall(require, "gh-review.ui.comments")
            if ok2 then pcall(cm2.render_for_file, state, file.filename) end
          end)
        end)
      end

      local function cancel()
        vim.cmd("stopinsert")
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
        vim.schedule(function()
          make_restore(saved_win, saved_pos)()
          scrollbind.reenable(state)
        end)
      end

      local o = { buffer = buf, silent = true, nowait = true }
      vim.keymap.set({ "n", "i" }, "<C-s>", submit, o)
      vim.keymap.set("n",          "<CR>",  submit, o)
      vim.keymap.set("n",          "q",     cancel, o)
      vim.keymap.set("n",          "<Esc>", cancel, o)
    end

    if #candidates == 1 then
      open_edit_for(candidates[1])
      return
    end

    -- Multiple candidates — show selection dialog
    local diff_win = saved_win
    local lines = { "  Edit comment:", "" }
    for i, c in ipairs(candidates) do
      table.insert(lines, string.format("  %d.  %s", i, c.label))
    end
    table.insert(lines, "")
    table.insert(lines, "  Press 1-9 to select  |  q/<Esc> to cancel")

    local width  = math.min(80, math.max(50, vim.o.columns - 10))
    local height = #lines
    local row    = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
    local col    = math.max(0, math.floor((vim.o.columns - width) / 2))

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("buftype",    "nofile", { buf = buf })
    vim.api.nvim_set_option_value("bufhidden",  "wipe",   { buf = buf })
    vim.api.nvim_set_option_value("modifiable", false,    { buf = buf })

    scrollbind.disable(state)
    local win = vim.api.nvim_open_win(buf, true, {
      relative  = "editor",
      row       = row,
      col       = col,
      width     = width,
      height    = height,
      border    = "rounded",
      style     = "minimal",
      title     = " Edit Comment ",
      title_pos = "center",
      zindex    = 60,
    })
    vim.api.nvim_set_option_value("scrollbind", false, { win = win })
    vim.api.nvim_set_option_value("cursorbind", false, { win = win })

    -- `and_reenable`: true when cancelling (no follow-up float),
    -- false when opening the edit float (which manages scrollbind itself).
    local function close_dialog(and_reenable)
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      vim.schedule(function()
        make_restore(diff_win, saved_pos)()
        if and_reenable then scrollbind.reenable(state) end
      end)
    end

    local o = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("n", "q",     function() close_dialog(true) end, o)
    vim.keymap.set("n", "<Esc>", function() close_dialog(true) end, o)

    for i = 1, math.min(#candidates, 9) do
      vim.keymap.set("n", tostring(i), function()
        close_dialog(false)
        open_edit_for(candidates[i])
      end, o)
    end
  end)
end

--- Open the review submission dialog.
--- Shows pending comment count and event options; on confirm calls
--- `create_review_with_comments()` with all queued comments in a single API call.
--- @param state GhReviewState
function M.open_review_dialog(state)
  local owner    = state.repo.owner
  local repo     = state.repo.name
  local pr_number = state.pr.number
  local head_sha = state.pr.head_sha

  if not (owner and repo and pr_number) then
    vim.notify("gh-review: No active PR session", vim.log.levels.WARN)
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

  scrollbind.disable(state)
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
  vim.api.nvim_set_option_value("scrollbind", false, { win = win })
  vim.api.nvim_set_option_value("cursorbind", false, { win = win })
  vim.api.nvim_set_option_value("cursorline", true,  { win = win })

  -- Start cursor on first option
  vim.api.nvim_win_set_cursor(win, { option_start, 0 })

  local function close_dialog()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.schedule(function() scrollbind.reenable(state) end)
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

    local reviews = require("gh-review.gh.reviews")
    reviews.create_review_with_comments(owner, repo, pr_number, {
      commit_sha = head_sha,
      event      = opt.event,
      body       = "",
      comments   = api_comments,
    }, function(err, _)
      if err then
        vim.notify("gh-review: Review failed: " .. err, vim.log.levels.ERROR)
        return
      end
      state.review.pending_comments = {}
      vim.notify("gh-review: Review submitted!", vim.log.levels.INFO)

      -- Refresh threads and re-render current file's comments
      reviews.fetch_threads(owner, repo, pr_number, function(_, threads)
        if not threads then return end
        state.review.threads = threads
        local file = state.pr.files[state.pr.current_idx]
        local ok, cm = pcall(require, "gh-review.ui.comments")
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
