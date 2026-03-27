local M = {}

-- Track active job handles so we can cancel them all if needed
local _active = {}

local function _remove_handle(h)
  for i, v in ipairs(_active) do
    if v == h then
      table.remove(_active, i)
      return
    end
  end
end

-- ---------------------------------------------------------------------------
-- Config helpers
-- ---------------------------------------------------------------------------

local function ai_cfg()
  local ok, main = pcall(require, "gh-review")
  if not ok then return {} end
  return (main.config and main.config.ai) or {}
end

--- @return string
local function model(kind)
  local cfg = ai_cfg()
  if kind == "analysis" then
    return cfg.analysis_model or "claude-sonnet-4-6"
  end
  return cfg.model or "claude-haiku-4-5-20251001"
end

--- Return shared client opts (api key + base_url + format + streaming).
--- @return table
local function client_opts()
  local cfg = ai_cfg()
  local out = {
    base_url  = cfg.base_url,
    format    = cfg.format,
    streaming = cfg.streaming,
  }
  if cfg.api_key and cfg.api_key ~= "" then
    out.api_key = cfg.api_key
  else
    out.api_key_env = cfg.api_key_env or "ANTHROPIC_API_KEY"
  end
  return out
end

-- ---------------------------------------------------------------------------
-- UI helpers
-- ---------------------------------------------------------------------------

--- Severity configuration: sign column char + highlight groups.
local SEV = {
  critical   = { sign = "!", hl = "DiagnosticError", sign_hl = "DiagnosticSignError" },
  warning    = { sign = "~", hl = "DiagnosticWarn",  sign_hl = "DiagnosticSignWarn"  },
  suggestion = { sign = "?", hl = "DiagnosticHint",  sign_hl = "DiagnosticSignHint"  },
}

local scrollbind = require("gh-review.ui.scrollbind")

--- Open a centered floating window for streaming AI output.
--- Returns the append_text() function for streaming content into the float.
local function open_streaming_float(title, height, state)
  scrollbind.disable(state)

  local width  = math.min(84, math.max(50, math.floor(vim.o.columns * 0.56)))
  height       = height or math.max(10, math.floor(vim.o.lines * 0.38))
  local row    = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col    = math.max(0, math.floor((vim.o.columns - width) / 2))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype",   "nofile",   { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe",     { buf = buf })
  vim.api.nvim_set_option_value("swapfile",  false,      { buf = buf })
  vim.api.nvim_set_option_value("filetype",  "markdown", { buf = buf })

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = row, col = col,
    width     = width, height = height,
    border    = "rounded",
    style     = "minimal",
    title     = " " .. title .. " ",
    title_pos = "center",
    zindex    = 55,
  })
  vim.api.nvim_set_option_value("wrap",      true,  { win = win })
  vim.api.nvim_set_option_value("linebreak", true,  { win = win })
  vim.api.nvim_set_option_value("scrollbind", false, { win = win })
  vim.api.nvim_set_option_value("cursorbind", false, { win = win })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  local accumulated = ""
  local ns_loading  = vim.api.nvim_create_namespace("gh_review_float_loading")

  -- Show a loading placeholder until the first chunk arrives
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_buf_set_extmark(buf, ns_loading, 0, 0, {
    virt_text     = { { "  waiting for response…", "Comment" } },
    virt_text_pos = "overlay",
  })

  local function append_text(text)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    -- Clear loading indicator on first chunk
    vim.api.nvim_buf_clear_namespace(buf, ns_loading, 0, -1)
    accumulated = accumulated .. text
    local lines = vim.split(accumulated, "\n", { plain = true })
    vim.api.nvim_set_option_value("modifiable", true,  { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_cursor, win, { #lines, 0 })
    end
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    vim.schedule(function() scrollbind.reenable(state) end)
  end

  local o = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q",     close, o)
  vim.keymap.set("n", "<Esc>", close, o)
  vim.keymap.set("n", "<C-a>", function()
    vim.fn.setreg("+", accumulated)
    vim.notify("gh-review AI: copied to clipboard", vim.log.levels.INFO)
  end, o)

  return append_text
end

--- Show an EOL loading indicator. Returns a cancel function.
local function show_loading(buf, ns, text)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return function() end end
  local id = vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_text     = { { "  " .. text, "Comment" } },
    virt_text_pos = "eol",
    priority      = 100,
  })
  return function()
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_del_extmark, buf, ns, id)
    end
  end
end

--- Word-wrap text to fit within a given display width.
--- Returns a list of lines, each no longer than `width` columns.
local function wrap_text(text, width)
  local lines = {}
  local current = ""
  for word in (text or ""):gmatch("%S+") do
    if current == "" then
      current = word
    elseif #current + 1 + #word <= width then
      current = current .. " " .. word
    else
      table.insert(lines, current)
      current = word
    end
  end
  if current ~= "" then table.insert(lines, current) end
  return #lines > 0 and lines or { "" }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Explain visual selection or current line.
--- Opens a streaming floating window with Claude's explanation.
--- @param state GhReviewState
--- @param buf integer  the diff buffer the cursor is in
function M.explain_selection(state, buf)
  local client  = require("gh-review.ai.client")
  local prompts = require("gh-review.ai.prompts")

  -- Get the live visual selection (line("v") = anchor, line(".") = cursor).
  -- In normal mode both return the cursor line, so this works for both modes.
  local v_start = vim.fn.line("v")
  local v_end   = vim.fn.line(".")
  if v_start > v_end then v_start, v_end = v_end, v_start end

  -- Exit visual mode if active
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  end

  local selected = vim.api.nvim_buf_get_lines(buf, v_start - 1, v_end, false)

  if #selected == 0 then
    vim.notify("gh-review AI: nothing selected", vim.log.levels.WARN)
    return
  end

  -- Surrounding context ±10 lines
  local ctx_s = math.max(0, v_start - 11)
  local ctx_e = math.min(vim.api.nvim_buf_line_count(buf), v_end + 10)
  local surrounding = vim.api.nvim_buf_get_lines(buf, ctx_s, ctx_e, false)

  local file = state.pr.files[state.pr.current_idx]
  if not file then
    vim.notify("gh-review AI: no file loaded", vim.log.levels.WARN)
    return
  end

  local user_msg = prompts.explain_context(file, selected, surrounding, state)
  local append = open_streaming_float("AI Explanation   q=close   C-a=copy", 20, state)

  local opts = client_opts()
  local h = client.stream({
    model       = model("fast"),
    system      = prompts.EXPLAINER_SYSTEM,
    messages    = { { role = "user", content = user_msg } },
    api_key_env = opts.api_key_env,
    api_key     = opts.api_key,
    base_url    = opts.base_url,
    format      = opts.format,
    streaming   = opts.streaming,
  }, append, function()
    _remove_handle(h)
  end, function(err)
    _remove_handle(h)
    vim.notify("gh-review AI: " .. err, vim.log.levels.ERROR)
  end)
  table.insert(_active, h)
end

--- Analyze the current file diff for bugs, security issues, and performance problems.
--- Results are rendered as virt_lines in the diff buffers using the ai_findings namespace.
--- @param state GhReviewState
function M.analyze_file(state)
  local client  = require("gh-review.ai.client")
  local prompts = require("gh-review.ai.prompts")

  local file = state.pr.files[state.pr.current_idx]
  if not file then
    vim.notify("gh-review AI: no file loaded", vim.log.levels.WARN)
    return
  end

  local left_buf  = state.layout.left_buf
  local right_buf = state.layout.right_buf
  if not left_buf or not right_buf then
    vim.notify("gh-review AI: diff buffers not ready", vim.log.levels.WARN)
    return
  end

  local base_lines = vim.api.nvim_buf_get_lines(left_buf,  0, -1, false)
  local head_lines = vim.api.nvim_buf_get_lines(right_buf, 0, -1, false)

  -- Existing threads on this file (for dedup in prompt)
  local file_threads = {}
  for _, t in ipairs(state.review.threads or {}) do
    if t.path == file.filename then table.insert(file_threads, t) end
  end

  local ns = state.ns.ai_findings
  local cancel_loading = show_loading(right_buf, ns, "AI: analyzing " .. file.filename .. "…")
  vim.notify("gh-review AI: analyzing " .. file.filename .. "…", vim.log.levels.INFO)

  local user_msg = prompts.analyze_context(file, base_lines, head_lines, file_threads)

  local opts = client_opts()
  local h = client.request({
    model       = model("analysis"),
    system      = prompts.REVIEWER_SYSTEM,
    messages    = { { role = "user", content = user_msg } },
    tools       = { prompts.ANALYZE_TOOL },
    api_key_env = opts.api_key_env,
    api_key     = opts.api_key,
    base_url    = opts.base_url,
    format      = opts.format,
    streaming   = opts.streaming,
  }, function(err, result)
    cancel_loading()
    _remove_handle(h)

    if err then
      vim.notify("gh-review AI: " .. err, vim.log.levels.ERROR)
      return
    end

    if result.type ~= "tool_use" or result.name ~= "submit_findings" then
      vim.notify("gh-review AI: unexpected response (expected tool use)", vim.log.levels.WARN)
      return
    end

    local input    = result.input or {}
    local findings = input.findings or {}
    local summary  = input.summary or ""

    if #findings == 0 then
      local suffix = summary ~= "" and (" — " .. summary) or ""
      vim.notify("gh-review AI: no issues found" .. suffix, vim.log.levels.INFO)
      return
    end

    M._render_findings(state, file, findings, summary, base_lines, head_lines)
    vim.notify(
      string.format("gh-review AI: %d finding(s) in %s  (<leader>ad to dismiss)", #findings, file.filename),
      vim.log.levels.INFO
    )
  end)
  table.insert(_active, h)
end

--- Render AI findings as virt_lines in the diff buffers.
--- Uses state.ns.ai_findings namespace (separate from human comments).
--- @param state GhReviewState
--- @param file GhFile
--- @param findings table[]
--- @param summary string
--- @param base_lines string[]
--- @param head_lines string[]
function M._render_findings(state, file, findings, summary, base_lines, head_lines)
  local ns        = state.ns.ai_findings
  local left_buf  = state.layout.left_buf
  local right_buf = state.layout.right_buf
  if not ns then return end

  -- Clear previous AI findings
  if left_buf  and vim.api.nvim_buf_is_valid(left_buf)  then
    vim.api.nvim_buf_clear_namespace(left_buf,  ns, 0, -1)
  end
  if right_buf and vim.api.nvim_buf_is_valid(right_buf) then
    vim.api.nvim_buf_clear_namespace(right_buf, ns, 0, -1)
  end

  local idx = 0
  for _, finding in ipairs(findings) do
    local buf       = (finding.side == "LEFT") and left_buf or right_buf
    local lines_ref = (finding.side == "LEFT") and base_lines or head_lines
    if not buf or not vim.api.nvim_buf_is_valid(buf) then goto continue end

    idx = idx + 1
    local row = math.max(0, math.min((finding.line or 1) - 1, #lines_ref - 1))
    local sc  = SEV[finding.severity] or SEV.suggestion

    -- Numbered prefix: "  1. ", "  2. ", etc.
    local prefix   = "  " .. idx .. ". "
    local cont_pad = string.rep(" ", #prefix)

    -- Compute available text width from the window showing this buffer
    local win        = vim.fn.bufwinid(buf)
    local win_width  = (win ~= -1) and vim.api.nvim_win_get_width(win) or 80
    local text_width = math.max(20, win_width - #prefix - 4)

    -- Word-wrap body into numbered list virt_lines
    local body_lines = wrap_text(finding.body, text_width)
    local vlines = {}
    for i, line in ipairs(body_lines) do
      if i == 1 then
        table.insert(vlines, { { prefix, sc.hl }, { line, sc.hl } })
      else
        table.insert(vlines, { { cont_pad, sc.hl }, { line, sc.hl } })
      end
    end

    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      virt_lines       = vlines,
      virt_lines_above = false,
    })

    -- Sign column: single char fits cleanly without truncation
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      sign_text     = sc.sign,
      sign_hl_group = sc.sign_hl,
      priority      = 15,
    })

    ::continue::
  end

  -- Summary as EOL text on line 1 of the PR buffer
  if summary ~= "" and right_buf and vim.api.nvim_buf_is_valid(right_buf) then
    vim.api.nvim_buf_set_extmark(right_buf, ns, 0, 0, {
      virt_text     = { { "  AI: " .. summary, "Comment" } },
      virt_text_pos = "eol",
      priority      = 5,
    })
  end
end

--- Dismiss all AI findings from the current diff buffers.
--- @param state GhReviewState
function M.dismiss(state)
  local ns = state.ns.ai_findings
  if not ns then return end
  for _, buf_key in ipairs({ "left_buf", "right_buf" }) do
    local buf = state.layout[buf_key]
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
  vim.notify("gh-review AI: findings dismissed", vim.log.levels.INFO)
end

--- Draft a review comment for the line under the cursor.
--- Streams a suggestion into a floating window; user can C-a to copy, then
--- switch to the comment float and paste.
--- @param state GhReviewState
--- @param buf integer  current diff buffer
function M.draft_comment(state, buf)
  local client  = require("gh-review.ai.client")
  local prompts = require("gh-review.ai.prompts")

  local file = state.pr.files[state.pr.current_idx]
  if not file then return end

  local cur_line  = vim.api.nvim_win_get_cursor(0)[1]
  local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local file_threads = {}
  for _, t in ipairs(state.review.threads or {}) do
    if t.path == file.filename then table.insert(file_threads, t) end
  end

  local user_msg = prompts.draft_comment_context(file, cur_line, buf_lines, file_threads)
  local append = open_streaming_float(
    "AI Draft Comment   q=close   C-a=copy",
    12,
    state
  )

  local opts = client_opts()
  local h = client.stream({
    model       = model("fast"),
    system      = prompts.COMMENTER_SYSTEM,
    messages    = { { role = "user", content = user_msg } },
    api_key_env = opts.api_key_env,
    api_key     = opts.api_key,
    base_url    = opts.base_url,
    format      = opts.format,
    streaming   = opts.streaming,
  }, append, function()
    _remove_handle(h)
  end, function(err)
    _remove_handle(h)
    vim.notify("gh-review AI: " .. err, vim.log.levels.ERROR)
  end)
  table.insert(_active, h)
end

--- Suggest a reply to the thread nearest to the cursor.
--- @param state GhReviewState
--- @param buf integer  current diff buffer
function M.reply_suggestion(state, buf)
  local client  = require("gh-review.ai.client")
  local prompts = require("gh-review.ai.prompts")

  local file = state.pr.files[state.pr.current_idx]
  if not file then return end

  local cur_line = vim.api.nvim_win_get_cursor(0)[1]

  -- Find closest thread on this file
  local best, best_dist = nil, math.huge
  for _, t in ipairs(state.review.threads or {}) do
    if t.path == file.filename then
      local t_line = t.line or t.original_line or 0
      local dist = math.abs(t_line - cur_line)
      if dist < best_dist then best, best_dist = t, dist end
    end
  end

  if not best then
    vim.notify("gh-review AI: no thread found on this file", vim.log.levels.WARN)
    return
  end
  if best_dist > 20 then
    vim.notify(
      string.format("gh-review AI: nearest thread is %d lines away — move cursor closer", best_dist),
      vim.log.levels.WARN
    )
    return
  end

  local user_msg = prompts.reply_context(best, file)
  local append = open_streaming_float("AI Reply Suggestion   q=close   C-a=copy", 10, state)

  local opts = client_opts()
  local h = client.stream({
    model       = model("fast"),
    system      = prompts.COMMENTER_SYSTEM,
    messages    = { { role = "user", content = user_msg } },
    api_key_env = opts.api_key_env,
    api_key     = opts.api_key,
    base_url    = opts.base_url,
    format      = opts.format,
    streaming   = opts.streaming,
  }, append, function()
    _remove_handle(h)
  end, function(err)
    _remove_handle(h)
    vim.notify("gh-review AI: " .. err, vim.log.levels.ERROR)
  end)
  table.insert(_active, h)
end

--- Generate a summary of the entire PR review.
--- Streams a 2-4 sentence summary into a floating window; C-a to copy into review body.
--- @param state GhReviewState
function M.review_summary(state)
  local client  = require("gh-review.ai.client")
  local prompts = require("gh-review.ai.prompts")

  local user_msg = prompts.summary_context(state)
  local append = open_streaming_float(
    "AI Review Summary   q=close   C-a=copy",
    14,
    state
  )

  local opts = client_opts()
  local h = client.stream({
    model       = model("fast"),
    system      = prompts.EXPLAINER_SYSTEM,
    messages    = { { role = "user", content = user_msg } },
    api_key_env = opts.api_key_env,
    api_key     = opts.api_key,
    base_url    = opts.base_url,
    format      = opts.format,
    streaming   = opts.streaming,
  }, append, function()
    _remove_handle(h)
  end, function(err)
    _remove_handle(h)
    vim.notify("gh-review AI: " .. err, vim.log.levels.ERROR)
  end)
  table.insert(_active, h)
end

--- Cancel all active AI requests.
function M.cancel_all()
  for _, h in ipairs(_active) do
    if h and h.cancel then pcall(h.cancel) end
  end
  _active = {}
  vim.notify("gh-review AI: cancelled all requests", vim.log.levels.INFO)
end

return M
