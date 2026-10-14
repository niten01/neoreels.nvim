local M = {}
local api = vim.api
local description = "NeoReels resize handle"

-- Intercept only the free corner, pass every other event to Neovim, and never
-- replace existing mouse mappings. Mappings exist only while a player is open.
function M.attach(get_player, on_resize)
  local installed, drag = {}, nil
  local pending
  local function mouse_key(key)
    local s, geometry, corner = get_player()
    if not s or not geometry or geometry.border == "none" then return key end
    local pos = vim.fn.getmousepos()
    local right = corner:find("right", 1, true) ~= nil
    local bottom = corner:find("bottom", 1, true) ~= nil
    if key == "<LeftMouse>" then
      local row = geometry.row + 1 + (bottom and 0 or geometry.height + 1)
      local col = geometry.col + 1 + (right and 0 or geometry.width + 1)
      if math.abs(pos.screenrow - row) > 1 or math.abs(pos.screencol - col) > 1 then return key end
      drag = { player = s, row = pos.screenrow, col = pos.screencol,
        width = geometry.width, height = geometry.height, right = right, bottom = bottom }
      return ""
    end
    if not drag or drag.player ~= s then return key end
    local width = drag.width + (pos.screencol - drag.col) * (drag.right and -1 or 1)
    local height = drag.height + (pos.screenrow - drag.row) * (drag.bottom and -1 or 1)
    pending = { player = s, width = math.max(4, math.min(240, width)), height = math.max(4, math.min(120, height)) }
    vim.schedule(function()
      if not pending then return end
      local change = pending
      pending = nil
      local current = get_player()
      if current == change.player then on_resize(change.width, change.height) end
    end)
    if key == "<LeftRelease>" then drag = nil end
    return ""
  end
  for _, mode in ipairs({ "n", "i", "x" }) do
    local available = true
    for _, key in ipairs({ "<LeftMouse>", "<LeftDrag>", "<LeftRelease>" }) do
      if next(vim.fn.maparg(key, mode, false, true)) then available = false end
    end
    if available then
      for _, key in ipairs({ "<LeftMouse>", "<LeftDrag>", "<LeftRelease>" }) do
        vim.keymap.set(mode, key, function() return mouse_key(key) end, { expr = true, desc = description })
        installed[#installed + 1] = { mode, key }
      end
    end
  end
  return function()
    pending, drag = nil, nil
    for _, mapping in ipairs(installed) do
      if vim.fn.maparg(mapping[2], mapping[1], false, true).desc == description then
        vim.keymap.del(mapping[1], mapping[2])
      end
    end
  end
end

return M
