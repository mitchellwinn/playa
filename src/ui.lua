-- s.playa dialogs: timelapse preview and export settings.

local player = dofile(app.fs.joinPath(SPLAYA_PATH, "player.lua"))
local export = dofile(app.fs.joinPath(SPLAYA_PATH, "export.lua"))

local M = {}

local VIEW = 320  -- preview box size in UI pixels
local FORMATS = { "GIF", "WebP", "MP4", "PNG frames" }
local EXT = { GIF = "gif", WebP = "webp", MP4 = "mp4", ["PNG frames"] = "png" }

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

  if d.hide then player.hideUndone(p.entries) else player.showAll(p.entries) end
  p:refresh()

  local ok, msg = export.run(p, {
    path = d.path, format = EXT[d.format],
    seconds = math.max(0.1, d.seconds), fps = math.max(1, math.min(60, d.fps)),
    hold = math.max(0, d.hold), scale = math.max(1, d.scale),
    bg = (not d.transparent) and d.bg or nil,
  })
  app.alert{ title = "s.playa", text = ok and msg or ("Export failed: " .. tostring(msg)) }
end

-- Preview --------------------------------------------------------------------

function M.play(rec, prefs)
  local spr = rec.sprite
  local entries = player.parse(rec.lines)
  local hide = true
  player.hideUndone(entries)
  local p = player.new(entries, spr.width, spr.height)
  local total = p:total()
  if total == 0 then
    app.alert{ title = "s.playa", text = rec.on and
      "Nothing recorded yet. Draw something, then play it back here."
      or "This sprite has no recording. Turn on File > s.playa > Record This Sprite." }
    return
  end

  local zoom = math.min(VIEW / p.width, VIEW / p.height)
  if zoom >= 1 then zoom = math.floor(zoom) end
  local vw, vh = math.max(1, math.floor(p.width * zoom)), math.max(1, math.floor(p.height * zoom))
  local pos = total
  p:seek(pos)

  local timer, dlg
  -- Aim for about ten seconds of playback at 30 ticks per second.
  local perTick = math.max(1, math.ceil(total / 300))

  local function stats()
    return string.format("%d strokes  ·  %s drawing", total, duration(player.drawingTime(entries)))
  end

  local function setPos(n)
    pos = math.max(0, math.min(total, n))
    p:seek(pos)
    dlg:modify{ id = "pos", value = pos }
    dlg:repaint()
  end

  local function stop()
    if timer and timer.isRunning then timer:stop() end
    dlg:modify{ id = "play", text = "Play" }
  end

  timer = Timer{ interval = 1 / 30, ontick = function()
    if pos >= total then stop() return end
    setPos(pos + perTick)
  end }

  dlg = Dialog{ title = "s.playa Timelapse", onclose = function() timer:stop() end }
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
  dlg:slider{ id = "pos", min = 0, max = total, value = pos,
    onchange = function() stop() setPos(dlg.data.pos) end }
  dlg:combobox{ id = "speed", label = "Speed",
    option = "Normal", options = { "Slow", "Normal", "Fast", "Fastest" },
    onchange = function()
      local mul = ({ Slow = 0.25, Normal = 1, Fast = 3, Fastest = 10 })[dlg.data.speed]
      perTick = math.max(1, math.ceil(total / 300 * mul))
    end }
  dlg:check{ id = "hide", label = "Undone strokes", text = "Leave out", selected = hide,
    onclick = function()
      stop()
      if dlg.data.hide then player.hideUndone(entries) else player.showAll(entries) end
      p:refresh()
      total = p:total()
      pcall(function() dlg:modify{ id = "pos", max = total } end)
      dlg:modify{ id = "stats", text = stats() }
      setPos(total)
    end }
  dlg:button{ id = "play", text = "Play", onclick = function()
    if timer.isRunning then stop() return end
    if pos >= total then setPos(0) end
    dlg:modify{ id = "play", text = "Pause" }
    timer:start()
  end }
  dlg:button{ text = "Export...", onclick = function()
    stop()
    M.export(rec, p, prefs)
    -- export rewinds the player; put the preview back where it was
    if dlg.data.hide then player.hideUndone(entries) else player.showAll(entries) end
    p:refresh()
    total = p:total()
    setPos(total)
  end }
  dlg:button{ text = "Close", onclick = function() timer:stop() dlg:close() end }
  dlg:show{ wait = false }
end

return M
