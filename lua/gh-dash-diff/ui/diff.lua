local M = {}

local BINARY_PLACEHOLDER = { "[Binary file — diff not available]" }
local LOADING_PLACEHOLDER = { "" }

--- Create a scratch buffer for diff display.
--- @param lines string[] File content lines
--- @param uri string Buffer name (e.g. "base://src/foo.lua")
--- @param filetype string Detected filetype for syntax highlighting
--- @param state GhDashDiffState
--- @return integer buf Buffer handle
local function create_diff_buf(lines, uri, filetype, state)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(buf, uri)
  vim.api.nvim_set_option_value("buftype",    "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden",  "wipe",   { buf = buf })
  vim.api.nvim_set_option_value("swapfile",   false,    { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false,    { buf = buf })
  if filetype and filetype ~= "" then
    vim.api.nvim_set_option_value("filetype", filetype, { buf = buf })
  end
  table.insert(state.layout.all_bufs, buf)
  return buf
end

--- Apply window display options suitable for a diff view.
--- @param win integer Window handle
local function set_win_opts(win)
  vim.wo[win].wrap        = false
  vim.wo[win].number      = true
  vim.wo[win].cursorline  = true
  vim.wo[win].foldmethod  = "diff"
  vim.wo[win].foldlevel   = 1
  vim.wo[win].scrollbind  = true
  vim.wo[win].cursorbind  = true
end

--- Clean up the current diff buffers (called before switching to a new file).
--- We don't delete old buffers here — they have bufhidden=wipe and will be
--- automatically wiped when replaced in the window by _apply_buffers.
--- Deleting them directly can close the windows they're displayed in.
--- @param state GhDashDiffState
function M.cleanup_current(state)
  -- Turn off diff mode in both windows
  for _, win_key in ipairs({ "left_win", "right_win" }) do
    local win = state.layout[win_key]
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        pcall(vim.cmd, "diffoff")
      end)
    end
  end
  state.layout.left_buf = nil
  state.layout.right_buf = nil
end

--- Set buffer-local keymaps on a diff buffer.
--- All keymaps are buffer-local to avoid polluting global keymap space.
--- Modules are required lazily inside callbacks.
--- @param state GhDashDiffState
--- @param buf integer Buffer handle
function M.set_keymaps(state, buf)
  local cfg = require("gh-dash-diff").config.keymaps
  local function map(lhs, rhs, desc)
    if lhs == false then return end
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end

  -- File navigation
  map(cfg.next_file, function()
    require("gh-dash-diff.ui.navigation").next_file(state)
  end, "Next changed file")

  map(cfg.prev_file, function()
    require("gh-dash-diff.ui.navigation").prev_file(state)
  end, "Previous changed file")

  -- Comment navigation
  map(cfg.next_comment, function()
    require("gh-dash-diff.ui.comments").goto_next(buf)
  end, "Next comment")

  map(cfg.prev_comment, function()
    require("gh-dash-diff.ui.comments").goto_prev(buf)
  end, "Previous comment")

  -- Picker focus toggle
  map(cfg.toggle_picker, function()
    require("gh-dash-diff.ui.navigation").toggle_picker(state)
  end, "Toggle file picker focus")

  -- Comment actions
  map(cfg.add_comment, function()
    require("gh-dash-diff.ui.input").open_comment(state)
  end, "Add inline comment")

  map(cfg.add_single_comment, function()
    require("gh-dash-diff.ui.input").open_single_comment(state)
  end, "Post single comment immediately")

  map(cfg.reply_thread, function()
    require("gh-dash-diff.ui.input").reply_thread(state)
  end, "Reply to thread")

  map(cfg.delete_comment, function()
    require("gh-dash-diff.ui.input").delete_pending(state)
  end, "Delete pending comment")

  map(cfg.toggle_comments, function()
    require("gh-dash-diff.ui.comments").toggle(state)
  end, "Toggle comment visibility")

  -- Review submission
  map(cfg.submit_review, function()
    require("gh-dash-diff.ui.input").open_review_dialog(state)
  end, "Submit review")

  -- Close
  map(cfg.close, function()
    require("gh-dash-diff").close()
  end, "Close PR review")

  -- Refresh
  map(cfg.refresh, function()
    local main = require("gh-dash-diff")
    main.close()
    main.open_pr(state.pr.number)
  end, "Refresh PR data")

  -- Help
  map("?", function() M.show_help(state) end, "Show keybinding help")
end

--- Show a floating window listing all PR review keybindings.
--- Reads actual key values from config so user overrides are reflected.
--- @param state GhDashDiffState
function M.show_help(state)
  -- Save diff window + cursor so help close returns to the exact position
  local diff_win  = vim.api.nvim_get_current_win()
  local saved_pos = vim.api.nvim_win_get_cursor(diff_win)

  local cfg = require("gh-dash-diff").config.keymaps

  -- Helper to display a key, replacing false/nil with "(disabled)"
  local function k(key)
    if key == false or key == nil then return "(disabled)" end
    return tostring(key)
  end

  local lines = {
    "  PR Review — Keybindings",
    "  " .. string.rep("─", 34),
    "  Navigation",
    string.format("  %-16s  Next / prev file", k(cfg.next_file) .. " / " .. k(cfg.prev_file)),
    string.format("  %-16s  Next / prev hunk (built-in)", "]c / [c"),
    string.format("  %-16s  Next / prev comment", k(cfg.next_comment) .. " / " .. k(cfg.prev_comment)),
    string.format("  %-16s  Toggle file picker focus", k(cfg.toggle_picker)),
    "",
    "  Comments",
    string.format("  %-16s  Add inline comment (queued)", k(cfg.add_comment)),
    string.format("  %-16s  Post single comment (immediate)", k(cfg.add_single_comment)),
    string.format("  %-16s  Reply to thread (immediate)", k(cfg.reply_thread)),
    string.format("  %-16s  Toggle comment visibility", k(cfg.toggle_comments)),
    "",
    "  Review",
    string.format("  %-16s  Submit review", k(cfg.submit_review)),
    "",
    "  General",
    string.format("  %-16s  Close PR review", k(cfg.close)),
    string.format("  %-16s  Refresh PR data", k(cfg.refresh)),
    string.format("  %-16s  This help", "?"),
    "",
    "  Press q or <Esc> to close",
  }

  local width  = 52
  local height = #lines
  local row    = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col    = math.max(0, math.floor((vim.o.columns - width) / 2))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
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
    title     = " PR Review Help ",
    title_pos = "center",
    zindex    = 60,
  })
  vim.api.nvim_set_option_value("cursorline", false, { win = win })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(diff_win) then
        vim.api.nvim_set_current_win(diff_win)
        pcall(vim.api.nvim_win_set_cursor, diff_win, saved_pos)
      end
    end)
  end

  local o = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q",     close, o)
  vim.keymap.set("n", "<Esc>", close, o)
end

--- Load a file's diff into the side-by-side windows.
--- Fetches base and PR content via git show in parallel, creates scratch
--- buffers, enables diff mode, and sets buffer-local keymaps.
--- @param state GhDashDiffState
--- @param file GhFile
--- @param idx number 1-based index into state.pr.files
function M.load_file(state, file, idx)
  local files_mod = require("gh-dash-diff.gh.files")
  local root = state.repo.root

  if not root then
    vim.notify("gh-dash-diff: git root not set in state", vim.log.levels.ERROR)
    return
  end

  -- Use commit SHAs when available (immutable), fall back to branch refs
  local base_ref = state.pr.base_sha or state.pr.base_ref
  local head_ref = state.pr.head_sha or state.pr.head_ref

  -- Handle renames: base uses the old filename, head uses the new one
  local base_filename = file.previous_filename or file.filename
  local head_filename = file.filename

  -- Binary file: show placeholder on both sides immediately
  if files_mod.is_binary(file) then
    M._apply_buffers(state, file, BINARY_PLACEHOLDER, BINARY_PLACEHOLDER, idx)
    return
  end

  -- For added files, base is empty; for removed files, head is empty
  -- We still issue both fetches (they'll fail gracefully for missing refs)
  -- and override the result in _apply_buffers.
  local pending    = 2
  local base_lines = {}
  local head_lines = {}
  local had_error  = false

  local function on_done()
    pending = pending - 1
    if pending > 0 then return end
    if had_error then return end  -- error already notified

    -- Override content for added/removed files
    if file.status == "added" or file.status == "copied" then
      base_lines = {}
    end
    if file.status == "removed" then
      head_lines = {}
    end

    M._apply_buffers(state, file, base_lines, head_lines, idx)
  end

  -- Fetch base version (empty for added/copied files — skip to save a git call)
  if file.status == "added" or file.status == "copied" then
    pending = pending - 1
    base_lines = {}
    if pending == 0 then
      M._apply_buffers(state, file, base_lines, head_lines, idx)
    end
  else
    files_mod.get_content(base_ref, base_filename, root, function(err, lines)
      if err and file.status ~= "added" and file.status ~= "copied" then
        -- Non-fatal: could be a file that doesn't exist at base (edge case)
        base_lines = {}
      else
        base_lines = lines or {}
      end
      on_done()
    end)
  end

  -- Fetch head version (empty for removed files — skip the git call)
  if file.status == "removed" then
    pending = pending - 1
    head_lines = {}
    if pending == 0 then
      M._apply_buffers(state, file, base_lines, head_lines, idx)
    end
  else
    files_mod.get_content(head_ref, head_filename, root, function(err, lines)
      if err then
        head_lines = {}
      else
        head_lines = lines or {}
      end
      on_done()
    end)
  end
end

--- Internal: create/swap diff buffers and enable diff mode.
--- Separated from load_file so binary/loading paths can also use it.
--- @param state GhDashDiffState
--- @param file GhFile
--- @param base_lines string[]
--- @param head_lines string[]
--- @param idx number
function M._apply_buffers(state, file, base_lines, head_lines, idx)
  local base_filename = file.previous_filename or file.filename
  local head_filename = file.filename
  local ft = vim.filetype.match({ filename = file.filename }) or ""

  -- Config buffer name prefixes
  local cfg = require("gh-dash-diff").config
  local base_prefix = cfg.buf_prefix and cfg.buf_prefix.base or "base://"
  local pr_prefix   = cfg.buf_prefix and cfg.buf_prefix.pr   or "pr://"

  -- Unique URIs to avoid buffer name collisions across files
  local base_uri = base_prefix .. base_filename
  local pr_uri   = pr_prefix   .. head_filename

  -- Temporarily disable WinClosed guard during buffer swap
  -- (cleanup_current deletes buffers which can trigger spurious events)
  state.layout.ready = false

  -- Remove old diff buffers first
  M.cleanup_current(state)

  -- Create new scratch buffers
  state.layout.left_buf  = create_diff_buf(base_lines, base_uri, ft, state)
  state.layout.right_buf = create_diff_buf(head_lines, pr_uri,   ft, state)

  -- Load into windows and enable diff mode
  local left_win  = state.layout.left_win
  local right_win = state.layout.right_win

  if vim.api.nvim_win_is_valid(left_win) then
    vim.api.nvim_win_set_buf(left_win, state.layout.left_buf)
    vim.api.nvim_set_current_win(left_win)
    vim.cmd("diffthis")
    set_win_opts(left_win)
    vim.api.nvim_win_set_hl_ns(left_win, 0)
  end

  if vim.api.nvim_win_is_valid(right_win) then
    vim.api.nvim_win_set_buf(right_win, state.layout.right_buf)
    vim.api.nvim_set_current_win(right_win)
    vim.cmd("diffthis")
    set_win_opts(right_win)
  end

  -- Set buffer-local keymaps on both diff buffers
  M.set_keymaps(state, state.layout.left_buf)
  M.set_keymaps(state, state.layout.right_buf)

  -- Render any existing comments for this file
  local ok, comments_mod = pcall(require, "gh-dash-diff.ui.comments")
  if ok then comments_mod.render_for_file(state, file.filename) end

  -- Focus the right (PR) diff window
  if vim.api.nvim_win_is_valid(right_win) then
    vim.api.nvim_set_current_win(right_win)
  end

  -- Re-enable WinClosed guard
  state.layout.ready = true
end

return M
