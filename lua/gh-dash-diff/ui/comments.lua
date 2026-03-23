local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Format an ISO 8601 timestamp as a short relative string ("2h ago", "3d ago").
--- @param iso string  e.g. "2024-01-15T10:30:00Z"
--- @return string
local function relative_time(iso)
  if not iso then return "" end
  -- Parse: 2024-01-15T10:30:00Z
  local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return iso end
  local ts = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  })
  local diff = os.difftime(os.time(), ts)
  if diff < 60 then return "just now"
  elseif diff < 3600 then return math.floor(diff / 60) .. "m ago"
  elseif diff < 86400 then return math.floor(diff / 3600) .. "h ago"
  elseif diff < 86400 * 30 then return math.floor(diff / 86400) .. "d ago"
  else return math.floor(diff / (86400 * 30)) .. "mo ago"
  end
end

--- Build a separator line that fills ~60 chars.
local SEP = string.rep("─", 60)

--- Choose the target buffer for a thread based on its side.
--- @param state GhDashDiffState
--- @param side string "LEFT"|"RIGHT" (nil treated as "RIGHT")
--- @return integer|nil
local function buf_for_side(state, side)
  if side == "LEFT" then
    return state.layout.left_buf
  else
    return state.layout.right_buf
  end
end

--- Split text into lines no longer than max_width, breaking at word boundaries.
--- Hard-breaks when no space is found within max_width.
--- @param text string
--- @param max_width integer
--- @return string[]
local function wrap_line(text, max_width)
  if max_width <= 0 or #text <= max_width then return { text } end
  local result = {}
  local s = text
  while #s > max_width do
    local break_at = nil
    for i = max_width, 1, -1 do
      if s:sub(i, i) == " " then
        break_at = i
        break
      end
    end
    if break_at then
      table.insert(result, s:sub(1, break_at - 1))
      s = s:sub(break_at + 1)
    else
      -- Hard-break at max_width
      table.insert(result, s:sub(1, max_width))
      s = s:sub(max_width + 1)
    end
  end
  if #s > 0 then
    table.insert(result, s)
  end
  return result
end

--- Parse a single line into {text, hl} chunks, handling **bold** and `inline code`.
--- Does not handle nested formatting.
--- @param text string
--- @param default_hl string
--- @return table[] list of {text, hl} pairs
local function parse_inline(text, default_hl)
  local chunks = {}
  local i = 1
  while i <= #text do
    local b_start = text:find("%*%*", i)
    local c_start = text:find("`", i)
    local next_pos, next_type
    if b_start and (not c_start or b_start <= c_start) then
      next_pos, next_type = b_start, "bold"
    elseif c_start then
      next_pos, next_type = c_start, "code"
    end
    if not next_pos then
      table.insert(chunks, { text:sub(i), default_hl })
      break
    end
    if next_pos > i then
      table.insert(chunks, { text:sub(i, next_pos - 1), default_hl })
    end
    if next_type == "bold" then
      local close = text:find("%*%*", next_pos + 2)
      if close then
        local inner = text:sub(next_pos + 2, close - 1)
        if #inner > 0 then table.insert(chunks, { inner, "GhCommentBold" }) end
        i = close + 2
      else
        table.insert(chunks, { "**", default_hl })
        i = next_pos + 2
      end
    else
      local close = text:find("`", next_pos + 1)
      if close then
        local inner = text:sub(next_pos + 1, close - 1)
        if #inner > 0 then table.insert(chunks, { inner, "GhCommentCode" }) end
        i = close + 1
      else
        table.insert(chunks, { "`", default_hl })
        i = next_pos + 1
      end
    end
  end
  return chunks
end

--- Wrap a list of {text, hl} chunks into rows that fit max_width visible characters.
--- Returns a list of rows, each being a list of {text, hl} chunks.
--- @param chunks table[]
--- @param max_width integer
--- @return table[][]
local function wrap_chunks(chunks, max_width)
  if max_width <= 0 then return { chunks } end
  local total = 0
  for _, ch in ipairs(chunks) do total = total + #ch[1] end
  if total <= max_width then return { chunks } end

  local rows = {}
  local current_row = {}
  local current_len = 0

  local function flush()
    if #current_row > 0 then
      table.insert(rows, current_row)
      current_row = {}
      current_len = 0
    end
  end

  for _, ch in ipairs(chunks) do
    local text, hl = ch[1], ch[2]
    local s = text
    while #s > 0 do
      local remaining = max_width - current_len
      if remaining <= 0 then
        flush()
        remaining = max_width
      end
      if #s <= remaining then
        table.insert(current_row, { s, hl })
        current_len = current_len + #s
        s = ""
      else
        -- Try word boundary split within remaining chars
        local break_at = nil
        for bi = remaining, 1, -1 do
          if s:sub(bi, bi) == " " then
            break_at = bi
            break
          end
        end
        if break_at then
          if break_at > 1 then
            table.insert(current_row, { s:sub(1, break_at - 1), hl })
          end
          flush()
          s = s:sub(break_at + 1)  -- skip the space
        else
          -- Hard break
          table.insert(current_row, { s:sub(1, remaining), hl })
          flush()
          s = s:sub(remaining + 1)
        end
      end
    end
  end
  flush()
  return rows
end

--- Build virt_lines for a single comment.
--- @param comment GhComment
--- @param is_resolved boolean
--- @param is_reply boolean  true for reply comments (indented with ↳)
--- @param max_width integer  available width for body text (excluding indent)
--- @return table[] list of virt_line rows (each is a list of {text, hl} chunks)
local function comment_virt_lines(comment, is_resolved, is_reply, max_width)
  local body_hl = is_resolved and "GhCommentResolved" or "GhCommentBody"
  local author_hl = is_resolved and "GhCommentResolved" or "GhCommentAuthor"
  local date_hl = "GhCommentDate"

  local lines = {}

  -- Author + date header
  local login = (comment.user and comment.user.login) or "unknown"
  local date_str = relative_time(comment.created_at)
  if is_reply then
    table.insert(lines, {
      { "    ↳ @" .. login, author_hl },
      { "  " .. date_str, date_hl },
    })
  else
    table.insert(lines, {
      { "  @" .. login, author_hl },
      { "  " .. date_str, date_hl },
    })
  end

  -- Body lines
  local body = comment.body or ""
  local body_indent = is_reply and "      " or "  "
  local indent_width = #body_indent
  local avail = math.max(20, max_width - indent_width)

  local in_code = false
  local is_suggest = false
  for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
    if line:match("^```") then
      if not in_code then
        in_code = true
        is_suggest = line:match("^```suggestion") ~= nil
        local fence_hl = is_suggest and "GhCommentSuggestion" or "GhCommentCode"
        table.insert(lines, { { body_indent .. line, fence_hl } })
      else
        local fence_hl = is_suggest and "GhCommentSuggestion" or "GhCommentCode"
        table.insert(lines, { { body_indent .. line, fence_hl } })
        in_code = false
        is_suggest = false
      end
    elseif in_code then
      local code_hl = is_suggest and "GhCommentSuggestion" or "GhCommentCode"
      for _, seg in ipairs(wrap_line(line, avail)) do
        table.insert(lines, { { body_indent .. seg, code_hl } })
      end
    elseif is_resolved then
      -- Resolved comments: plain rendering, no markdown decoration
      for _, seg in ipairs(wrap_line(line, avail)) do
        table.insert(lines, { { body_indent .. seg, body_hl } })
      end
    else
      local chunks = parse_inline(line, body_hl)
      if #chunks == 0 then
        table.insert(lines, { { body_indent, body_hl } })
      else
        for _, row in ipairs(wrap_chunks(chunks, avail)) do
          local vline = { { body_indent, body_hl } }
          for _, ch in ipairs(row) do
            table.insert(vline, ch)
          end
          table.insert(lines, vline)
        end
      end
    end
  end

  return lines
end

-- ---------------------------------------------------------------------------
-- Core rendering
-- ---------------------------------------------------------------------------

--- Render a single thread as virt_lines + sign + EOL text.
--- @param buf integer  target buffer
--- @param thread GhThread
--- @param ns_comments integer
--- @param ns_signs integer
--- @param ns_eol integer
local function render_thread(buf, thread, ns_comments, ns_signs, ns_eol)
  if not vim.api.nvim_buf_is_valid(buf) then return end

  -- Determine available width for comment text from the buffer's window.
  -- Subtract sign column, line numbers, fold column etc. so text isn't clipped.
  local win_width = math.floor(vim.o.columns / 2) - 8
  local wins = vim.fn.win_findbuf(buf)
  if wins and #wins > 0 then
    local w = wins[1]
    local textoff = 0
    local info = vim.fn.getwininfo(w)
    if info and info[1] then
      textoff = info[1].textoff or 0
    end
    win_width = vim.api.nvim_win_get_width(w) - textoff - 1
  end

  -- Determine anchor line (1-based from GitHub; convert to 0-based for extmarks)
  local anchor_line = thread.line or thread.original_line
  if not anchor_line or anchor_line < 1 then return end
  local row = anchor_line - 1  -- 0-based

  -- Clamp to buffer length
  local line_count = vim.api.nvim_buf_line_count(buf)
  if row >= line_count then row = math.max(0, line_count - 1) end

  local is_resolved = thread.is_resolved or false
  local sep_hl = is_resolved and "GhCommentResolved" or "GhCommentSeparator"

  -- Build all virt_lines
  local virt_lines = {}

  -- Opening separator
  table.insert(virt_lines, { { "  " .. SEP, sep_hl } })

  -- Resolved badge
  if is_resolved then
    table.insert(virt_lines, { { "  [RESOLVED]", "GhCommentResolved" } })
  end

  -- Comments
  for i, comment in ipairs(thread.comments or {}) do
    -- Blank line between comments (not before the first one)
    if i > 1 then
      table.insert(virt_lines, { { "", "Normal" } })
    end
    for _, vline in ipairs(comment_virt_lines(comment, is_resolved, i > 1, win_width)) do
      table.insert(virt_lines, vline)
    end
  end

  -- Closing separator
  table.insert(virt_lines, { { "  " .. SEP, sep_hl } })

  -- Place virt_lines extmark
  vim.api.nvim_buf_set_extmark(buf, ns_comments, row, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
  })

  -- Sign column indicator
  local sign_text = is_resolved and "" or ""
  local sign_hl = is_resolved and "GhSignComment" or "GhSignUnresolved"
  vim.api.nvim_buf_set_extmark(buf, ns_signs, row, 0, {
    sign_text = sign_text,
    sign_hl_group = sign_hl,
    priority = 10,
  })

  -- EOL virtual text: "  N comments"
  local n = #(thread.comments or {})
  local eol_text = string.format("   %d comment%s", n, n == 1 and "" or "s")
  vim.api.nvim_buf_set_extmark(buf, ns_eol, row, 0, {
    virt_text = { { eol_text, "GhCommentCount" } },
    virt_text_pos = "eol",
    priority = 10,
  })
end

--- Clear all comment-related extmarks from a buffer.
--- @param buf integer
--- @param ns_comments integer
--- @param ns_signs integer
--- @param ns_eol integer
local function clear_buf(buf, ns_comments, ns_signs, ns_eol)
  if not buf then return end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns_comments, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_signs, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_eol, 0, -1)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Render comments for all threads in the current file's diff buffers.
--- Called after threads are initially fetched (or refreshed).
--- @param threads GhThread[]
function M.render_all(threads)
  local state = require("gh-dash-diff.state").state
  if not state.layout.ready then return end

  -- Determine current file path
  local files = state.pr.files
  local idx = state.pr.current_idx
  if idx < 1 or idx > #files then return end
  local filename = files[idx].filename

  -- Update threads in state
  state.review.threads = threads

  M.render_for_file(state, filename)
end

--- Render comments for a specific file's diff buffers.
--- Called when switching files or after a comment is added.
--- @param state GhDashDiffState
--- @param filename string
function M.render_for_file(state, filename)
  if not state.review.comments_visible then return end

  local ns_c = state.ns.comments
  local ns_s = state.ns.signs
  local ns_e = state.ns.eol
  if not ns_c or not ns_s or not ns_e then return end

  local left_buf = state.layout.left_buf
  local right_buf = state.layout.right_buf

  -- Snapshot cursor positions before touching extmarks.  Clearing virtual
  -- lines from scrollbound diff windows can trigger scroll-sync and jump
  -- the cursor to the top.
  local saved_cursors = {}
  for _, wk in ipairs({ "left_win", "right_win" }) do
    local w = state.layout[wk]
    if w and vim.api.nvim_win_is_valid(w) then
      saved_cursors[wk] = vim.api.nvim_win_get_cursor(w)
    end
  end

  -- Clear previous extmarks on both buffers
  clear_buf(left_buf, ns_c, ns_s, ns_e)
  clear_buf(right_buf, ns_c, ns_s, ns_e)

  -- Render threads for this file
  for _, thread in ipairs(state.review.threads or {}) do
    if thread.path == filename then
      local buf = buf_for_side(state, thread.side)
      if buf then
        render_thread(buf, thread, ns_c, ns_s, ns_e)
      end
    end
  end

  -- Also render pending comments for this file (local, not yet submitted)
  for _, pc in ipairs(state.review.pending_comments or {}) do
    if pc.path == filename then
      local buf = buf_for_side(state, pc.side)
      if buf and vim.api.nvim_buf_is_valid(buf) then
        local row = (pc.line or 1) - 1
        local line_count = vim.api.nvim_buf_line_count(buf)
        if row >= line_count then row = math.max(0, line_count - 1) end

        -- Pending virt_lines (single comment, no thread wrapper)
        vim.api.nvim_buf_set_extmark(buf, ns_c, row, 0, {
          virt_lines = {
            { { "  " .. SEP, "GhCommentSeparator" } },
            { { "  [PENDING] " .. (pc.body or ""), "GhCommentBody" } },
            { { "  " .. SEP, "GhCommentSeparator" } },
          },
          virt_lines_above = false,
        })

        vim.api.nvim_buf_set_extmark(buf, ns_s, row, 0, {
          sign_text = "",
          sign_hl_group = "GhSignPending",
          priority = 20,  -- higher than existing comment signs
        })

        vim.api.nvim_buf_set_extmark(buf, ns_e, row, 0, {
          virt_text = { { "   pending", "GhCommentCount" } },
          virt_text_pos = "eol",
          priority = 20,
        })
      end
    end
  end

  -- Restore cursor positions that may have been disturbed by extmark changes.
  for _, wk in ipairs({ "left_win", "right_win" }) do
    local w = state.layout[wk]
    if saved_cursors[wk] and w and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_set_cursor, w, saved_cursors[wk])
    end
  end
end

--- Jump to the next line with a comment extmark in the buffer.
--- @param buf integer
function M.goto_next(buf)
  local state = require("gh-dash-diff.state").state
  local ns = state.ns.comments
  if not ns then return end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local cur_row = cursor[1] - 1  -- 0-based

  -- Get all marks, sorted by row
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  -- marks: { {id, row, col}, ... } — already sorted by position

  for _, mark in ipairs(marks) do
    local mark_row = mark[2]
    if mark_row > cur_row then
      vim.api.nvim_win_set_cursor(0, { mark_row + 1, 0 })
      return
    end
  end

  -- Wrap: go to first mark
  if #marks > 0 then
    vim.api.nvim_win_set_cursor(0, { marks[1][2] + 1, 0 })
  end
end

--- Jump to the previous line with a comment extmark in the buffer.
--- @param buf integer
function M.goto_prev(buf)
  local state = require("gh-dash-diff.state").state
  local ns = state.ns.comments
  if not ns then return end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local cur_row = cursor[1] - 1  -- 0-based

  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})

  for i = #marks, 1, -1 do
    local mark_row = marks[i][2]
    if mark_row < cur_row then
      vim.api.nvim_win_set_cursor(0, { mark_row + 1, 0 })
      return
    end
  end

  -- Wrap: go to last mark
  if #marks > 0 then
    vim.api.nvim_win_set_cursor(0, { marks[#marks][2] + 1, 0 })
  end
end

--- Convenience wrapper: re-render pending comments for the current file.
--- Called by ui/input.lua after a pending comment is added or removed.
--- @param state GhDashDiffState
function M.update_pending(state)
  local files = state.pr.files
  local idx = state.pr.current_idx
  if idx >= 1 and idx <= #files then
    M.render_for_file(state, files[idx].filename)
  end
end

--- Toggle comment virt_lines visibility.
--- Clears or re-renders all comment namespaces for the current file.
--- @param state GhDashDiffState
function M.toggle(state)
  state.review.comments_visible = not state.review.comments_visible

  if state.review.comments_visible then
    -- Re-render for the current file
    local files = state.pr.files
    local idx = state.pr.current_idx
    if idx >= 1 and idx <= #files then
      M.render_for_file(state, files[idx].filename)
    end
    vim.notify("gh-dash-diff: comments shown", vim.log.levels.INFO)
  else
    -- Clear all extmarks from both diff buffers
    local ns_c = state.ns.comments
    local ns_s = state.ns.signs
    local ns_e = state.ns.eol
    if ns_c then
      clear_buf(state.layout.left_buf, ns_c, ns_s, ns_e)
      clear_buf(state.layout.right_buf, ns_c, ns_s, ns_e)
    end
    vim.notify("gh-dash-diff: comments hidden", vim.log.levels.INFO)
  end
end

return M
