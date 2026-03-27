# gh-review.nvim

A Neovim plugin for reviewing GitHub Pull Requests with side-by-side diffs, inline comments, and review submission — all without leaving your editor.

## Features

- **PR browser** — Snacks picker with fuzzy search, one-key composable filters, and a live search mode for arbitrary GitHub qualifiers
- **Side-by-side diff** — Native Neovim `diffthis` with syntax highlighting
- **File explorer** — Sidebar with directory tree grouping, diff stats, and viewed indicators
- **Inline comments** — View, add, edit, reply, and delete review comments as virtual text
- **Markdown rendering** — Bold, inline code, suggestion blocks, and clickable links in comments
- **Review submission** — Submit approvals, request changes, or comment from within Neovim
- **Commit-by-commit review** — Toggle between full-PR and per-commit diff modes
- **Viewed file tracking** — Mark files as reviewed, synced with GitHub's viewed state
- **Edit and resume** — Jump to editing a file, then resume the review where you left off
- **AI-assisted review** — Explain code, analyze files for issues, draft comments, summarize PRs, and chat with full repo context using Claude (requires API key; works with any Anthropic-compatible endpoint). Prompt caching reduces repeated-call costs by ~90%.

## Requirements

- Neovim >= 0.10.0
- [gh CLI](https://cli.github.com/) (authenticated)
- [snacks.nvim](https://github.com/folke/snacks.nvim)

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "aref-aslani/gh-review.nvim",
  dependencies = { "folke/snacks.nvim" },
  cmd = { "GhReview", "GhReviewClose", "GhReviewResume", "GhPrs" },
  keys = {
    { "<leader>pr", "<cmd>GhPrs<CR>", desc = "Browse PRs" },
    { "<leader>gp", "<cmd>GhReview<CR>", desc = "Open PR review" },
    { "<leader>ppr", "<cmd>GhReviewResume<CR>", desc = "Resume PR review" },
  },
  opts = {},
}
```

## Commands

| Command | Description |
|---------|-------------|
| `:GhPrs` | Browse open PRs for the current repo |
| `:GhReview [number]` | Open PR review (prompts if no number given) |
| `:GhReviewClose` | Close the review UI |
| `:GhReviewResume` | Resume the last suspended review |

## Keybindings

### PR Browser (`GhPrs`)

| Key | Action |
|-----|--------|
| `<CR>` | Open selected PR for review |
| `<C-a>` | Toggle `author:@me` filter |
| `<C-o>` | Toggle `is:open` filter |
| `<C-x>` | Toggle `is:closed` filter |
| `<C-n>` | Toggle `review-requested:@me` filter |
| `<C-g>` | Toggle live search mode |
| `<C-r>` | Refresh / clear filters |

The picker has two input modes:

- **Fuzzy mode** (default) — typing filters the already-loaded list locally. Any active search query is shown as a statuscolumn prefix before the `>` prompt.
- **Live mode** (`<C-g>`) — the input is sent directly to `gh pr list --search` on each keystroke, re-querying GitHub in real time. Supports any [GitHub search qualifier](https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests) (e.g. `author:@me is:open label:bug`). Pressing `<C-g>` again returns to fuzzy mode.

When entering live mode, any active shortcut filters (`<C-a>` etc.) are pre-populated into the input so you can inspect and edit them. All fetches happen in-place — the picker stays open and shows a loading indicator while results arrive.

### Diff View

| Key | Action |
|-----|--------|
| `]f` / `[f` | Next / previous file |
| `<C-o>` / `<C-i>` | File back / forward (history) |
| `]c` / `[c` | Next / previous hunk (built-in) |
| `]x` / `[x` | Next / previous comment |
| `t` | Toggle file picker focus |
| `<leader>e` | Toggle explorer sidebar |
| `<CR>` | Edit file at cursor line |
| `o` | Open PR in browser |
| `q` | Close review |
| `R` | Refresh PR data |
| `?` | Show keybinding help |

### Comments

| Key | Action |
|-----|--------|
| `<leader>cc` | Add inline comment (queued for review) |
| `<leader>ca` | Post single comment immediately |
| `<leader>ce` | Edit comment under cursor |
| `<leader>cr` | Reply to thread |
| `<leader>cd` | Delete pending comment |
| `<leader>cx` | Resolve / unresolve thread |
| `<leader>ct` | Toggle comment visibility |
| `gx` | Open URL in comment under cursor |

### Review

| Key | Action |
|-----|--------|
| `<leader>cv` | Toggle file viewed status |
| `<leader>rs` | Submit review |
| `<leader>cm` | Toggle file/commit review mode |
| `]g` / `[g` | Next / previous commit |

### Explorer Sidebar

| Key | Action |
|-----|--------|
| `<CR>` / `l` | Open file diff |
| `<BS>` | Back to commit list (in commit drill-down) |
| `<leader>cv` | Toggle viewed on selected file |
| `q` | Close review |

### AI (requires `ai.enabled = true`)

| Key | Action |
|-----|--------|
| `<leader>ae` | Explain visual selection or current line |
| `<leader>aa` | Analyze current file diff for issues |
| `<leader>ac` | Draft a review comment for the current line or visual selection |
| `<leader>as` | Generate a PR review summary |
| `<leader>ar` | Suggest a reply to the thread under cursor |
| `<leader>ad` | Dismiss AI findings from diff buffers |
| `<leader>ai` | Open AI chat for the current PR |
| `<leader>ai` _(visual)_ | Open AI chat with selection pre-filled as context |

### AI Chat window

| Key | Action |
|-----|--------|
| `i` / `a` / `<CR>` | Open message input |
| `<C-s>` / `<CR>` | Send message (inside input) |
| `<Esc>` | Cancel input / close chat |
| `<C-a>` | Copy last AI response to clipboard |
| `<C-x>` | Clear chat history |
| `q` | Close chat window |

The chat maintains full conversation history for the current PR — ask follow-up questions, request clarifications, or dig into specific changes. History resets automatically when you open a different PR.

The AI chat is context-aware: it knows which file you were viewing when you opened it, has the full content of that file, and sees the unified diffs for all changed files in the PR. In `"full"` context mode, the AI can also explore the repository on-demand — reading related files, checking git history, and browsing directory structure — to answer deeper questions.

When triggered from a visual selection (`<leader>ai` in visual mode), the selected lines are inserted as a fenced code block at the top of the input, with the cursor positioned after the closing fence so you can immediately type your question:

```
```lua
local ok, data = pcall(vim.json.decode, raw)
```
What happens if `raw` is an empty string here?
```

### AI context levels

The `context_level` option controls the trade-off between review depth and API cost:

| Level | What the AI sees | Approximate cost |
|-------|-----------------|-----------------|
| `"minimal"` | File content + diff only | ~$0.01–0.05 per analysis |
| `"standard"` | + git history, imports, sibling files | ~$0.001 extra per call |
| `"full"` | + on-demand repo exploration via tools | ~$0.02–0.10 extra (varies) |

**Prompt caching** is enabled automatically for the Anthropic API. System prompts and repo context are cached for 5 minutes, so repeated calls (e.g. analyzing multiple files, chatting about the same PR) cost ~90% less on input tokens after the first call.

In `"full"` mode, the AI has three tools it can call during analysis and chat:
- **get_file_history** — fetch recent git commits for any file
- **read_repo_file** — read any file in the repository (capped at 200 lines)
- **list_directory** — list files in a directory

The AI decides when to use these tools based on the complexity of the change. Simple diffs incur no extra tool-call cost; complex changes that reference external types or have tricky history get richer context automatically.

## Configuration

All options with their defaults:

```lua
require("gh-review").setup({
  gh_cmd = "gh",

  picker = {
    width = 35,
    position = "left",
  },

  diff_algorithm = "histogram",
  diff_context_lines = 6,

  buf_prefix = {
    base = "base://",
    pr = "pr://",
  },

  -- Set any keymap to false to disable it
  keymaps = {
    toggle_picker      = "t",
    toggle_explorer    = "<leader>e",
    next_file          = "]f",
    prev_file          = "[f",
    next_comment       = "]x",
    prev_comment       = "[x",
    toggle_review_mode = "<leader>cm",
    next_commit        = "]g",
    prev_commit        = "[g",
    add_comment        = "<leader>cc",
    add_single_comment = "<leader>ca",

    edit_comment       = "<leader>ce",
    reply_thread       = "<leader>cr",
    delete_comment     = "<leader>cd",
    resolve_thread     = "<leader>cx",
    toggle_comments    = "<leader>ct",
    toggle_viewed      = "<leader>cv",
    submit_review      = "<leader>rs",
    edit_file          = "<CR>",
    open_in_browser    = "o",
    close              = "q",
    refresh            = "R",
  },

  signs = {
    comment  = "",
    pending  = "",
    resolved = "",
  },

  -- AI features (disabled by default)
  -- Requires an Anthropic-compatible API key.
  -- Works with the public Anthropic API or any compatible gateway
  -- (AWS Bedrock, custom proxies, etc.) via base_url + format + streaming.
  ai = {
    enabled        = false,
    model          = "claude-haiku-4-5-20251001",  -- fast model for interactive features
    analysis_model = "claude-sonnet-4-6",          -- deeper model for analyze_file
    api_key_env    = "ANTHROPIC_API_KEY",          -- env var to read the key from
    api_key        = nil,                          -- or set directly: api_key = "sk-ant-..."
    base_url       = "https://api.anthropic.com/v1/messages",  -- override for custom gateways
    -- format: controls the wire protocol used to talk to the AI backend.
    --   "anthropic" (default) — Anthropic Messages API
    --   "bedrock"             — AWS Bedrock (model in URL, anthropic_version in body)
    --   "openai"              — OpenAI-compatible API (works with OpenAI, Groq, Mistral,
    --                           Together AI, Ollama, LM Studio, Gemini, and more)
    format         = "anthropic",
    -- streaming: set to false if your gateway does not support SSE streaming.
    -- When false, all AI features use a single buffered request instead.
    streaming      = true,
    max_tokens     = 4096,
    -- context_level: how much repository context the AI receives.
    --   "minimal"  — only the diff and file content (cheapest)
    --   "standard" — + git history, imports, directory structure
    --   "full"     — standard + on-demand tool use to read related files
    context_level  = "standard",
    keymaps = {
      explain_selection = "<leader>ae",
      analyze_file      = "<leader>aa",
      draft_comment     = "<leader>ac",
      review_summary    = "<leader>as",
      reply_suggestion  = "<leader>ar",
      dismiss           = "<leader>ad",
      chat_open         = "<leader>ai",
    },
  },
})
```

### Using a custom AI gateway or alternative LLM

The `format` option controls the wire protocol. Set `base_url` to point at any compatible endpoint:

**OpenAI**
```lua
ai = {
  enabled        = true,
  format         = "openai",
  api_key_env    = "OPENAI_API_KEY",
  model          = "gpt-4o-mini",
  analysis_model = "gpt-4o",
},
```

**Google Gemini** (via its OpenAI-compatible endpoint)
```lua
ai = {
  enabled        = true,
  format         = "openai",
  api_key_env    = "GEMINI_API_KEY",
  base_url       = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
  model          = "gemini-2.0-flash",
  analysis_model = "gemini-2.5-pro-preview-03-25",
},
```

**Groq**
```lua
ai = {
  enabled        = true,
  format         = "openai",
  api_key_env    = "GROQ_API_KEY",
  base_url       = "https://api.groq.com/openai/v1/chat/completions",
  model          = "llama-3.3-70b-versatile",
  analysis_model = "llama-3.3-70b-versatile",
},
```

**Ollama** (local, no key needed)
```lua
ai = {
  enabled        = true,
  format         = "openai",
  api_key        = "ollama",  -- Ollama ignores the key but the field must be non-empty
  base_url       = "http://localhost:11434/v1/chat/completions",
  model          = "qwen2.5-coder:7b",
  analysis_model = "qwen2.5-coder:7b",
},
```

**AWS Bedrock (Claude via Bedrock)**
```lua
ai = {
  enabled        = true,
  format         = "bedrock",
  api_key_env    = "AWS_SESSION_TOKEN",
  base_url       = "https://bedrock-runtime.us-east-1.amazonaws.com",
  model          = "anthropic.claude-haiku-4-5-20251001",
  analysis_model = "anthropic.claude-sonnet-4-6",
  streaming      = false,  -- set true only if your Bedrock proxy supports SSE
},
```

**Custom gateway (any Anthropic-compatible proxy)**
```lua
ai = {
  enabled     = true,
  format      = "anthropic",
  api_key_env = "MY_GATEWAY_TOKEN",
  base_url    = "https://my-gateway.example.com/v1/messages",
},
```

## Highlight Groups

All highlight groups use `default = true` so your colorscheme takes precedence.

| Group | Default | Purpose |
|-------|---------|---------|
| `GhFileModified` | `DiffChange` | Modified file in picker |
| `GhFileAdded` | `DiffAdd` | Added file in picker |
| `GhFileDeleted` | `DiffDelete` | Deleted file in picker |
| `GhFileRenamed` | `DiffText` | Renamed file in picker |
| `GhStatAdd` | `#40a060` | Addition stats |
| `GhStatDel` | `#c04040` | Deletion stats |
| `GhCommentAuthor` | `Special` | Comment author name |
| `GhCommentBody` | `Normal` | Comment body text |
| `GhCommentCode` | `Special` | Inline code in comments |
| `GhCommentBold` | bold | Bold text in comments |
| `GhCommentSuggestion` | `DiffAdd` | Suggestion blocks |
| `GhCommentResolved` | `Comment` | Resolved thread text |
| `GhCommentLink` | `Underlined` | Link text in comments |
| `GhCommentLinkUrl` | `Comment` | Link URL in comments |
| `GhSignComment` | `DiagnosticSignInfo` | Comment sign |
| `GhSignUnresolved` | `DiagnosticSignWarn` | Unresolved comment sign |
| `GhSignPending` | `DiagnosticSignHint` | Pending comment sign |

## License

MIT
