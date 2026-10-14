local M = {}
local api = vim.api
local spinner = { "|", "/", "-", "\\" }

local function wrap(message, width)
  local lines, current = {}, ""
  for word in message:gmatch("%S+") do
    if #current + #word + 1 > width and current ~= "" then lines[#lines + 1], current = current, "" end
    current = current == "" and word or current .. " " .. word
    while #current > width do
      lines[#lines + 1], current = current:sub(1, width), current:sub(width + 1)
    end
  end
  if current ~= "" then lines[#lines + 1] = current end
  return lines
end

function M.render(s)
  if not api.nvim_win_is_valid(s.win) or not api.nvim_buf_is_valid(s.buf) then return end
  local geometry = api.nvim_win_get_config(s.win)
  local width, height = geometry.width, geometry.height
  local available = math.max(1, width - 4)
  local content = wrap(s.message or "Fetching your next Reel", available)
  if s.status ~= "error" then
    local tick = math.floor(((vim.uv or vim.loop).hrtime() - s.loading_started) / 100000000)
    content[#content + 1] = ""
    if s.progress then
      local percent = math.max(0, math.min(100, math.floor(s.progress)))
      local length = math.max(1, math.min(22, available - 8))
      local filled = math.floor(length * percent / 100)
      content[#content + 1] = ("[" .. string.rep("=", filled) .. string.rep(" ", length - filled) .. "] " .. percent .. "%"):sub(1, available)
    else
      local seconds = math.floor(((vim.uv or vim.loop).hrtime() - s.loading_started) / 1000000000)
      content[#content + 1] = (spinner[tick % #spinner + 1] .. "  " .. seconds .. "s"):sub(1, available)
    end
  end
  local lines = {}
  for _ = 1, height do lines[#lines + 1] = string.rep(" ", width) end
  local top = math.max(0, math.floor((height - #content) / 2))
  for i, line in ipairs(content) do
    if top + i > height then break end
    local left = math.max(0, math.floor((width - #line) / 2))
    lines[top + i] = string.rep(" ", left) .. line .. string.rep(" ", math.max(0, width - left - #line))
  end
  api.nvim_set_option_value("modifiable", true, { buf = s.buf })
  api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = s.buf })
end

return M
