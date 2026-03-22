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

--- Build virt_lines for a single comment.
--- @param comment GhComment
--- @param is_resolved boolean
--- @return table[] list of virt_line rows (each is a list of {text, hl} chunks)
local function comment_virt_lines(comment, is_resolved)
  local body_hl = is_resolved and "GhCommentResolved" or "GhCommentBody"
  local author_hl = is_resolved and "GhCommentResolved" or "GhCommentAuthor"
  local date_hl = "GhCommentDate"

  local lines = {}

  -- Author + date header
  local login = (comment.user and comment.user.login) or "unknown"
  local date_str = relative_time(comment.created_at)
  table.insert(lines, {
    { "  @" .. login, author_hl },
    { "  " .. date_str, date_hl },
  })

  -- Body lines
  local body = comment.body or ""
  for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
    table.insert(lines, { { "  " .. line, body_hl } })
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
    for _, vline in ipairs(comment_virt_lines(comment, is_resolved)) do
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
