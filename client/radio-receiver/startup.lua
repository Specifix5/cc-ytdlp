term.clear()
term.setCursorPos(1, 1)

local monitors = { peripheral.find("monitor") }

local logo = [[fffffffffffffffffffffffffffffffffff
fff000ff0ffff0f00000ff0ffff0f00000f
ff0fff0ffffff0ffffff0f0fff0ffffffff
f0ffffff0fffffffffff0fffff0ffffffff
f0ffffff0ffff0f00000fff0fffff00000f
f0ffffff0ffff0f0ffff0ff0f0fffffffff
ff0fff0ff0fff0f0ffff0ff0f0fffffffff
fff000ffff000ff0ffff0fff0ffff00000f
]]
monitors[1].clear()
monitors[1].setCursorPos(1, 1)
monitors[1].setTextScale(0.5)
local img = paintutils.parseImage(logo)
paintutils.drawImage(img, 1, 1)

monitors[1].setCursorPos(1, 10)
monitors[1].write("  CURVE Radio System, by Specifix")

term.setCursorPos(1, 10)
term.write("  CURVE Radio System, by Specifix")

term.redirect(monitors[1])
paintutils.drawImage(img, 1, 1)

os.sleep(1)

shell.run("wget run https://raw.githubusercontent.com/Specifix5/cc-ytdlp/main/client/radio-receiver/radio.lua")
