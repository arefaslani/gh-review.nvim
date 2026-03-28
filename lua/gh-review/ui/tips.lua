local M = {}

--- Tips shown while the PR list is loading.
M.loading = {
  -- Picker filters
  "tip: <C-a> filter by author    <C-o> show open PRs only",
  "tip: <C-x> show closed PRs     <C-n> review requested by you",
  "tip: <C-r> refresh PR list      <CR> open selected PR",
  "tip: combine filters — e.g. <C-a> + <C-o> for your open PRs",

  -- Search modes
  "tip: <C-g> toggle live search   type to fuzzy-filter results",
  "tip: live search passes queries directly to the GitHub API",
  "tip: in live search, type 'author:' to get ghost-text completions",
  "tip: live search supports all GitHub search qualifiers (label:, milestone:, …)",
}

--- Tips shown while a PR is being opened.
M.opening = {
  -- Navigation between files
  "tip: use ]f / [f to jump between changed files",
  "tip: use <C-o> / <C-i> to go back / forward in visited files",

  -- Navigation within files
  "tip: use ]c / [c to jump between changed hunks in a file",
  "tip: use ]x / [x to jump between comments in a file",

  -- Commit review
  "tip: use ]g / [g to step through commits one by one",
  "tip: press <leader>cm to toggle between file and commit review mode",

  -- Comments
  "tip: press <leader>cc to add an inline comment (queued for batch review)",
  "tip: press <leader>ca to post a single comment immediately",
  "tip: select lines in visual mode before <leader>cc for multi-line comments",
  "tip: press <leader>cr to reply to a comment thread",
  "tip: press <leader>ce to edit a comment you wrote",
  "tip: press <leader>cd to delete a pending comment",
  "tip: press <leader>cx to resolve or unresolve a thread",
  "tip: press <leader>ct to toggle comment visibility on/off",
  "tip: press gx on a comment to open its URL in the browser",

  -- Review submission
  "tip: press <leader>rs to submit your review (approve, request changes, or comment)",
  "tip: press <leader>cv to mark a file as viewed (synced with GitHub)",

  -- Sidebar & layout
  "tip: press t to toggle the file picker sidebar",
  "tip: press <leader>e to toggle the explorer sidebar",

  -- Editing
  "tip: press <CR> on a diff line to edit the file at that line",
  "tip: use :GhReviewResume to get back to your review after editing",

  -- General
  "tip: press o to open the current PR in your browser",
  "tip: press R to refresh the PR data from GitHub",
  "tip: press ? to see all keybindings at a glance",
  "tip: press q to close the review",

  -- AI features
  "tip: enable ai with { ai = { enabled = true } } for AI-assisted reviews",
  "tip: <leader>ae explains a code selection using AI",
  "tip: <leader>aa analyzes the current file diff for potential issues",
  "tip: <leader>as generates an AI summary of the entire PR",
  "tip: <leader>ac drafts a review comment for the current line",
  "tip: <leader>ar suggests a reply to the comment thread under cursor",
  "tip: <leader>ai opens an AI chat window for the current PR",

  -- Configuration
  "tip: all keymaps are customizable — set any to false to disable it",
  "tip: set diff_context_lines to control how many context lines surround hunks",
  "tip: sign characters for comments are customizable via the signs option",
  "tip: the explorer sidebar position and width are configurable",

  -- Commands
  "tip: :GhPrs opens a PR browser for the current repo",
  "tip: :GhReview 123 opens PR #123 directly for review",
}

--- Pick a random tip from a list.
function M.random(tips)
  return tips[math.random(#tips)]
end

return M
