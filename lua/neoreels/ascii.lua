local M = {}
local function render(frame, source_width, source_height, width, height, ramp, color)
  local palette, lines = {}, {}
  local spans = {}
  local scale = math.min(width / source_width, height / source_height)
  local draw_width = math.max(1, math.floor(source_width * scale))
  local draw_height = math.max(1, math.floor(source_height * scale))
  local left = math.floor((width - draw_width) / 2)
  local top = math.floor((height - draw_height) / 2)
  for value = 0, 255 do
    local index = math.floor(value * (#ramp - 1) / 255) + 1
    palette[value] = ramp:sub(index, index)
  end
  for y = 0, height - 1 do
    local row, previous, span = {}, nil, nil
    for x = 0, width - 1 do
      local group
      if x >= left and x < left + draw_width and y >= top and y < top + draw_height then
        local source_x = math.floor((x - left) * source_width / draw_width)
        local source_y = math.floor((y - top) * source_height / draw_height)
        local offset = source_y * source_width + source_x
        if color then
          local r, g, b = frame:byte(offset * 3 + 1, offset * 3 + 3)
          -- Foreground color already carries perceived brightness. Max-channel
          -- glyph density keeps saturated blues and reds visible as ASCII.
          row[x + 1] = palette[math.max(r, g, b)]
          if row[x + 1] ~= " " then
            group = math.floor(r / 51 + 0.5) * 36 + math.floor(g / 51 + 0.5) * 6 + math.floor(b / 51 + 0.5)
          end
        else row[x + 1] = palette[frame:byte(offset + 1)] end
      else row[x + 1] = " " end
      if group ~= nil and group == previous then span.finish = x + 1
      elseif group ~= nil then
        span = { row = y, start = x, finish = x + 1, color = group }
        spans[#spans + 1] = span
      end
      previous = group
    end
    lines[y + 1] = table.concat(row)
  end
  return lines, spans
end

function M.render(frame, source_width, source_height, width, height, ramp)
  return render(frame, source_width, source_height, width, height, ramp, false)
end

function M.render_rgb(frame, source_width, source_height, width, height, ramp)
  return render(frame, source_width, source_height, width, height, ramp, true)
end

function M.setup_colors()
  for r = 0, 5 do
    for g = 0, 5 do
      for b = 0, 5 do
        local index = r * 36 + g * 6 + b
        vim.api.nvim_set_hl(0, "NeoReelsPixel" .. index, {
          fg = string.format("#%02x%02x%02x", r * 51, g * 51, b * 51), ctermfg = 16 + index,
        })
      end
    end
  end
end

return M
