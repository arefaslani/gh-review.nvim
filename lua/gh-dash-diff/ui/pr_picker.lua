local M = {}

-- Module-level filter state — survives recursive M.open calls.
-- Keys are qualifier strings (e.g. "author:@me"), values are true.
local _active_filters = {}
local _filter_ns = vim.api.nvim_create_namespace("gh-pr-picker-filter")

--- Build the combined search string from active filters.
local function build_search()
  local parts = {}
  for q, _ in pairs(_active_filters) do
    table.insert(parts, q)
  end
  if #parts == 0 then return nil end
  table.sort(parts)
  return table.concat(parts, " ")
end

--- Build a display label for the active filters.
local function filter_label()
  local s = build_search()
  return s or ""
end

local REVIEW_ICONS = {
  APPROVED           = "✔",
  CHANGES_REQUESTED  = "✗",
  REVIEW_REQUIRED    = "○",
  draft              = "◌",
}

--- Format PR stats as "+42/-10"
local function fmt_stats(pr)
  return string.format("+%d/-%d", pr.additions or 0, pr.deletions or 0)
end

--- Get review status icon for a PR.
local function review_icon(pr)
  if pr.isDraft then return REVIEW_ICONS.draft end
  return REVIEW_ICONS[pr.reviewDecision] or REVIEW_ICONS.REVIEW_REQUIRED
end

--- Build picker items from a PR list.
--- @param prs table[]
--- @return table[]
local function build_items(prs)
  local items = {}
  for i, pr in ipairs(prs) do
    local author = pr.author and pr.author.login or "unknown"
    table.insert(items, {
      idx       = i,
      text      = string.format("#%d %s @%s", pr.number, pr.title, author),
      number    = pr.number,
      title     = pr.title,
      author    = author,
      icon      = review_icon(pr),
      stats     = fmt_stats(pr),
      body      = pr.body or "",
      isDraft   = pr.isDraft,
      _pr       = pr,
    })
  end
  return items
end

--- Open a Snacks picker to browse PRs.
--- @param prs table[] List of PRs from gh/prs.lua
--- @param opts? {title?: string, owner?: string, repo?: string, _base_title?: string}
function M.open(prs, opts)
  opts = opts or {}
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("gh-dash-diff requires snacks.nvim", vim.log.levels.ERROR)
    return
  end

  local owner = opts.owner
  local repo  = opts.repo
  local prs_mod = require("gh-dash-diff.gh.prs")
  local base_title = opts._base_title or opts.title or "GitHub PRs"

  local function get_title()
    local label = filter_label()
    if label ~= "" then
      return base_title .. "  [" .. label .. "]"
    end
    return base_title
  end

  local picker_ref = nil

  --- Toggle a single qualifier in the active filters and re-fetch PRs.
  local function toggle_filter(qualifier)
    if picker_ref then picker_ref:close() end
    if not (owner and repo) then
      vim.notify("gh-dash-diff: owner/repo not available for search", vim.log.levels.WARN)
      return
    end

    -- Toggle this qualifier
    if _active_filters[qualifier] then
      _active_filters[qualifier] = nil
    else
      _active_filters[qualifier] = true
    end

    local search = build_search()
    local list_opts = search and { search = search } or nil
    prs_mod.list(owner, repo, list_opts, function(err, new_prs)
      if err then
        vim.notify("gh-dash-diff: " .. err, vim.log.levels.ERROR)
        return
      end
      M.open(new_prs or {}, { owner = owner, repo = repo, _base_title = base_title })
    end)
  end

  --- Replace all filters with a manual search query.
  local function do_manual_search(query)
    if picker_ref then picker_ref:close() end
    if not (owner and repo) then return end

    -- Parse query into individual qualifiers and set them as active filters
    _active_filters = {}
    for word in query:gmatch("%S+") do
      if word:find(":") then
        _active_filters[word] = true
      end
    end

    local search = build_search()
    local list_opts = search and { search = search } or nil
    prs_mod.list(owner, repo, list_opts, function(err, new_prs)
      if err then
        vim.notify("gh-dash-diff: " .. err, vim.log.levels.ERROR)
        return
      end
      M.open(new_prs or {}, { owner = owner, repo = repo, _base_title = base_title })
    end)
  end

  -- Cached contributor logins for the current repo, populated asynchronously.
  local contributor_logins = {}
  if owner and repo then
    prs_mod.list_contributors(owner, repo, function(err, logins)
      if not err and logins then contributor_logins = logins end
    end)
  end

  local function build_hint_line()
    local first = contributor_logins[1]
    local author_hint = first and ("author:" .. first) or "author:@me"
    return "Tip: " .. author_hint .. "  is:open  is:closed  review-requested:@me"
  end

  local items = build_items(prs)

  picker_ref = Snacks.picker.pick({
    source    = "gh_prs",
    title     = get_title(),
    items     = items,

    layout = {
      preset  = "dropdown",
      preview = true,
      width   = 0.7,
      height  = 0.6,
    },

    format = function(item, _picker)
      local num_hl  = "Special"
      local icon_hl = item.isDraft and "Comment"
        or (item.icon == REVIEW_ICONS.APPROVED and "GhStatAdd"
        or  (item.icon == REVIEW_ICONS.CHANGES_REQUESTED and "GhStatDel"
        or   "Normal"))
      return {
        { string.format("#%-4d ", item.number), num_hl },
        { item.icon .. " ",                     icon_hl },
        { item.title .. "  ",                   "Normal" },
        { "@" .. item.author .. "  ",           "Comment" },
        { item.stats,                            "Comment" },
      }
    end,

    preview = function(ctx)
      local item = ctx.item
      if not item then return end
      local pr = item._pr
      local lines = {
        string.format("# PR #%d: %s", pr.number, pr.title),
        "",
        string.format("Author : @%s", item.author),
        string.format("Branch : %s → %s", pr.headRefName or "?", pr.baseRefName or "?"),
        string.format("Status : %s %s", item.icon,
          pr.isDraft and "Draft" or (pr.reviewDecision or "No review")),
        string.format("Changes: %s (%d files)", item.stats, pr.changedFiles or 0),
        "",
      }
      if pr.body and pr.body ~= "" then
        for _, line in ipairs(vim.split(pr.body, "\n", { plain = true })) do
          table.insert(lines, line)
        end
      else
        table.insert(lines, "_No description provided._")
      end
      table.insert(lines, "")
      table.insert(lines, "---")
      table.insert(lines, build_hint_line())
      ctx.preview:set_lines(lines)
      ctx.preview:highlight({ ft = "markdown" })
    end,

    confirm = function(_picker, item)
      if not item then return end
      _picker:close()
      _active_filters = {}
      require("gh-dash-diff").open_pr(item.number)
    end,

    actions = {
      refresh_prs = function(_picker)
        _picker:close()
        _active_filters = {}
        require("gh-dash-diff").open_dash()
      end,
    },
  })

  -- Set raw keymaps on picker buffers (Snacks action resolution is unreliable for these).
  if picker_ref then
    local function get_input_query()
      local input_win = picker_ref.layout and picker_ref.layout.wins and picker_ref.layout.wins.input
      if input_win and input_win:valid() then
        return vim.api.nvim_buf_get_lines(input_win.buf, 0, -1, false)[1] or ""
      end
      return ""
    end

    local function set_filter_keys(buf)
      local o = { buffer = buf, silent = true }
      vim.keymap.set({ "n", "i" }, "<C-r>", function()
        if picker_ref then picker_ref:close() end
        _active_filters = {}
        require("gh-dash-diff").open_dash()
      end, o)
      vim.keymap.set({ "n", "i" }, "<C-a>", function()
        toggle_filter("author:@me")
      end, o)
      vim.keymap.set({ "n", "i" }, "<C-o>", function()
        toggle_filter("is:open")
      end, o)
      vim.keymap.set({ "n", "i" }, "<C-x>", function()
        toggle_filter("is:closed")
      end, o)
      vim.keymap.set({ "n", "i" }, "<C-n>", function()
        toggle_filter("review-requested:@me")
      end, o)
      vim.keymap.set({ "n", "i" }, "<C-g>", function()
        -- First try reading from the picker input (user may have typed a query)
        local query = get_input_query()
        if query ~= "" and query:find(":") then
          do_manual_search(query)
          return
        end
        -- Otherwise prompt for a manual search query
        vim.ui.input({ prompt = "Search qualifiers (e.g. author:user is:open): " }, function(input)
          if input and input ~= "" then
            do_manual_search(input)
          end
        end)
      end, o)
    end

    local list_win = picker_ref.layout and picker_ref.layout.wins and picker_ref.layout.wins.list
    if list_win and list_win:valid() then
      set_filter_keys(list_win.buf)
    end

    local input_win = picker_ref.layout and picker_ref.layout.wins and picker_ref.layout.wins.input
    if input_win and input_win:valid() then
      set_filter_keys(input_win.buf)
      -- Show active filters as virtual text (doesn't interfere with fuzzy matching)
      local label = filter_label()
      if label ~= "" then
        vim.api.nvim_buf_set_extmark(input_win.buf, _filter_ns, 0, 0, {
          virt_text = { { " filter: " .. label, "Comment" } },
          virt_text_pos = "right_align",
        })
      end
    end
  end

  return picker_ref
end

return M
