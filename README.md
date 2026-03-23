# gh-review.nvim

A Neovim plugin for reviewing GitHub Pull Requests with side-by-side diffs, inline comments, and review submission — all without leaving your editor.

## Features

- **PR browser** — Snacks picker with fuzzy search and composable filters (`author:@me`, `is:open`, etc.)
- **Side-by-side diff** — Native Neovim `diffthis` with syntax highlighting
- **File explorer** — Sidebar with directory tree grouping, diff stats, and viewed indicators
- **Inline comments** — View, add, reply, and delete review comments as virtual text
- **Review submission** — Submit approvals, request changes, or comment from within Neovim
- **Commit-by-commit review** — Toggle between full-PR and per-commit diff modes
- **Viewed file tracking** — Mark files as reviewed, synced with GitHub's viewed state
- **Edit and resume** — Jump to editing a file, then resume the review where you left off

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
| `<C-g>` | Manual search query (any GitHub qualifier) |
| `<C-r>` | Refresh / clear filters |

### Diff View

| Key | Action |
|-----|--------|
| `]f` / `[f` | Next / previous file |
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
| `<leader>cr` | Reply to thread |
| `<leader>cd` | Delete pending comment |
| `<leader>ct` | Toggle comment visibility |

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
    add_suggestion     = "<leader>cs",
    reply_thread       = "<leader>cr",
    delete_comment     = "<leader>cd",
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
})
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
| `GhSignComment` | `DiagnosticSignInfo` | Comment sign |
| `GhSignUnresolved` | `DiagnosticSignWarn` | Unresolved comment sign |
| `GhSignPending` | `DiagnosticSignHint` | Pending comment sign |

## License

MIT
