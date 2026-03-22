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
  local debounce_timer = nil

  local function get_title(filter_label)
    local base = opts.title or "GitHub PRs"
    if filter_label and filter_label ~= "" then
      return base .. "  [" .. filter_label .. "]"
    end
    return base
  end

  --- Close the current picker, re-fetch with a search query, and reopen.
  local function reopen_with_search(search_query, filter_label)
    if picker_ref then picker_ref:close() end
    if not (owner and repo) then
      vim.notify("gh-dash-diff: owner/repo not available for search", vim.log.levels.WARN)
      return
    end
    prs_mod.list(owner, repo, { search = search_query }, function(err2, new_prs)
      if err2 then
        vim.notify("gh-dash-diff: search error: " .. err2, vim.log.levels.ERROR)
        return
      end
      M.open(new_prs or {}, vim.tbl_extend("force", opts, {
        title = get_title(filter_label or search_query),
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
        gh_search = function(_picker)
          -- Manually trigger a GitHub search using the current input text.
          local query = ""
          if _picker.input and _picker.input.filter then
            query = _picker.input.filter.text or ""
          end
          if query:find(":") and owner and repo then
            reopen_with_search(query, query)
          end
        end,
      },

      win = {
        input = {
          keys = {
            ["<C-r>"] = "refresh_prs",
            ["<C-a>"] = "filter_author_me",
            ["<C-o>"] = "filter_open",
            ["<C-x>"] = "filter_closed",
            ["<C-m>"] = "filter_review_requested",
            ["<C-g>"] = "gh_search",
          },
        },
        list = {
          keys = {
            ["<C-r>"] = "refresh_prs",
            ["<C-a>"] = "filter_author_me",
            ["<C-o>"] = "filter_open",
            ["<C-x>"] = "filter_closed",
            ["<C-m>"] = "filter_review_requested",
          },
        },
      },
    })

    -- Set up debounced input watcher so GitHub search qualifiers trigger a re-fetch.
    if owner and repo then
      vim.defer_fn(function()
        if not picker_ref then return end
        local input_buf = picker_ref.input and picker_ref.input.buf
        if not input_buf or not vim.api.nvim_buf_is_valid(input_buf) then return end

        local last_query = ""
        vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
          buffer = input_buf,
          callback = function()
            if not picker_ref then return end
            local query = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)[1] or ""
            if query == last_query or not query:find(":") then return end
            last_query = query

            if debounce_timer then
              debounce_timer:stop()
              debounce_timer:close()
            end
            debounce_timer = vim.uv.new_timer()
            debounce_timer:start(500, 0, vim.schedule_wrap(function()
              if debounce_timer then debounce_timer:close(); debounce_timer = nil end
              if not picker_ref then return end
              reopen_with_search(query, query)
            end))
          end,
        })
      end, 100)
    end
  end

  do_open(items)
  return picker_ref
end

return M
