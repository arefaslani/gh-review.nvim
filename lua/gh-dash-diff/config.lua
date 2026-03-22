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
    toggle_picker  = "t",

    -- Navigation (set on diff buffers)
    next_file      = "]f",
    prev_file      = "[f",
    next_comment   = "]x",
    prev_comment   = "[x",

    -- Comments (set on diff buffers)
    add_comment    = "<leader>cc",
    add_suggestion = "<leader>cs",
    reply_thread   = "<leader>cr",
    delete_comment = "<leader>cd",
    toggle_comments = "<leader>ct",

    -- Review
    submit_review  = "<leader>rs",

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
