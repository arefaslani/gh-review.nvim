local M = {}

-- ---------------------------------------------------------------------------
-- System prompts
-- ---------------------------------------------------------------------------

M.REVIEWER_SYSTEM = [[You are an expert code reviewer. Analyze pull request diffs and report precise, actionable findings.

Rules:
- Only flag bugs, logic errors, security vulnerabilities, and performance problems
- Do NOT comment on formatting, style, naming conventions, or code organization
- Be concise — 1-3 sentences per finding
- Only include findings where you are confident (skip uncertain guesses)
- Use the submit_findings tool to return structured output]]

M.EXPLAINER_SYSTEM = [[You are a helpful code assistant. Explain code changes clearly and concisely.
Focus on: what the code does, why it might have changed, and any potential concerns.
Be direct. Avoid unnecessary padding or repetition.]]

M.COMMENTER_SYSTEM = [[You are a helpful code reviewer drafting a review comment.
Write a single concise, professional, and actionable comment. 1-3 sentences maximum.
Do not include greetings, sign-offs, or meta-commentary about what you are doing.]]

-- ---------------------------------------------------------------------------
-- Context builders
-- ---------------------------------------------------------------------------

--- Build the user message for explain_selection.
--- @param file GhFile
--- @param selected_lines string[]
--- @param surrounding_lines string[]
--- @param state GhReviewState
--- @return string
function M.explain_context(file, selected_lines, surrounding_lines, state)
  local pr = state.pr
  local parts = {}

  table.insert(parts, string.format("PR #%s: %s", pr.number or "?", pr.title or "(no title)"))
  table.insert(parts, string.format("File: %s  [status: %s]", file.filename, file.status or "modified"))

  if surrounding_lines and #surrounding_lines > 0 then
    table.insert(parts, "\nSurrounding context:")
    table.insert(parts, "```")
    table.insert(parts, table.concat(surrounding_lines, "\n"))
    table.insert(parts, "```")
  end

  table.insert(parts, "\nSelected code to explain:")
  table.insert(parts, "```")
  table.insert(parts, table.concat(selected_lines, "\n"))
  table.insert(parts, "```")

  table.insert(parts, "\nExplain what this code does, why it may have changed, and note any concerns.")

  return table.concat(parts, "\n")
end

--- Build the user message for analyze_file (tool use).
--- @param file GhFile
--- @param base_lines string[]
--- @param head_lines string[]
--- @param threads GhThread[]  existing threads on this file (for dedup)
--- @param upfront_context? string  optional repo context (git history, imports, etc.)
--- @return string
function M.analyze_context(file, base_lines, head_lines, threads, upfront_context)
  local parts = {}

  -- Upfront repo context (cheap, ~50-300 tokens)
  if upfront_context and upfront_context ~= "" then
    table.insert(parts, "Repository context:")
    table.insert(parts, upfront_context)
    table.insert(parts, "")
  end

  table.insert(parts, string.format(
    "File: %s  [status: %s, +%d -%d lines]",
    file.filename,
    file.status or "modified",
    file.additions or 0,
    file.deletions or 0
  ))

  -- Existing threads — avoid duplicating what reviewers already flagged
  local active_threads = {}
  for _, t in ipairs(threads or {}) do
    if not t.is_resolved then
      table.insert(active_threads, t)
    end
  end
  if #active_threads > 0 then
    table.insert(parts, "\nExisting review comments (do not duplicate):")
    for _, t in ipairs(active_threads) do
      local first = t.comments and t.comments[1]
      if first then
        table.insert(parts, string.format(
          "  Line %d: %s",
          t.line or 0,
          (first.body or ""):sub(1, 120)
        ))
      end
    end
  end

  table.insert(parts, "\nBase version (before this PR):")
  table.insert(parts, "```")
  -- Cap at ~400 lines to stay within token budget for large files
  local base_cap = math.min(#base_lines, 400)
  for i = 1, base_cap do
    table.insert(parts, string.format("%4d: %s", i, base_lines[i]))
  end
  if #base_lines > base_cap then
    table.insert(parts, string.format("... (%d more lines truncated)", #base_lines - base_cap))
  end
  table.insert(parts, "```")

  table.insert(parts, "\nPR version (HEAD — analyze this side):")
  table.insert(parts, "```")
  local head_cap = math.min(#head_lines, 400)
  for i = 1, head_cap do
    table.insert(parts, string.format("%4d: %s", i, head_lines[i]))
  end
  if #head_lines > head_cap then
    table.insert(parts, string.format("... (%d more lines truncated)", #head_lines - head_cap))
  end
  table.insert(parts, "```")

  table.insert(parts, "\nAnalyze the changes. Focus on the PR version (RIGHT/HEAD). Use the submit_findings tool.")

  return table.concat(parts, "\n")
end

--- Build the user message for draft_comment.
--- @param file GhFile
--- @param cursor_line integer  1-based
--- @param buf_lines string[]
--- @param threads GhThread[]
--- @return string
function M.draft_comment_context(file, cursor_line, buf_lines, threads)
  local parts = {}

  table.insert(parts, string.format("File: %s", file.filename))

  -- ±20 lines around cursor, with >> marker
  local ctx_start = math.max(1, cursor_line - 20)
  local ctx_end   = math.min(#buf_lines, cursor_line + 20)
  local ctx_lines = {}
  for i = ctx_start, ctx_end do
    local prefix = (i == cursor_line) and ">> " or "   "
    table.insert(ctx_lines, string.format("%s%4d: %s", prefix, i, buf_lines[i] or ""))
  end

  table.insert(parts, "\nCode context (>> marks the target line):")
  table.insert(parts, "```")
  table.insert(parts, table.concat(ctx_lines, "\n"))
  table.insert(parts, "```")

  -- Nearby existing threads for dedup
  local nearby = {}
  for _, t in ipairs(threads or {}) do
    local t_line = t.line or t.original_line or 0
    if math.abs(t_line - cursor_line) <= 10 then
      local first = t.comments and t.comments[1]
      if first then
        table.insert(nearby, string.format(
          "  Line %d: %s", t_line, (first.body or ""):sub(1, 80)
        ))
      end
    end
  end
  if #nearby > 0 then
    table.insert(parts, "\nNearby existing comments (do not duplicate):")
    table.insert(parts, table.concat(nearby, "\n"))
  end

  table.insert(parts, string.format(
    "\nDraft a concise review comment for line %d.", cursor_line
  ))

  return table.concat(parts, "\n")
end

--- Build the user message for reply_suggestion.
--- @param thread GhThread
--- @param file GhFile
--- @return string
function M.reply_context(thread, file)
  local parts = {}

  table.insert(parts, string.format(
    "File: %s, Line: %d", file.filename, thread.line or thread.original_line or 0
  ))
  table.insert(parts, "\nReview thread:")
  for i, comment in ipairs(thread.comments or {}) do
    local author = (comment.user and comment.user.login) or "unknown"
    table.insert(parts, string.format("%d. @%s: %s", i, author, comment.body or ""))
  end

  table.insert(parts, "\nSuggest a brief, helpful reply to continue this thread.")

  return table.concat(parts, "\n")
end

--- Build the user message for review_summary.
--- @param state GhReviewState
--- @return string
function M.summary_context(state)
  local pr = state.pr
  local parts = {}

  table.insert(parts, string.format("PR #%s: %s", pr.number or "?", pr.title or "(no title)"))
  table.insert(parts, string.format("Branch: %s → %s", pr.head_ref or "?", pr.base_ref or "?"))

  -- Files changed
  local file_count = #(pr.files or {})
  table.insert(parts, string.format("\n%d file(s) changed:", file_count))
  for _, f in ipairs(pr.files or {}) do
    local icon = f.status == "added" and "+" or f.status == "removed" and "-" or "~"
    table.insert(parts, string.format("  %s %s (+%d -%d)", icon, f.filename, f.additions or 0, f.deletions or 0))
  end

  -- Pending comments
  local pending = state.review.pending_comments or {}
  if #pending > 0 then
    table.insert(parts, string.format("\nYour %d pending comment(s):", #pending))
    for _, pc in ipairs(pending) do
      table.insert(parts, string.format(
        "  %s:%d: %s",
        pc.path or "",
        pc.line or 0,
        (pc.body or ""):sub(1, 100)
      ))
    end
  end

  -- Unresolved thread count
  local unresolved = 0
  for _, t in ipairs(state.review.threads or {}) do
    if not t.is_resolved then unresolved = unresolved + 1 end
  end
  if unresolved > 0 then
    table.insert(parts, string.format("\n%d unresolved existing thread(s).", unresolved))
  end

  table.insert(parts, "\nWrite a concise PR review summary (2-4 sentences). Cover: what changed, any concerns, overall assessment.")

  return table.concat(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- Tool definition for analyze_file
-- ---------------------------------------------------------------------------

M.ANALYZE_TOOL = {
  name        = "submit_findings",
  description = "Submit structured code review findings with exact line numbers and severity",
  input_schema = {
    type = "object",
    properties = {
      findings = {
        type  = "array",
        items = {
          type = "object",
          properties = {
            line     = { type = "integer", description = "Line number exactly as shown in the code block (the number before the colon)" },
            side     = { type = "string",  enum = { "LEFT", "RIGHT" }, description = "LEFT=base, RIGHT=PR head" },
            severity = { type = "string",  enum = { "critical", "warning", "suggestion" } },
            body     = { type = "string",  description = "Concise finding (1-3 sentences)" },
          },
          required = { "line", "side", "severity", "body" },
        },
      },
      summary = { type = "string", description = "One-sentence overall summary of the file review" },
    },
    required = { "findings", "summary" },
  },
}

return M
