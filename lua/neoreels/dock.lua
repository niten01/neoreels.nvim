local M = {}
local api = vim.api

-- A normal split reserves screen space; the corner float lives entirely inside
-- it. Editor text can then use Neovim's native wrapping instead of being hidden.
function M.open(corner, width)
  local self = { tab = api.nvim_get_current_tabpage(), wrapped = {} }
  self.buf = api.nvim_create_buf(false, true)
  api.nvim_set_option_value("bufhidden", "wipe", { buf = self.buf })
  api.nvim_set_option_value("filetype", "neoreels-dock", { buf = self.buf })
  api.nvim_set_option_value("modifiable", false, { buf = self.buf })
  self.win = api.nvim_open_win(self.buf, false, {
    split = corner:find("right", 1, true) and "right" or "left", win = -1,
    width = width, style = "minimal", noautocmd = true,
  })
  for name, value in pairs({ winfixwidth = true, winbar = "", wrap = false,
    signcolumn = "no", winhighlight = "Normal:NeoReels,EndOfBuffer:NeoReels" }) do
    api.nvim_set_option_value(name, value, { win = self.win })
  end

  function self:wrap_editors()
    if not api.nvim_tabpage_is_valid(self.tab) then return end
    for _, win in ipairs(api.nvim_tabpage_list_wins(self.tab)) do
      if win ~= self.win and api.nvim_win_get_config(win).relative == "" then
        local buf = api.nvim_win_get_buf(win)
        if api.nvim_get_option_value("buftype", { buf = buf }) == "" and self.wrapped[win] == nil then
          self.wrapped[win] = api.nvim_get_option_value("wrap", { win = win })
          api.nvim_set_option_value("wrap", true, { win = win })
        end
      end
    end
  end

  function self:close()
    for win, original in pairs(self.wrapped) do
      if api.nvim_win_is_valid(win) and api.nvim_get_option_value("wrap", { win = win }) then
        api.nvim_set_option_value("wrap", original, { win = win })
      end
    end
    if api.nvim_win_is_valid(self.win) then pcall(api.nvim_win_close, self.win, true) end
    if api.nvim_buf_is_valid(self.buf) then pcall(api.nvim_buf_delete, self.buf, { force = true }) end
  end

  self:wrap_editors()
  return self
end

return M
