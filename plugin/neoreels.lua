if vim.g.loaded_neoreels then return end
vim.g.loaded_neoreels = true

vim.api.nvim_create_user_command("NeoReelsPlay", function()
  require("neoreels").play()
end, { desc = "Play your personalized Instagram Reels feed" })
vim.api.nvim_create_user_command("NeoReelsPause", function()
  require("neoreels").pause()
end, { desc = "Pause or resume ASCII video playback" })
vim.api.nvim_create_user_command("NeoReelsStop", function()
  require("neoreels").stop()
end, { desc = "Close the player and stop FFmpeg" })
vim.api.nvim_create_user_command("NeoReelsResize", function(command)
  if #command.fargs ~= 2 then vim.notify("neoreels: Use :NeoReelsResize WIDTH HEIGHT", vim.log.levels.ERROR); return end
  local ok, err = pcall(require("neoreels").resize, tonumber(command.fargs[1]), tonumber(command.fargs[2]))
  if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
end, { nargs = "+", desc = "Resize the video window without restarting playback" })
vim.api.nvim_create_user_command("NeoReelsNext", function()
  if not require("neoreels").next() then vim.notify("neoreels: No next Reel is queued") end
end, { desc = "Skip to the next queued Reel" })
vim.api.nvim_create_user_command("NeoReelsWrap", function()
  local enabled = require("neoreels").toggle_wrap()
  vim.notify("neoreels: Wrap mode " .. (enabled and "enabled" or "disabled"))
end, { desc = "Toggle reserved space and buffer wrapping without restarting playback" })
