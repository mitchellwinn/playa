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

-- deferred mode: changes queue up and are compared later, several at once
PLAYA_DEFER = true
local ds = Sprite(24, 24)
local drec = recorder.load(ds)
ds.events:on("change", function(ev) drec:onChange(ev) end)
app.events:on("beforecommand", function(ev)
  if ev.name == "Undo" then drec.pending = "u" elseif ev.name == "Redo" then drec.pending = "r" end
end)
app.events:on("aftercommand", function() drec.pending = nil end)
drec:start()
app.useTool{ tool = "pencil", color = red, points = { Point(1, 1), Point(10, 1) } }
drec:flush()
app.useTool{ tool = "pencil", color = green, points = { Point(1, 5), Point(10, 5) } }
app.useTool{ tool = "pencil", color = blue, points = { Point(1, 9), Point(10, 9) } }
app.command.Undo()
app.command.Undo()                       -- four changes queued, one flush
check(#drec.queue == 4, "changes queue until flush")
drec:flush()
app.useTool{ tool = "pencil", color = blue, points = { Point(5, 0), Point(5, 20) } }
drec:flush()
local dfinal = recorder.composite(ds, 1)
local de = player.parse(drec.lines)
player.hideUndone(de)
local dp = player.new(de, ds.width, ds.height)
check(dp:seek(dp:total()).bytes == dfinal, "deferred replay matches final canvas")
local dhidden = 0
for _, e in ipairs(de) do if e.hidden then dhidden = dhidden + 1 end end
check(dhidden == 4, "queued undos still pair with their edits (got " .. dhidden .. ")")
PLAYA_DEFER = nil

-- stroke order from the cursor path --------------------------------------
local order = dofile(app.fs.joinPath(PLAYA_PATH, "order.lua"))
local ps = Sprite(32, 32)
local prec = recorder.load(ps)
ps.events:on("change", function(ev) prec:onChange(ev) end)
prec:start()
local cursor, tick = nil, 0
PLAYA_POINTER = function()
  if not cursor then return nil end
  tick = tick + 1
  return cursor.x, cursor.y, tick
end
local function stroke(from, to, withPath)
  cursor = nil
  if withPath then
    local steps = 10
    for k = 0, steps do
      tick = tick + 3
      prec:pointer(math.floor(from.x + (to.x - from.x) * k / steps + 0.5),
                   math.floor(from.y + (to.y - from.y) * k / steps + 0.5), tick)
    end
  end
  cursor = to
  app.useTool{ tool = "pencil", color = red, points = { from, to } }
  cursor = nil
end
stroke(Point(2, 2), Point(20, 2), true)     -- left to right, with path
stroke(Point(20, 6), Point(2, 6), true)     -- right to left, with path
stroke(Point(2, 10), Point(20, 10), false)  -- no path, cursor ends at the right
stroke(Point(25, 2), Point(25, 25), false)  -- no path, vertical, ends at bottom
local ordered = player.parse(prec.lines)
player.hideUndone(ordered)
local op = player.new(ordered, ps.width, ps.height, "pixels")
local strokesSeen = {}
for _, idx in ipairs(op.steps) do
  local e = ordered[idx]
  if e.order then strokesSeen[#strokesSeen + 1] = e end
end
check(#strokesSeen == 4, "four strokes ordered (got " .. #strokesSeen .. ")")
local function ends(e) local px = e.order.pixels return px[1], px[#px] end
local a1, z1 = ends(strokesSeen[1])
check(a1.x == 2 and z1.x == 20, "path: left-to-right stroke draws from the left")
local a2, z2 = ends(strokesSeen[2])
check(a2.x == 20 and z2.x == 2, "path: right-to-left stroke draws from the right")
local a3, z3 = ends(strokesSeen[3])
check(a3.x == 2 and z3.x == 20, "cursor only: line finishes where the cursor stopped")
local a4, z4 = ends(strokesSeen[4])
check(a4.y == 2 and z4.y == 25, "cursor only: vertical line runs toward the cursor")
check(strokesSeen[1].order.ticks > 0, "path strokes carry their duration")

-- a fill floods out from where the cursor clicked
app.useTool{ tool = "rectangle", color = blue, points = { Point(4, 14), Point(16, 26) } }
cursor = Point(10, 20)
app.useTool{ tool = "paint_bucket", color = green, points = { Point(10, 20) } }
cursor = nil
local fe = player.parse(prec.lines)
player.hideUndone(fe)
local fp = player.new(fe, ps.width, ps.height, "pixels")
local fill = fe[fp.steps[#fp.steps]]
local first = fill.order.pixels[1]
check(#fill.order.pixels > 50 and math.abs(first.x - 10) <= 1 and math.abs(first.y - 20) <= 1,
      "bucket fill starts at the click (" .. first.x .. "," .. first.y .. ")")

-- every mode ends on the real canvas; partway through a stroke is partial
local pfinal = recorder.composite(ps, 1)
for _, mode in ipairs{ "strokes", "pixels", "realtime" } do
  local mp = player.new(player.parse(prec.lines), ps.width, ps.height, mode)
  local total = mp:totalUnits()
  check(mp:at(total).bytes == pfinal, mode .. ": timeline ends on the final canvas")
  check(mp:at(0).bytes ~= pfinal, mode .. ": timeline starts before the drawing")
end
local pp = player.new(player.parse(prec.lines), ps.width, ps.height, "pixels")
local s1 = 1
while pp.entries[pp.steps[s1]].full do s1 = s1 + 1 end
local base = s1 > 1 and pp.cum[s1 - 1] or 0
local before = pp:at(base).bytes
local mid = pp:at(base + (pp.cum[s1] - base) / 2).bytes
local after = pp:at(pp.cum[s1]).bytes
check(mid ~= before and mid ~= after, "pixels: halfway through the first stroke is partly drawn")
PLAYA_POINTER = nil

-- fills, moves and commands ------------------------------------------------
local ms = Sprite(40, 40)
local mrec = recorder.load(ms)
ms.events:on("change", function(ev) mrec:onChange(ev) end)
app.events:on("beforecommand", function(ev) if ev.name ~= "" then mrec.command = ev.name end end)
app.events:on("aftercommand", function() mrec.command = nil end)
mrec:start()
local mcursor, mtick = nil, 0
PLAYA_POINTER = function() if mcursor then mtick = mtick + 1 return mcursor.x, mcursor.y, mtick end end
local function lastOrdered(mode)
  local es = player.parse(mrec.lines)
  player.hideUndone(es)
  local pl = player.new(es, ms.width, ms.height, mode or "pixels")
  return es[pl.steps[#pl.steps]], pl
end

-- bucket fill after hovering across the region: floods from the click
app.tool = "rectangle"
app.useTool{ tool = "rectangle", color = blue, points = { Point(2, 2), Point(30, 30) } }
app.tool = "paint_bucket"
for k = 0, 10 do mtick = mtick + 2 mrec:pointer(4 + k * 2, 4 + k, mtick) end   -- hover in
mcursor = Point(24, 14)
app.useTool{ tool = "paint_bucket", color = green, points = { Point(24, 14) } }
mcursor = nil
local fillE = lastOrdered()
local f1 = fillE.order.pixels[1]
check(not fillE.order.move and math.abs(f1.x - 24) <= 1 and math.abs(f1.y - 14) <= 1,
      "bucket after hovering still floods from the click (" .. f1.x .. "," .. f1.y .. ")")

-- a two-color chunk on its own layer, moved by (12, 6)
local chunkLayer = ms:newLayer()
app.tool = "pencil"
app.useTool{ tool = "filled_rectangle", color = red, layer = chunkLayer, points = { Point(4, 4), Point(9, 9) } }
app.useTool{ tool = "pencil", color = blue, layer = chunkLayer, points = { Point(5, 5), Point(8, 5) } }
app.tool = "move"
app.transaction("move", function()
  local cel = chunkLayer:cel(1)
  cel.position = Point(cel.position.x + 12, cel.position.y + 6)
end)
local moveE, mp = lastOrdered()
check(moveE.order and moveE.order.move and moveE.order.dx == 12 and moveE.order.dy == 6,
      "moved chunk detected with its offset")
local base = mp.steps[#mp.steps - 1] and mp.cum[#mp.steps - 1] or 0
local half = mp:at(base + (mp.cum[#mp.steps] - base) / 2)
check(half:getPixel(4 + 6, 4 + 3) == app.pixelColor.rgba(255, 0, 0, 255),
      "halfway through the slide the chunk is halfway there")
check(mp:at(mp:totalUnits()).bytes == recorder.composite(ms, 1), "slide ends on the final canvas")

-- Edit > Fill spreads from the middle of the selection
app.tool = "rectangular_marquee"
ms.selection = Selection(Rectangle(30, 30, 8, 8))
app.fgColor = Color{ r = 250, g = 200, b = 0, a = 255 }
app.command.Fill()
ms.selection = Selection()
local cmdE = lastOrdered()
local c1 = cmdE.order.pixels and cmdE.order.pixels[1]
check(cmdE.cmd == "Fill" and not cmdE.order.move and c1 and c1.x >= 32 and c1.x <= 35 and c1.y >= 32 and c1.y <= 35,
      "Fill command recorded and spreads from the middle")
for _, mode in ipairs{ "strokes", "pixels", "realtime" } do
  local _, pl = lastOrdered(mode)
  check(pl:at(pl:totalUnits()).bytes == recorder.composite(ms, 1), mode .. ": ends on the final canvas")
end
app.tool = "pencil"
PLAYA_POINTER = nil

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
