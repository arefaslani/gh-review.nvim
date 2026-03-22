local M = {}
local exec = require("gh-dash-diff.gh.exec")

-- ---------------------------------------------------------------------------
-- GraphQL queries
-- ---------------------------------------------------------------------------

local THREADS_QUERY = [[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          originalLine
          startLine
          originalStartLine
          diffSide
          resolvedBy { login }
          comments(first: 100) {
            nodes {
              databaseId
              body
              author { login }
              createdAt
              updatedAt
              path
              line
              originalLine
              startLine
              diffSide
              startDiffSide
              replyTo { databaseId }
              pullRequestReview { databaseId state }
            }
          }
        }
      }
    }
  }
}
]]

-- ---------------------------------------------------------------------------
-- Thread fetching
-- ---------------------------------------------------------------------------

--- Fetch all review threads for a PR via GraphQL (includes resolution status).
--- Falls back to REST list_comments + group_into_threads on GraphQL error.
--- @param owner string
--- @param repo string
--- @param pr_number integer
--- @param callback fun(err: string|nil, threads: GhThread[]|nil)
function M.fetch_threads(owner, repo, pr_number, callback)
  exec.graphql(THREADS_QUERY, {
    owner = owner,
    name = repo,
    number = pr_number,
  }, function(err, data)
    if err then
      -- GraphQL failed — fall back to REST
      M.list_comments(owner, repo, pr_number, function(err2, comments)
        if err2 then callback(err2, nil); return end
        callback(nil, M.group_into_threads(comments or {}))
      end)
      return
    end

    local raw_threads = vim.tbl_get(
      data, "repository", "pullRequest", "reviewThreads", "nodes"
    ) or {}

    local threads = {}
    for _, t in ipairs(raw_threads) do
      local comments = {}
      for _, c in ipairs((t.comments or {}).nodes or {}) do
        table.insert(comments, {
          id           = c.databaseId,
          body         = c.body,
          user         = { login = c.author and c.author.login or "unknown" },
          created_at   = c.createdAt,
          updated_at   = c.updatedAt,
          path         = c.path,
          line         = c.line,
          original_line = c.originalLine,
          start_line   = c.startLine,
          side         = c.diffSide,
          start_side   = c.startDiffSide,
          in_reply_to_id = c.replyTo and c.replyTo.databaseId or nil,
        })
      end
      table.insert(threads, {
        id           = t.id,
        is_resolved  = t.isResolved or false,
        is_outdated  = t.isOutdated or false,
        path         = t.path,
        line         = t.line,
        original_line = t.originalLine,
        start_line   = t.startLine,
        side         = t.diffSide,
        comments     = comments,
      })
    end
    callback(nil, threads)
  end)
end

-- ---------------------------------------------------------------------------
-- REST comment operations
-- ---------------------------------------------------------------------------

--- Fetch all inline review comments for a PR via REST (paginated).
--- @param owner string
--- @param repo string
--- @param pr_number integer
--- @param callback fun(err: string|nil, comments: GhComment[]|nil)
function M.list_comments(owner, repo, pr_number, callback)
  exec.run_json({
    "api",
    string.format("repos/%s/%s/pulls/%d/comments", owner, repo, pr_number),
    "--paginate",
  }, nil, callback)
end

--- Create a pending review (no event = PENDING state).
--- Call this before adding individual comments one by one.
--- @param owner string
--- @param repo string
--- @param pr_number integer
--- @param commit_sha string HEAD commit SHA of the PR
--- @param callback fun(err: string|nil, review: GhPendingReview|nil)
function M.create_pending_review(owner, repo, pr_number, commit_sha, callback)
  exec.run({
    "api",
    string.format("repos/%s/%s/pulls/%d/reviews", owner, repo, pr_number),
    "-X", "POST",
    "-f", "commit_id=" .. commit_sha,
    "--jq", "{id: .id, state: .state, commit_id: .commit_id}",
  }, nil, function(err, stdout)
    if err then callback(err, nil); return end
    local ok, data = pcall(vim.json.decode, stdout)
    if ok then
      callback(nil, data)
    else
      callback("Failed to parse pending review response", nil)
    end
  end)
end

--- Add a single inline comment to an existing pending review.
--- @param owner string
--- @param repo string
--- @param pr_number integer
--- @param review_id integer
--- @param comment {path: string, line: integer, side: "LEFT"|"RIGHT", body: string, start_line?: integer, start_side?: "LEFT"|"RIGHT"}
--- @param callback fun(err: string|nil, comment: GhComment|nil)
function M.add_comment_to_review(owner, repo, pr_number, review_id, comment, callback)
  local args = {
    "api",
    string.format("repos/%s/%s/pulls/%d/reviews/%d/comments",
      owner, repo, pr_number, review_id),
    "-X", "POST",
    "-f", "path=" .. comment.path,
    "-F", "line=" .. tostring(comment.line),
    "-f", "side=" .. comment.side,
    "-f", "body=" .. comment.body,
  }
  if comment.start_line then
    table.insert(args, "-F"); table.insert(args, "start_line=" .. tostring(comment.start_line))
    table.insert(args, "-f"); table.insert(args, "start_side=" .. (comment.start_side or comment.side))
  end
  exec.run_json(args, nil, callback)
end

--- Submit an existing pending review.
--- @param owner string
--- @param repo string
--- @param pr_number integer
--- @param review_id integer
--- @param event "APPROVE"|"REQUEST_CHANGES"|"COMMENT"
--- @param body? string Optional review summary message
--- @param callback fun(err: string|nil, review: GhReview|nil)
function M.submit_review(owner, repo, pr_number, review_id, event, body, callback)
  local args = {
    "api",
    string.format("repos/%s/%s/pulls/%d/reviews/%d/events",
      owner, repo, pr_number, review_id),
    "-X", "POST",
    "-f", "event=" .. event,
  }
  if body and body ~= "" then
    table.insert(args, "-f"); table.insert(args, "body=" .. body)
  end
  exec.run_json(args, nil, callback)
end

--- Create a review with all inline comments in a single API call (preferred).
--- Avoids the create-pending → add-comments → submit dance.
--- @param owner string
--- @param repo string
--- @param pr_number integer
--- @param opts {commit_sha: string, event: "APPROVE"|"REQUEST_CHANGES"|"COMMENT", body?: string, comments: {path: string, line: integer, side: "LEFT"|"RIGHT", body: string}[]}
--- @param callback fun(err: string|nil, review: GhReview|nil)
function M.create_review_with_comments(owner, repo, pr_number, opts, callback)
  local payload = {
    commit_id = opts.commit_sha,
    event     = opts.event,
    body      = opts.body or "",
    comments  = opts.comments,
  }
  local json = vim.json.encode(payload)
  exec.run({
    "api",
    string.format("repos/%s/%s/pulls/%d/reviews", owner, repo, pr_number),
    "-X", "POST",
    "--input", "-",
  }, { stdin = json }, function(err, stdout)
    if err then callback(err, nil); return end
    local ok, data = pcall(vim.json.decode, stdout)
    if ok then callback(nil, data) else callback("JSON parse error", nil) end
  end)
end

--- Post a single standalone PR review comment immediately (not part of a review).
--- @param owner string
--- @param repo string
--- @param pr_number integer
--- @param opts {commit_sha: string, path: string, line: integer, side: "LEFT"|"RIGHT", body: string, start_line?: integer, start_side?: "LEFT"|"RIGHT"}
--- @param callback fun(err: string|nil, comment: GhComment|nil)
function M.create_single_comment(owner, repo, pr_number, opts, callback)
  local payload = {
    body      = opts.body,
    commit_id = opts.commit_sha,
    path      = opts.path,
    line      = opts.line,
    side      = opts.side,
  }
  if opts.start_line then
    payload.start_line = opts.start_line
    payload.start_side = opts.start_side or opts.side
  end
  local json = vim.json.encode(payload)
  exec.run({
    "api",
    string.format("repos/%s/%s/pulls/%d/comments", owner, repo, pr_number),
    "-X", "POST",
    "--input", "-",
  }, { stdin = json }, function(err, stdout)
    if err then callback(err, nil); return end
    local ok, data = pcall(vim.json.decode, stdout)
    if ok then callback(nil, data) else callback("JSON parse error", nil) end
  end)
end

--- Reply to an existing comment thread.
--- Replies are sent immediately (not queued as pending).
--- @param owner string
--- @param repo string
--- @param pr_number integer
--- @param comment_id integer Database ID of the comment to reply to
--- @param body string Reply text (markdown)
--- @param callback fun(err: string|nil, comment: GhComment|nil)
function M.reply_to_comment(owner, repo, pr_number, comment_id, body, callback)
  exec.run_json({
    "api",
    string.format("repos/%s/%s/pulls/%d/comments/%d/replies",
      owner, repo, pr_number, comment_id),
    "-X", "POST",
    "-f", "body=" .. body,
  }, nil, callback)
end

-- ---------------------------------------------------------------------------
-- Thread resolution (GraphQL only — not available via REST)
-- ---------------------------------------------------------------------------

--- Resolve a review thread.
--- @param thread_id string GraphQL node ID of the thread
--- @param callback fun(err: string|nil)
function M.resolve_thread(thread_id, callback)
  exec.graphql(
    "mutation($threadId: ID!) { resolveReviewThread(input: { threadId: $threadId }) { thread { isResolved } } }",
    { threadId = thread_id },
    function(err, data)
      if err then callback(err); return end
      local resolved = vim.tbl_get(data, "resolveReviewThread", "thread", "isResolved")
      if not resolved then
        callback("Thread was not resolved (unexpected API response)")
      else
        callback(nil)
      end
    end
  )
end

--- Unresolve a review thread.
--- @param thread_id string GraphQL node ID of the thread
--- @param callback fun(err: string|nil)
function M.unresolve_thread(thread_id, callback)
  exec.graphql(
    "mutation($threadId: ID!) { unresolveReviewThread(input: { threadId: $threadId }) { thread { isResolved } } }",
    { threadId = thread_id },
    function(err, _) callback(err) end
  )
end

-- ---------------------------------------------------------------------------
-- REST fallback: reconstruct threads from flat comment list
-- ---------------------------------------------------------------------------

--- Group flat REST comments into thread objects using in_reply_to_id.
--- Used as a fallback when GraphQL fetch_threads fails.
--- @param comments GhComment[]
--- @return GhThread[]
function M.group_into_threads(comments)
  local by_id = {}
  for _, c in ipairs(comments) do by_id[c.id] = c end

  local threads = {}
  local thread_by_root = {}

  for _, c in ipairs(comments) do
    if not c.in_reply_to_id then
      local thread = {
        id          = nil,
        is_resolved = false,
        is_outdated = false,
        path        = c.path,
        line        = c.line,
        side        = c.side,
        comments    = { c },
      }
      table.insert(threads, thread)
      thread_by_root[c.id] = thread
    end
  end

  for _, c in ipairs(comments) do
    if c.in_reply_to_id then
      -- Walk up the reply chain to find the root comment
      local root_id = c.in_reply_to_id
      while by_id[root_id] and by_id[root_id].in_reply_to_id do
        root_id = by_id[root_id].in_reply_to_id
      end
      local thread = thread_by_root[root_id]
      if thread then table.insert(thread.comments, c) end
    end
  end

  -- Sort each thread's comments chronologically
  for _, thread in ipairs(threads) do
    table.sort(thread.comments, function(a, b) return a.created_at < b.created_at end)
  end

  return threads
end

return M
