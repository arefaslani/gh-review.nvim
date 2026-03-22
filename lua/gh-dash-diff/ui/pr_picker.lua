local M = {}

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
--- @param opts? {title?: string, owner?: string, repo?: string}
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

  local items = build_items(prs)
  local picker_ref = nil
  local active_filter = opts._active_filter or nil  -- track current filter for toggling

  local function get_title(filter_label)
    local base = opts.title or "GitHub PRs"
    if filter_label and filter_label ~= "" then
      return base .. "  [" .. filter_label .. "]"
    end
    return base
  end

  --- Close the current picker, re-fetch with a search query, and reopen.
  --- If the same filter is already active, clear it instead (toggle behavior).
  local function reopen_with_search(search_query, filter_label)
    if picker_ref then picker_ref:close() end
    if not (owner and repo) then
      vim.notify("gh-dash-diff: owner/repo not available for search", vim.log.levels.WARN)
      return
    end

    -- Toggle: if same filter is active, clear it
    if active_filter == search_query then
      prs_mod.list(owner, repo, nil, function(err2, new_prs)
        if err2 then
          vim.notify("gh-dash-diff: " .. err2, vim.log.levels.ERROR)
          return
        end
        M.open(new_prs or {}, vim.tbl_extend("force", opts, {
          title = opts.title or "GitHub PRs",
          _active_filter = nil,
        }))
      end)
      return
    end

    prs_mod.list(owner, repo, { search = search_query }, function(err2, new_prs)
      if err2 then
        vim.notify("gh-dash-diff: search error: " .. err2, vim.log.levels.ERROR)
        return
      end
      M.open(new_prs or {}, vim.tbl_extend("force", opts, {
        title = get_title(filter_label or search_query),
        _active_filter = search_query,
      }))
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

  local function do_open(picker_items)
    picker_ref = Snacks.picker.pick({
      source    = "gh_prs",
      title     = get_title(),
      items     = picker_items,

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
        require("gh-dash-diff").open_pr(item.number)
      end,

      actions = {
        refresh_prs = function(_picker)
          _picker:close()
          require("gh-dash-diff").open_dash()
        end,
        filter_author_me = function(_picker)
          reopen_with_search("author:@me", "author:@me")
        end,
        filter_open = function(_picker)
          reopen_with_search("is:open", "is:open")
        end,
        filter_closed = function(_picker)
          reopen_with_search("is:closed", "is:closed")
        end,
        filter_review_requested = function(_picker)
          reopen_with_search("review-requested:@me", "review-requested:@me")
        end,
      },
    })

    -- Bypass Snacks win.input.keys / win.list.keys (unreliable for custom actions).
    -- Set raw vim keymaps on picker buffers — same pattern as ui/picker.lua.
    if picker_ref then
      local function get_input_query()
        local input_win = picker_ref.layout and picker_ref.layout.wins and picker_ref.layout.wins.input
        if input_win and input_win:valid() then
          return vim.api.nvim_buf_get_lines(input_win.buf, 0, -1, false)[1] or ""
        end
        if picker_ref.input and picker_ref.input.buf
          and vim.api.nvim_buf_is_valid(picker_ref.input.buf) then
          return vim.api.nvim_buf_get_lines(picker_ref.input.buf, 0, -1, false)[1] or ""
        end
        return ""
      end

      local function set_filter_keys(buf)
        local o = { buffer = buf, silent = true }
        vim.keymap.set({ "n", "i" }, "<C-r>", function()
          if picker_ref then picker_ref:close() end
          require("gh-dash-diff").open_dash()
        end, o)
        vim.keymap.set({ "n", "i" }, "<C-a>", function()
          reopen_with_search("author:@me", "author:@me")
        end, o)
        vim.keymap.set({ "n", "i" }, "<C-o>", function()
          reopen_with_search("is:open", "is:open")
        end, o)
        vim.keymap.set({ "n", "i" }, "<C-x>", function()
          reopen_with_search("is:closed", "is:closed")
        end, o)
        vim.keymap.set({ "n", "i" }, "<C-n>", function()
          reopen_with_search("review-requested:@me", "review-requested:@me")
        end, o)
        vim.keymap.set({ "n", "i" }, "<C-g>", function()
          local query = get_input_query()
          if query:find(":") then
            reopen_with_search(query, query)
          end
        end, o)
      end

      local list_win = picker_ref.layout and picker_ref.layout.wins and picker_ref.layout.wins.list
      if list_win and list_win:valid() then
        set_filter_keys(list_win.buf)
      end

      local input_win = picker_ref.layout and picker_ref.layout.wins and picker_ref.layout.wins.input
      if input_win and input_win:valid() then
        set_filter_keys(input_win.buf)
      end
    end
  end

  do_open(items)
  return picker_ref
end

return M
