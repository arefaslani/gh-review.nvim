local M = {}

local highlights = {
  -- Picker file status icons
  GhFileModified    = { link = "DiffChange",          default = true },
  GhFileAdded       = { link = "DiffAdd",             default = true },
  GhFileDeleted     = { link = "DiffDelete",          default = true },
  GhFileRenamed     = { link = "DiffText",            default = true },

  -- Picker diff stats
  GhStatAdd         = { fg = "#40a060",               default = true },
  GhStatDel         = { fg = "#c04040",               default = true },

  -- Comment virtual lines
  GhCommentSeparator  = { link = "Comment",            default = true },
  GhCommentAuthor     = { link = "Special", bold = true, default = true },
  GhCommentDate       = { link = "Comment",             default = true },
  GhCommentBody       = { link = "Normal",              default = true },
  GhCommentResolved   = { link = "Comment", italic = true, default = true },
  GhCommentCount      = { link = "Comment",             default = true },
  GhCommentCode       = { bg = "#2a2a3a", fg = "#c0c0d0", default = true },
  GhCommentCodeFence  = { fg = "#606080", italic = true,  default = true },
  GhCommentBold       = { bold = true,                  default = true },
  GhCommentSuggestion = { link = "DiffAdd",             default = true },
  GhCommentLink       = { link = "Underlined",          default = true },
  GhCommentLinkUrl    = { link = "Comment",             default = true },

  -- Comment input floating window
  GhCommentInput    = { link = "NormalFloat",         default = true },
  GhCommentInputBorder = { link = "FloatBorder",      default = true },

  -- Sign column
  GhSignComment     = { link = "DiagnosticSignInfo",  default = true },
  GhSignUnresolved  = { link = "DiagnosticSignWarn",  default = true },
  GhSignPending     = { link = "DiagnosticSignHint",  default = true },

  -- Ghost completion (author filter)
  GhGhostText       = { link = "Comment", italic = true, default = true },
}

local function apply()
  for name, opts in pairs(highlights) do
    vim.api.nvim_set_hl(0, name, opts)
  end
end

function M.setup()
  apply()

  -- Re-apply when colorscheme changes
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("GhReviewHighlights", { clear = true }),
    callback = apply,
  })
end

return M
