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
--- @param opts? {title?: string}
function M.open(prs, opts)
  opts = opts or {}
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("gh-dash-diff requires snacks.nvim", vim.log.levels.ERROR)
    return
  end

  local items = build_items(prs)
  local picker_ref = nil

  local function do_open(picker_items)
    picker_ref = Snacks.picker.pick({
      source    = "gh_prs",
      title     = opts.title or "GitHub PRs",
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
      },

      win = {
        input = {
          keys = {
            ["<C-r>"] = "refresh_prs",
          },
        },
        list = {
          keys = {
            ["<C-r>"] = "refresh_prs",
          },
        },
      },
    })
  end

  do_open(items)
  return picker_ref
end

return M
