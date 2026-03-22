local M = {}

M.state = {
  -- Repository context (populated on first use)
  repo = { owner = nil, name = nil, branch = nil, root = nil },

  -- Current PR session
  pr = {
    number = nil, title = nil,
    head_ref = nil, base_ref = nil, head_sha = nil, base_sha = nil,
    files = {},        -- GhFile[] from API
    current_idx = 0,   -- 1-based index into files
  },

  -- Review state
  review = {
    pending_id = nil,
    pending_comments = {},   -- PendingComment[]
    threads = {},            -- GhThread[]
    comments_visible = true,
    viewed_files = {},       -- set of filenames marked as viewed
  },

  -- Window/buffer handles
  layout = {
    tab = nil,               -- tabpage handle
    picker = nil,            -- Snacks picker instance (has :focus(), :close(), etc.)
    left_win = nil,          -- base diff window
    right_win = nil,         -- PR diff window
    left_buf = nil,          -- base diff buffer
    right_buf = nil,         -- PR diff buffer
    last_diff_win = nil,     -- last focused diff win (for t toggle)
    all_bufs = {},           -- all created buffers for cleanup
    ready = false,           -- set true after layout is fully open
  },

  -- Extmark namespace handles (created once, reused)
  ns = { comments = nil, signs = nil, eol = nil },
}

function M.reset()
  local ns = M.state.ns
  -- Reset to fresh defaults while preserving namespace handles
  M.state = {
    repo = { owner = nil, name = nil, branch = nil, root = nil },
    pr = {
      number = nil, title = nil,
      head_ref = nil, base_ref = nil, head_sha = nil, base_sha = nil,
      files = {},
      current_idx = 0,
    },
    review = {
      pending_id = nil,
      pending_comments = {},
      threads = {},
      comments_visible = true,
      viewed_files = {},
    },
    layout = {
      tab = nil,
      picker = nil,
      left_win = nil,
      right_win = nil,
      left_buf = nil,
      right_buf = nil,
      last_diff_win = nil,
      all_bufs = {},
      ready = false,
    },
    ns = ns,
  }
end

return M
