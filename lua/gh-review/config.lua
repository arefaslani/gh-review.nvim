local M = {}

M.defaults = {
  gh_cmd = "gh",

  -- Snacks picker sidebar
  picker = {
    width = 35,            -- sidebar width in columns
    position = "left",     -- "left" or "right"
  },

  -- Diff behavior
  diff_algorithm = "histogram",
  diff_context_lines = 6,

  -- Buffer naming convention prefixes
  buf_prefix = {
    base = "base://",
    pr = "pr://",
  },

  -- Keymaps (set to false to disable individual bindings)
  keymaps = {
    -- Snacks picker sidebar
    toggle_picker   = "t",
    toggle_explorer = "<leader>e",

    -- Navigation (set on diff buffers)
    next_file      = "]f",
    prev_file      = "[f",
    next_comment   = "]x",
    prev_comment   = "[x",

    -- Commit review mode
    toggle_review_mode = "<leader>cm",
    next_commit        = "]g",
    prev_commit        = "[g",

    -- Comments (set on diff buffers)
    add_comment         = "<leader>cc",
    add_single_comment  = "<leader>ca",

    reply_thread        = "<leader>cr",
    delete_comment      = "<leader>cd",
    edit_comment        = "<leader>ce",
    resolve_thread      = "<leader>cx",
    toggle_comments     = "<leader>ct",

    -- Review
    toggle_viewed  = "<leader>cv",
    submit_review  = "<leader>rs",

    -- Edit
    edit_file      = "<CR>",
    open_in_browser = "o",

    -- General
    close          = "q",
    refresh        = "R",
  },

  -- Signs
  signs = {
    comment  = "",
    pending  = "",
    resolved = "",
  },

  -- AI features (disabled by default — set enabled=true and export ANTHROPIC_API_KEY)
  ai = {
    enabled          = false,
    model            = "claude-haiku-4-5-20251001",   -- fast model for interactive features
    analysis_model   = "claude-sonnet-4-6",           -- deeper model for analyze_file
    api_key_env      = "ANTHROPIC_API_KEY",           -- env var name to read key from
    api_key          = nil,                            -- or set key directly: api_key = "sk-ant-..."
    base_url         = "https://api.anthropic.com/v1/messages",  -- override for custom gateways
    -- format: controls the wire protocol used to talk to the AI backend.
    --   "anthropic" (default) — Anthropic Messages API (x-api-key auth, model in body)
    --   "bedrock"             — AWS Bedrock (Bearer auth, model in URL, anthropic_version in body)
    --   "openai"              — OpenAI-compatible API (Bearer auth, model in body, system as message).
    --                           Works with OpenAI, Groq, Mistral, Together AI, Ollama, LM Studio,
    --                           and Gemini (via its OpenAI-compatible endpoint).
    format           = "anthropic",
    -- streaming: set to false if your gateway does not support SSE
    -- (e.g. AWS Bedrock invoke-with-response-stream requires special auth some proxies lack).
    -- When false, all AI features use a single buffered request instead of SSE.
    streaming        = true,
    max_tokens       = 4096,
    keymaps = {
      explain_selection = "<leader>ae",   -- explain visual selection or current line
      analyze_file      = "<leader>aa",   -- analyze current file diff for issues
      draft_comment     = "<leader>ac",   -- draft a comment for the current line
      review_summary    = "<leader>as",   -- generate PR review summary
      reply_suggestion  = "<leader>ar",   -- suggest reply to thread under cursor
      dismiss           = "<leader>ad",   -- clear AI findings from diff buffers
      chat_open         = "<leader>ai",   -- open multi-turn AI chat for the current PR
    },
  },
}

function M.apply(user_opts)
  return vim.tbl_deep_extend("force", M.defaults, user_opts or {})
end

function M.validate(cfg)
  vim.validate({
    gh_cmd = { cfg.gh_cmd, "string" },
    keymaps = { cfg.keymaps, "table" },
  })
end

return M
