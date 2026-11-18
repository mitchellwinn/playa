-- Playa export: renders a timelapse to GIF, WebP, PNG frames or MP4.

local M = {}

local function pad(n) return string.format("%05d", n) end

local function quote(s)
  if app.os.windows then return '"' .. s .. '"' end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

function M.findFfmpeg()
  local candidates = {
    "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg",
    "C:\\ffmpeg\\bin\\ffmpeg.exe", "C:\\Program Files\\ffmpeg\\bin\\ffmpeg.exe",
  }
  for _, p in ipairs(candidates) do
    if app.fs.isFile(p) then return p end
  end
  return "ffmpeg"  -- hope it is on PATH
end

-- Where on the player's timeline each output frame sits. Whole strokes only
-- in Strokes mode; other modes can land partway through a stroke.
function M.plan(totalUnits, seconds, fps, whole)
  -- Short recordings repeat pictures so the timelapse still lasts `seconds`.
  local count = math.max(1, math.floor(seconds * fps + 0.5))
  local positions = {}
  for i = 1, count do
    local u = i * totalUnits / count
    if whole then u = math.max(1, math.min(totalUnits, math.ceil(u))) end
    positions[i] = u
  end
  return positions
end

function M.autoScale(w, h)
  return math.max(1, math.floor(512 / math.max(w, h)))
end

-- Draws one output frame: background, the canvas, then nearest-neighbour scale.
local function render(canvas, w, h, scale, bg)
  local img = Image(ImageSpec{ width = w, height = h, colorMode = ColorMode.RGB })
  if bg then img:clear(bg) end
  img:drawImage(canvas, Point(0, 0), 255, BlendMode.NORMAL)
  if scale > 1 then img:resize{ width = w * scale, height = h * scale, method = "nearest" } end
  return img
end

-- opts: path, format (gif|webp|png|mp4), seconds, fps, scale, hold, bg (Color|nil)
-- Returns true, message or false, error.
function M.run(player, opts)
  local total = player:total()
  if total == 0 then return false, "Nothing recorded yet." end

  local w, h = player.width, player.height
  local scale = math.max(1, math.floor(opts.scale or 1))
  local positions = M.plan(player:totalUnits(), opts.seconds, opts.fps, player.mode == "strokes")
  local holdFrames = math.floor((opts.hold or 0) * opts.fps + 0.5)
  local format = opts.format

  if format == "mp4" and not opts.bg then
    opts.bg = Color{ r = 255, g = 255, b = 255 }  -- video has no transparency
  end

  PLAYA_BUSY = true
  local ok, result = pcall(function()
    player:reset()

    if format == "gif" or format == "webp" then
      local spr = Sprite(w * scale, h * scale, ColorMode.RGB)
      local layer = spr.layers[1]
      local frames, lastBytes = 0, nil
      for _, pos in ipairs(positions) do
        local img = render(player:at(pos), w, h, scale, opts.bg)
        local bytes = img.bytes
        if bytes == lastBytes then
          -- Same picture again: lengthen the previous frame instead.
          spr.frames[frames].duration = spr.frames[frames].duration + 1 / opts.fps
        else
          frames = frames + 1
          if frames > 1 then spr:newEmptyFrame(frames) end
          spr:newCel(layer, frames, img, Point(0, 0))
          spr.frames[frames].duration = 1 / opts.fps
          lastBytes = bytes
        end
      end
      spr.frames[frames].duration = spr.frames[frames].duration + (opts.hold or 0)
      spr:saveCopyAs(opts.path)
      spr:close()
      return string.format("Saved %d frames to %s", frames, app.fs.fileName(opts.path))
    end

    -- PNG sequence (also the input for MP4).
    local dir, base
    if format == "png" then
      dir = app.fs.filePath(opts.path)
      base = app.fs.fileTitle(opts.path) .. "_"
    else
      dir = app.fs.joinPath(app.fs.tempPath, "playa-" .. os.time())
      app.fs.makeAllDirectories(dir)
      base = "f_"
    end

    local written = {}
    local n = 0
    local last
    for _, pos in ipairs(positions) do
      last = render(player:at(pos), w, h, scale, opts.bg)
      n = n + 1
      local file = app.fs.joinPath(dir, base .. pad(n) .. ".png")
      last:saveAs(file)
      written[#written + 1] = file
    end
    for _ = 1, holdFrames do
      n = n + 1
      local file = app.fs.joinPath(dir, base .. pad(n) .. ".png")
      last:saveAs(file)
      written[#written + 1] = file
    end

    if format == "png" then
      return string.format("Saved %d PNG frames to %s", n, dir)
    end

    local cmd = string.format(
      '%s -y -loglevel error -framerate %d -i %s -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" '
      .. '-c:v libx264 -pix_fmt yuv420p -crf 18 %s',
      quote(opts.ffmpeg or M.findFfmpeg()), opts.fps,
      quote(app.fs.joinPath(dir, "f_%05d.png")), quote(opts.path))
    local okRun = os.execute(cmd)
    for _, f in ipairs(written) do os.remove(f) end
    os.remove(dir)
    if not okRun or not app.fs.isFile(opts.path) then
      error("ffmpeg failed. Install ffmpeg (ffmpeg.org) or export as GIF instead.")
    end
    return string.format("Saved %s (%d frames)", app.fs.fileName(opts.path), n)
  end)
  PLAYA_BUSY = false
  return ok, result
end

return M
