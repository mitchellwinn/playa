-- Headless test: aseprite -b --script-param root=<repo> --script-param out=<dir> --script test/run.lua
local root, out = app.params.root, app.params.out
PLAYA_PATH = app.fs.joinPath(root, "src")
local codec = dofile(app.fs.joinPath(PLAYA_PATH, "codec.lua"))
local recorder = dofile(app.fs.joinPath(PLAYA_PATH, "recorder.lua"))
local player = dofile(app.fs.joinPath(PLAYA_PATH, "player.lua"))
local export = dofile(app.fs.joinPath(PLAYA_PATH, "export.lua"))

local fails = 0
local function check(cond, msg)
  if cond then print("ok   " .. msg) else print("FAIL " .. msg) fails = fails + 1 end
end

-- codec round trips
for _, s in ipairs{ "", "abcd", string.rep("\0\0\0\0", 300), "\1\2\3\4\5\6\7\8\1\2\3\4",
                    string.rep("wxyz", 129) .. "abcd" .. string.rep("q", 4 * 700) } do
  check(codec.decode(codec.encode(s)) == s, "codec round trip len " .. #s)
end
for n = 0, 5 do
  local s = string.rep("\255", n)
  check(codec.unb64(codec.b64(s)) == s, "b64 len " .. n)
end

-- record a session
local spr = Sprite(48, 32)
local rec = recorder.load(spr)
spr.events:on("change", function(ev) rec:onChange(ev) end)
app.events:on("beforecommand", function(ev)
  if ev.name == "Undo" then rec.pending = "u" elseif ev.name == "Redo" then rec.pending = "r" end
end)
app.events:on("aftercommand", function() rec.pending = nil end)
rec:start()

local red, green, blue = Color{ r = 255, g = 0, b = 0, a = 255 }, Color{ r = 0, g = 200, b = 0, a = 255 }, Color{ r = 0, g = 0, b = 255, a = 255 }
app.useTool{ tool = "pencil", color = red, points = { Point(2, 2), Point(20, 10) } }
app.useTool{ tool = "pencil", color = green, points = { Point(5, 20), Point(40, 25) } }
app.command.Undo()                                          -- green undone
app.useTool{ tool = "rectangle", color = blue, points = { Point(30, 2), Point(44, 14) } }
app.command.Undo()
app.command.Redo()                                          -- blue kept
app.useTool{ tool = "pencil", color = green, points = { Point(1, 30), Point(47, 30) } }

local final = recorder.composite(spr, 1)
check(#rec.lines >= 6, "logged lines: " .. #rec.lines)

rec:save()
local file = app.fs.joinPath(out, "rec.aseprite")
spr:saveAs(file)
spr:close()

local s2 = app.open(file)
local rec2 = recorder.load(s2)
check(#rec2.lines == #rec.lines, "lines survive save/reload")

local entries = player.parse(rec2.lines)
check(#entries == #rec2.lines, "all lines parse")

player.showAll(entries)
local p = player.new(entries, s2.width, s2.height)
check(p:seek(p:total()).bytes == final, "full replay matches final canvas")

player.hideUndone(entries)
p:refresh()
check(p:seek(p:total()).bytes == final, "replay without undone strokes matches final canvas")
local hidden = 0
for _, e in ipairs(entries) do if e.hidden then hidden = hidden + 1 end end
check(hidden == 4, "two undo pairs hidden (got " .. hidden .. ")")

-- seek backward rewinds
local mid = p:seek(1).bytes
check(mid ~= final, "first step differs from final")
check(p:seek(p:total()).bytes == final, "seek forward again matches")

-- canvas resize mid-recording
spr = s2
rec = rec2
spr.events:on("change", function(ev) rec:onChange(ev) end)
rec:start()
app.command.CanvasSize{ ui = false, right = 16, bottom = 8 }
app.useTool{ tool = "pencil", color = red, points = { Point(60, 36), Point(62, 38) } }
local final2 = recorder.composite(spr, 1)
local e2 = player.parse(rec.lines)
player.hideUndone(e2)
local p2 = player.new(e2, spr.width, spr.height)
check(p2.width == 64 and p2.height == 40, "player grows to resized canvas")
check(p2:seek(p2:total()).bytes == final2, "replay after canvas resize matches")

-- exports
for _, fmt in ipairs{ "gif", "webp", "png", "mp4" } do
  local path = app.fs.joinPath(out, "tl." .. fmt)
  local ok, msg = export.run(p2, { path = path, format = fmt, seconds = 2, fps = 10,
                                   hold = 1, scale = 4, bg = fmt ~= "gif" and Color{ r = 255, g = 255, b = 255 } or nil })
  local exists = app.fs.isFile(fmt == "png" and app.fs.joinPath(out, "tl_00001.png") or path)
  check(ok and exists, "export " .. fmt .. ": " .. tostring(msg))
end

-- recordings saved under the 0.1.0 property name still load, then move over
local legacy = Sprite(8, 8)
legacy.properties("s.playa").chunks = { "e,0,1,0,0,0,0,1,\ne,0,1,0,0,0,0,2," }
legacy.properties("s.playa").on = true
local lrec = recorder.load(legacy)
check(#lrec.lines == 2 and lrec.on == true, "legacy recording loads")
lrec:save()
check(legacy.properties("s.playa").chunks == nil, "legacy properties cleared after save")
check(#recorder.load(legacy).lines == 2, "recording readable under new name")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
