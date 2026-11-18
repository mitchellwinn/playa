-- Playa dialogs: timelapse preview and export settings.

local player = dofile(app.fs.joinPath(PLAYA_PATH, "player.lua"))
local export = dofile(app.fs.joinPath(PLAYA_PATH, "export.lua"))

local M = {}

local VIEW = 320  -- preview box size in UI pixels
local FORMATS = { "GIF", "WebP", "MP4", "PNG frames" }
local EXT = { GIF = "gif", WebP = "webp", MP4 = "mp4", ["PNG frames"] = "png" }
local DETAILS = { "Strokes", "Pixels", "Real time" }
local MODE = { Strokes = "strokes", Pixels = "pixels", ["Real time"] = "realtime" }
local DETAIL_HELP = {
  Strokes = "Each stroke appears at once.",
  Pixels = "Strokes draw in pixel by pixel, in drawing order.",
  ["Real time"] = "Strokes draw at your speed; long pauses are shortened.",
}

local function detailOf(prefs) return MODE[prefs.detail or "Pixels"] and (prefs.detail or "Pixels") or "Pixels" end

local function duration(seconds)
  local h, m = seconds // 3600, (seconds % 3600) // 60
  if h > 0 then return string.format("%dh %02dm", h, m) end
  if m > 0 then return string.format("%dm %02ds", m, seconds % 60) end
  return string.format("%ds", seconds)
end

local function defaultPath(spr, ext)
  local name = spr.filename
  local dir = app.fs.filePath(name)
  local title = app.fs.fileTitle(name)
  if dir == "" then dir = app.fs.userDocsPath end
  if title == "" then title = "sprite" end
  return app.fs.joinPath(dir, title .. "-timelapse." .. ext)
end

-- Export ---------------------------------------------------------------------

function M.export(rec, p, prefs)
  local spr = rec.sprite
  local ex = prefs.export or {}
  local format = ex.format or "GIF"
  local dlg
  dlg = Dialog{ title = "Export Timelapse" }
  dlg:combobox{ id = "format", label = "Format", option = format, options = FORMATS,
    onchange = function()
      local ext = EXT[dlg.data.format]
      dlg:modify{ id = "path", filename = app.fs.filePathAndTitle(dlg.data.path) .. "." .. ext }
      dlg:modify{ id = "fps", text = tostring(ext == "mp4" and 30 or 25) }
    end }
  dlg:file{ id = "path", label = "Save to", save = true,
    filename = defaultPath(spr, EXT[format]), filetypes = { "gif", "webp", "mp4", "png" } }
  dlg:separator{ text = "Timing" }
  dlg:combobox{ id = "detail", label = "Detail", option = detailOf(prefs), options = DETAILS }
  dlg:number{ id = "seconds", label = "Length (sec)", text = tostring(ex.seconds or 15), decimals = 1 }
  dlg:number{ id = "fps", label = "Frames/sec", text = tostring(ex.fps or 25), decimals = 0 }
  dlg:number{ id = "hold", label = "Hold end (sec)", text = tostring(ex.hold or 2), decimals = 1 }
  dlg:separator{ text = "Look" }
  dlg:number{ id = "scale", label = "Scale", text = tostring(export.autoScale(p.width, p.height)), decimals = 0 }
  dlg:check{ id = "transparent", label = "Background", text = "Transparent",
    selected = ex.transparent == true,
    onclick = function() dlg:modify{ id = "bg", visible = not dlg.data.transparent } end }
  dlg:color{ id = "bg", color = Color{ r = 255, g = 255, b = 255 }, visible = ex.transparent ~= true }
  dlg:check{ id = "hide", label = "Undone strokes", text = "Leave out",
    selected = ex.hide ~= false }
  dlg:separator()
  dlg:button{ id = "ok", text = "Export", focus = true }
  dlg:button{ id = "cancel", text = "Cancel" }
  dlg:show()

  local d = dlg.data
  if not d.ok then return end
  prefs.export = { format = d.format, seconds = d.seconds, fps = d.fps, hold = d.hold,
                   transparent = d.transparent, hide = d.hide }
  prefs.detail = d.detail

  if d.hide then player.hideUndone(p.entries) else player.showAll(p.entries) end
  p.mode = MODE[d.detail]
  p:refresh()

  local ok, msg = export.run(p, {
    path = d.path, format = EXT[d.format],
    seconds = math.max(0.1, d.seconds), fps = math.max(1, math.min(60, d.fps)),
    hold = math.max(0, d.hold), scale = math.max(1, d.scale),
    bg = (not d.transparent) and d.bg or nil,
  })
  app.alert{ title = "Playa", text = ok and msg or ("Export failed: " .. tostring(msg)) }
end

-- Preview --------------------------------------------------------------------

function M.play(rec, prefs)
  local spr = rec.sprite
  local entries = player.parse(rec.lines)
  player.hideUndone(entries)
  local detail = detailOf(prefs)
  local p = player.new(entries, spr.width, spr.height, MODE[detail])
  if p:total() == 0 then
    app.alert{ title = "Playa", text = rec.on and
      "Nothing recorded yet. Draw something, then play it back here."
      or "This sprite has no recording. Turn on File > Playa > Record This Sprite." }
    return
  end

  local zoom = math.min(VIEW / p.width, VIEW / p.height)
  if zoom >= 1 then zoom = math.floor(zoom) end
  local vw, vh = math.max(1, math.floor(p.width * zoom)), math.max(1, math.floor(p.height * zoom))

  -- Positions are timeline units; the slider works in whole units.
  local total = p:totalUnits()
  local pos = total
  local speed = 1
  p:at(pos)

  local timer, dlg

  local function perTick()
    -- about ten seconds of playback at 30 ticks per second, times the speed
    return total / 300 * speed
  end

  local function stats()
    return string.format("%d strokes  ·  %s drawing", p:total(), duration(player.drawingTime(entries)))
  end

  local function setPos(u, fromSlider)
    pos = math.max(0, math.min(total, u))
    p:at(pos)
    if not fromSlider then dlg:modify{ id = "pos", value = math.floor(pos + 0.5) } end
    dlg:repaint()
  end

  local function stop()
    if timer and timer.isRunning then timer:stop() end
    dlg:modify{ id = "play", text = "Play" }
  end

  local function rebuild()
    stop()
    if dlg.data.hide then player.hideUndone(entries) else player.showAll(entries) end
    p.mode = MODE[dlg.data.detail]
    p:refresh()
    total = p:totalUnits()
    pcall(function() dlg:modify{ id = "pos", max = math.max(1, math.ceil(total)) } end)
    dlg:modify{ id = "stats", text = stats() }
    setPos(total)
  end

  timer = Timer{ interval = 1 / 30, ontick = function()
    if pos >= total then stop() return end
    setPos(pos + perTick())
  end }

  dlg = Dialog{ title = "Playa", onclose = function() timer:stop() end }
  dlg:label{ id = "stats", text = stats() }
  dlg:canvas{ id = "view", width = VIEW, height = VIEW,
    onpaint = function(ev)
      local gc = ev.context
      local ox, oy = (gc.width - vw) // 2, (gc.height - vh) // 2
      -- checkerboard behind transparent pixels
      local cell = 8
      for y = oy, oy + vh - 1, cell do
        for x = ox, ox + vw - 1, cell do
          local dark = ((x - ox) // cell + (y - oy) // cell) % 2 == 0
          gc.color = dark and Color{ gray = 180 } or Color{ gray = 220 }
          gc:fillRect(Rectangle(x, y, math.min(cell, ox + vw - x), math.min(cell, oy + vh - y)))
        end
      end
      local img = p:current()
      gc:drawImage(img, img.bounds, Rectangle(ox, oy, vw, vh))
    end }
  dlg:slider{ id = "pos", min = 0, max = math.max(1, math.ceil(total)), value = math.ceil(total),
    onchange = function() stop() setPos(dlg.data.pos, true) end }
  dlg:combobox{ id = "detail", label = "Detail", option = detail, options = DETAILS,
    onchange = function()
      prefs.detail = dlg.data.detail
      dlg:modify{ id = "help", text = DETAIL_HELP[dlg.data.detail] }
      rebuild()
    end }
  dlg:label{ id = "help", text = DETAIL_HELP[detail] }
  dlg:combobox{ id = "speed", label = "Speed",
    option = "Normal", options = { "Slow", "Normal", "Fast", "Fastest" },
    onchange = function()
      speed = ({ Slow = 0.25, Normal = 1, Fast = 3, Fastest = 10 })[dlg.data.speed]
    end }
  dlg:check{ id = "hide", label = "Undone strokes", text = "Leave out", selected = true,
    onclick = rebuild }
  dlg:button{ id = "play", text = "Play", onclick = function()
    if timer.isRunning then stop() return end
    if pos >= total then setPos(0) end
    dlg:modify{ id = "play", text = "Pause" }
    timer:start()
  end }
  dlg:button{ text = "Export...", onclick = function()
    stop()
    M.export(rec, p, prefs)
    -- export may change the detail and rewinds the player; sync back up
    dlg:modify{ id = "detail", option = detailOf(prefs) }
    dlg:modify{ id = "help", text = DETAIL_HELP[detailOf(prefs)] }
    rebuild()
  end }
  dlg:button{ text = "Close", onclick = function() timer:stop() dlg:close() end }
  dlg:show{ wait = false }
end

return M
