local M = {}

-- ---------------------------------------------------------------------------
-- Module-level session state (one active chat per plugin instance)
-- ---------------------------------------------------------------------------

local _history   = {}   -- {role="user"|"assistant", content="..."}[]
local _pr_number = nil  -- PR the current history belongs to
local _buf       = nil  -- integer|nil  — the chat display buffer
local _win       = nil  -- integer|nil  — the chat window
local _active    = nil  -- cancellable client handle
local _prev_win  = nil  -- window that had focus before the chat was opened

-- ---------------------------------------------------------------------------
-- Buffer helpers
-- ---------------------------------------------------------------------------

local function buf_valid()
  return _buf and vim.api.nvim_buf_is_valid(_buf)
      and _win and vim.api.nvim_win_is_valid(_win)
end

--- Append lines at the end of the chat buffer and scroll to bottom.
local function buf_append(lines)
  if not buf_valid() then return end
  vim.api.nvim_set_option_value("modifiable", true, { buf = _buf })
  local n = vim.api.nvim_buf_line_count(_buf)
  vim.api.nvim_buf_set_lines(_buf, n, n, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = _buf })
  pcall(vim.api.nvim_win_set_cursor, _win, { vim.api.nvim_buf_line_count(_buf), 0 })
end

--- Replace everything from line `from` (0-indexed) to end of buffer, then scroll.
local function buf_replace_tail(from, lines)
  if not buf_valid() then return end
  vim.api.nvim_set_option_value("modifiable", true, { buf = _buf })
  vim.api.nvim_buf_set_lines(_buf, from, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = _buf })
  pcall(vim.api.nvim_win_set_cursor, _win, { vim.api.nvim_buf_line_count(_buf), 0 })
end

local function init_buf()
  if not _buf or not vim.api.nvim_buf_is_valid(_buf) then return end
  vim.api.nvim_set_option_value("modifiable", true, { buf = _buf })
  vim.api.nvim_buf_set_lines(_buf, 0, -1, false, {
    "_i / <CR> = new message   q = close   C-a = copy last response   C-x = clear history_",
    "",
  })
  vim.api.nvim_set_option_value("modifiable", false, { buf = _buf })
end

--- Repopulate the buffer from the in-memory history (used when re-opening a window).
local function render_history()
  if not _buf or not vim.api.nvim_buf_is_valid(_buf) then return end
  vim.api.nvim_set_option_value("modifiable", true, { buf = _buf })
  local lines = {
    "_i / <CR> = new message   q = close   C-a = copy last response   C-x = clear history_",
    "",
  }
  for _, entry in ipairs(_history) do
    local heading = entry.role == "user" and "## You" or "## AI"
    vim.list_extend(lines, { heading, "" })
    vim.list_extend(lines, vim.split(entry.content, "\n", { plain = true }))
    vim.list_extend(lines, { "", "---", "" })
  end
  vim.api.nvim_buf_set_lines(_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = _buf })
  if _win and vim.api.nvim_win_is_valid(_win) then
    pcall(vim.api.nvim_win_set_cursor, _win, { vim.api.nvim_buf_line_count(_buf), 0 })
  end
end

-- ---------------------------------------------------------------------------
-- System prompt
-- ---------------------------------------------------------------------------

local function build_system(state)
  local pr = state.pr
  local parts = {
    "You are a helpful code review assistant embedded in a Neovim PR review tool.",
    "Answer questions about the pull request and its code changes clearly and concisely.",
    "",
    string.format("PR #%s: %s", pr.number or "?", pr.title or "(no title)"),
    string.format("Branch: %s → %s", pr.head_ref or "?", pr.base_ref or "?"),
  }
  local cur_file = pr.files and pr.files[pr.current_idx]
  if cur_file then
    table.insert(parts, string.format("Currently viewing: %s", cur_file.filename))
  end
  return table.concat(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- Send a message and stream the response into the chat buffer
-- ---------------------------------------------------------------------------

local function send_message(text, state)
  if text == "" then return end

  -- Add user turn to history
  table.insert(_history, { role = "user", content = text })

  -- Render user message into buffer.
  -- text may contain embedded newlines (e.g. when pre-filled from a visual selection),
  -- so split it into individual lines — nvim_buf_set_lines rejects strings with \n.
  local user_lines = { "## You", "" }
  vim.list_extend(user_lines, vim.split(text, "\n", { plain = true }))
  vim.list_extend(user_lines, { "", "---", "", "## AI", "" })
  buf_append(user_lines)

  -- Remember where the AI content will start (0-indexed line)
  local ai_content_start = buf_valid()
    and vim.api.nvim_buf_line_count(_buf)
    or 0

  -- Placeholder while waiting for the first chunk
  buf_append({ "  _thinking…_" })

  -- Cancel any in-flight request
  if _active then pcall(_active.cancel); _active = nil end

  local accumulated = ""
  local first_chunk = true

  local cfg = require("gh-review").config.ai or {}
  local client_opts = {
    model      = cfg.model or "claude-haiku-4-5-20251001",
    system     = build_system(state),
    messages   = _history,
    base_url   = cfg.base_url,
    format     = cfg.format,
    streaming  = cfg.streaming,
    max_tokens = cfg.max_tokens or 4096,
  }
  if cfg.api_key and cfg.api_key ~= "" then
    client_opts.api_key = cfg.api_key
  else
    client_opts.api_key_env = cfg.api_key_env or "ANTHROPIC_API_KEY"
  end

  local h = require("gh-review.ai.client").stream(
    client_opts,

    -- on_chunk: replace placeholder / accumulate streamed text
    function(chunk)
      accumulated = accumulated .. chunk
      first_chunk = false
      buf_replace_tail(ai_content_start, vim.split(accumulated, "\n", { plain = true }))
    end,

    -- on_done
    function()
      table.insert(_history, { role = "assistant", content = accumulated })
      buf_append({ "", "---", "" })
      _active = nil
    end,

    -- on_error
    function(err)
      if first_chunk then
        buf_replace_tail(ai_content_start, { "_Error: " .. err .. "_" })
      else
        buf_append({ "", "_Error: " .. err .. "_" })
      end
      buf_append({ "", "---", "" })
      -- Remove the failed user turn from history so history stays consistent
      if _history[#_history] and _history[#_history].role == "user" then
        table.remove(_history)
      end
      _active = nil
    end
  )
  _active = h
end

-- ---------------------------------------------------------------------------
-- Input overlay
-- ---------------------------------------------------------------------------

--- Open a small input float anchored to the bottom of the chat window.
--- @param state GhReviewState
--- @param prefill? string  Optional text to pre-populate the input with
local function open_input(state, prefill)
  if not buf_valid() then return end

  -- Read dimensions from the live window so this works from any call site
  local win_pos     = vim.api.nvim_win_get_position(_win)
  local win_cfg     = vim.api.nvim_win_get_config(_win)
  local chat_width  = win_cfg.width
  local chat_height = win_cfg.height
  local chat_row    = win_pos[1]
  local chat_col    = win_pos[2]

  local input_height = 4
  local input_buf    = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype",   "nofile", { buf = input_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe",   { buf = input_buf })
  vim.api.nvim_set_option_value("swapfile",  false,    { buf = input_buf })

  -- Prefer to sit just below the chat window; fall back to overlapping bottom
  local input_row = chat_row + chat_height + 1
  if input_row + input_height > vim.o.lines - 2 then
    input_row = math.max(0, chat_row + chat_height - input_height - 1)
  end

  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative  = "editor",
    row       = input_row,
    col       = chat_col,
    width     = chat_width,
    height    = input_height,
    border    = "rounded",
    style     = "minimal",
    title     = " Message   C-s / <CR> = send   <Esc> = cancel ",
    title_pos = "center",
    zindex    = 61,
  })
  vim.api.nvim_set_option_value("wrap",      true, { win = input_win })
  vim.api.nvim_set_option_value("linebreak", true, { win = input_win })

  -- Pre-fill with provided context and place cursor at the end
  if prefill and prefill ~= "" then
    local prefill_lines = vim.split(prefill, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, prefill_lines)
    pcall(vim.api.nvim_win_set_cursor, input_win,
      { #prefill_lines, #prefill_lines[#prefill_lines] })
    vim.cmd("startinsert!")
  else
    vim.cmd("startinsert")
  end

  local function submit()
    vim.cmd("stopinsert")
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    local msg   = vim.trim(table.concat(lines, "\n"))
    if vim.api.nvim_win_is_valid(input_win) then
      vim.api.nvim_win_close(input_win, true)
    end
    if _win and vim.api.nvim_win_is_valid(_win) then
      vim.api.nvim_set_current_win(_win)
    end
    if msg ~= "" then
      send_message(msg, state)
    end
  end

  local function cancel()
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(input_win) then
      vim.api.nvim_win_close(input_win, true)
    end
    if _win and vim.api.nvim_win_is_valid(_win) then
      vim.api.nvim_set_current_win(_win)
    end
  end

  local o = { buffer = input_buf, silent = true, nowait = true }
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, o)
  vim.keymap.set("n",          "<CR>",  submit, o)
  vim.keymap.set("n",          "q",     cancel, o)
  vim.keymap.set("n",          "<Esc>", cancel, o)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Open (or focus) the AI chat window.
--- History is automatically reset when a different PR is opened.
--- @param state GhReviewState
function M.open(state)
  local cfg = require("gh-review").config.ai or {}
  if not cfg.enabled then
    vim.notify("gh-review AI: set ai.enabled = true in your config", vim.log.levels.WARN)
    return
  end

  -- Reset history when switching PRs
  if state.pr.number and state.pr.number ~= _pr_number then
    _history   = {}
    _pr_number = state.pr.number
    if _active then pcall(_active.cancel); _active = nil end
    -- Close any stale window from the previous PR
    if _win and vim.api.nvim_win_is_valid(_win) then
      vim.api.nvim_win_close(_win, true)
    end
    _win = nil
    _buf = nil
  end

  -- If window already open, just focus it
  if buf_valid() then
    vim.api.nvim_set_current_win(_win)
    return
  end

  -- Remember where the user was so we can return focus there on close
  _prev_win = vim.api.nvim_get_current_win()

  -- Create the chat buffer
  _buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype",    "nofile",   { buf = _buf })
  vim.api.nvim_set_option_value("bufhidden",  "wipe",     { buf = _buf })
  vim.api.nvim_set_option_value("swapfile",   false,      { buf = _buf })
  vim.api.nvim_set_option_value("filetype",   "markdown", { buf = _buf })
  vim.api.nvim_set_option_value("modifiable", false,      { buf = _buf })

  local width  = math.min(90, math.max(60, math.floor(vim.o.columns * 0.60)))
  local height = math.max(16, math.floor(vim.o.lines * 0.52))
  local row    = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col    = math.max(0, math.floor((vim.o.columns - width) / 2))

  local pr    = state.pr
  local title = string.format(" AI Chat — PR #%s ", pr.number or "?")

  _win = vim.api.nvim_open_win(_buf, true, {
    relative  = "editor",
    row       = row, col = col,
    width     = width, height = height,
    border    = "rounded",
    style     = "minimal",
    title     = title,
    title_pos = "center",
    zindex    = 60,
  })
  vim.api.nvim_set_option_value("wrap",       true,  { win = _win })
  vim.api.nvim_set_option_value("linebreak",  true,  { win = _win })
  vim.api.nvim_set_option_value("scrollbind", false, { win = _win })
  vim.api.nvim_set_option_value("cursorbind", false, { win = _win })

  -- Suspend scrollbind/cursorbind on the diff windows while the chat is open.
  -- Without this, scrolling inside the float propagates to the diff windows.
  local scrollbind = require("gh-review.ui.scrollbind")
  scrollbind.disable(state)

  if #_history == 0 then
    init_buf()
  else
    render_history()
  end

  local function close()
    -- Restore diff window scroll bindings before closing
    scrollbind.reenable(state)
    if _win and vim.api.nvim_win_is_valid(_win) then
      vim.api.nvim_win_close(_win, true)
    end
    _win = nil
    _buf = nil
    -- Return focus to the window the user was in before opening the chat
    if _prev_win and vim.api.nvim_win_is_valid(_prev_win) then
      vim.api.nvim_set_current_win(_prev_win)
    end
    _prev_win = nil
  end

  local o = { buffer = _buf, silent = true, nowait = true }

  vim.keymap.set("n", "q",     close, o)
  vim.keymap.set("n", "<Esc>", close, o)

  vim.keymap.set("n", "i",    function() open_input(state) end, o)
  vim.keymap.set("n", "a",    function() open_input(state) end, o)
  vim.keymap.set("n", "<CR>", function() open_input(state) end, o)

  -- Copy last AI response to clipboard
  vim.keymap.set("n", "<C-a>", function()
    local last_ai = nil
    for i = #_history, 1, -1 do
      if _history[i].role == "assistant" then
        last_ai = _history[i].content
        break
      end
    end
    if last_ai then
      vim.fn.setreg("+", last_ai)
      vim.notify("gh-review AI: last response copied to clipboard", vim.log.levels.INFO)
    else
      vim.notify("gh-review AI: no response to copy yet", vim.log.levels.WARN)
    end
  end, o)

  -- Clear history and start fresh
  vim.keymap.set("n", "<C-x>", function()
    M.clear()
  end, o)
end

--- Open the AI chat pre-seeded with the current visual selection as context.
--- The selected lines are formatted as a fenced code block in the input float,
--- with the cursor placed after the closing fence so the user can type a question.
--- Falls back to a plain M.open() when no selection is active.
--- @param state GhReviewState
--- @param buf integer  The diff buffer the selection is in
function M.open_with_context(state, buf)
  -- Get the live visual selection boundaries (line("v") = anchor, line(".") = cursor)
  local v_start = vim.fn.line("v")
  local v_end   = vim.fn.line(".")
  if v_start > v_end then v_start, v_end = v_end, v_start end

  -- Exit visual mode so the selection is deactivated
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

  local sel_lines = vim.api.nvim_buf_get_lines(buf, v_start - 1, v_end, false)

  -- No selection — just open the chat normally
  if #sel_lines == 0 then
    M.open(state)
    return
  end

  -- Build a fenced code block for the prefill
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf }) or ""
  local parts = { "```" .. ft }
  vim.list_extend(parts, sel_lines)
  vim.list_extend(parts, { "```", "" })
  local prefill = table.concat(parts, "\n")

  -- nvim_open_win is synchronous, so _win is valid as soon as M.open returns
  M.open(state)
  open_input(state, prefill)
end

--- Clear the chat history and reset the buffer.
--- Useful for starting a fresh conversation without reopening the PR.
function M.clear()
  _history = {}
  if _active then pcall(_active.cancel); _active = nil end
  if _buf and vim.api.nvim_buf_is_valid(_buf) then
    init_buf()
  end
  vim.notify("gh-review AI: chat history cleared", vim.log.levels.INFO)
end

return M
