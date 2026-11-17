-- Playa recorder: watches a sprite and logs every visible change as a patch.
--
-- A recording is a list of text lines, one per change event:
--
--   kind,full,frame,x,y,w,h,t,data
--
--   kind  e = edit, u = undo, r = redo, h = undo-history jump (direction
--         unknown), x = sync (the canvas changed outside a change event,
--         or the first snapshot of a frame)
--   full  1 = keyframe: data is the whole canvas, (w,h) is its size
--   frame frame number the change was seen on
--   x,y,w,h  changed rectangle (w = 0 means no visible change)
--   t     unix time in seconds
--   data  RGBA pixels of the rectangle after the change, RLE + base64
--
-- Every change event writes exactly one e/u/r/h line, even an invisible one,
-- so undo lines can be matched to the edits they revert.
--
-- Lines are stored in the sprite's "playa" extension properties, chunked
-- because a single .aseprite string property holds at most 64 KB.

local codec = dofile(app.fs.joinPath(PLAYA_PATH, "codec.lua"))

local M = {}

local PROP = "playa"
local LEGACY_PROP = "s.playa"  -- name used by 0.1.0 builds
local CHUNK = 60000
local FORMAT = 1

local ssub = string.sub

-- Composite of what the artist sees on one frame, as RGBA bytes.
local function composite(spr, frameNumber)
  local img = Image(ImageSpec{ width = spr.width, height = spr.height,
                               colorMode = ColorMode.RGB })
  img:drawSprite(spr, frameNumber)
  return img.bytes
end

-- Bounding box of the pixels that differ between two same-size images.
local function diffRect(a, b, w, h)
  local stride = w * 4
  local top, bottom
  for y = 0, h - 1 do
    local o = y * stride + 1
    if ssub(a, o, o + stride - 1) ~= ssub(b, o, o + stride - 1) then
      top = top or y
      bottom = y
    end
  end
  if not top then return nil end

  local left, right = w, -1
  for y = top, bottom do
    local o = y * stride + 1
    if ssub(a, o, o + stride - 1) ~= ssub(b, o, o + stride - 1) then
      for x = 0, left - 1 do
        local p = o + x * 4
        if ssub(a, p, p + 3) ~= ssub(b, p, p + 3) then left = x break end
      end
      for x = w - 1, right + 1, -1 do
        local p = o + x * 4
        if ssub(a, p, p + 3) ~= ssub(b, p, p + 3) then right = x break end
      end
    end
  end
  return left, top, right - left + 1, bottom - top + 1
end

local function crop(bytes, w, x, y, cw, ch)
  local stride = w * 4
  local rows = {}
  for r = 0, ch - 1 do
    local o = (y + r) * stride + x * 4 + 1
    rows[#rows + 1] = ssub(bytes, o, o + cw * 4 - 1)
  end
  return table.concat(rows)
end

-- Recording object ---------------------------------------------------------

local Rec = {}
Rec.__index = Rec

function M.load(spr)
  local props = spr.properties(PROP)
  local migrated = false
  if props.chunks == nil then
    local old = spr.properties(LEGACY_PROP)
    if old.chunks ~= nil or old.on ~= nil then
      props = old
      migrated = true
    end
  end
  local rec = setmetatable({
    sprite = spr,
    lines = {},
    cache = {},      -- frame -> { w, h, bytes, logged }
    pending = nil,   -- kind set by the command hook before a change event
    on = props.on,   -- nil: never decided for this sprite (auto-record pref applies)
    dirty = migrated,   -- moved to the current property name on next save
    migrated = migrated,
  }, Rec)
  local chunks = props.chunks
  if type(chunks) == "table" and #chunks > 0 then
    local text = table.concat(chunks)
    for line in text:gmatch("[^\n]+") do rec.lines[#rec.lines + 1] = line end
  end
  return rec
end

function Rec:save()
  local props = self.sprite.properties(PROP)
  local text = table.concat(self.lines, "\n")
  local chunks = {}
  for i = 1, #text, CHUNK do chunks[#chunks + 1] = ssub(text, i, i + CHUNK - 1) end
  props.format = FORMAT
  props.on = self.on
  props.chunks = chunks
  if self.migrated then
    self.sprite.properties(LEGACY_PROP, {})
    self.migrated = false
  end
  self.dirty = false
end

function Rec:clear()
  self.lines = {}
  self.cache = {}
  self.dirty = true
  self:save()
end

function Rec:count() return #self.lines end

function Rec:currentFrame()
  if app.sprite == self.sprite and app.frame then return app.frame.frameNumber end
  return 1
end

function Rec:push(kind, full, frame, x, y, w, h, data)
  self.lines[#self.lines + 1] = string.format("%s,%d,%d,%d,%d,%d,%d,%d,%s",
    kind, full and 1 or 0, frame, x, y, w, h, os.time(), data or "")
  self.dirty = true
end

function Rec:keyframe(kind, frame, c)
  self:push(kind, true, frame, 0, 0, c.w, c.h, codec.encode(c.bytes))
  c.logged = true
end

-- Take a fresh look at a frame. Logs a sync line when the canvas changed
-- since we last saw it (edits that touched a frame other than the active one).
function Rec:look(frame)
  local spr = self.sprite
  if frame > #spr.frames then return end
  local w, h = spr.width, spr.height
  local bytes = composite(spr, frame)
  local c = self.cache[frame]
  if c and c.logged then
    if c.w ~= w or c.h ~= h then
      self.cache[frame] = { w = w, h = h, bytes = bytes }
      self:keyframe("x", frame, self.cache[frame])
      return
    end
    local x, y, dw, dh = diffRect(c.bytes, bytes, w, h)
    if x then self:push("x", false, frame, x, y, dw, dh, codec.encode(crop(bytes, w, x, y, dw, dh))) end
  end
  self.cache[frame] = { w = w, h = h, bytes = bytes, logged = c and c.logged }
end

function Rec:onChange(ev)
  local kind = ev.fromUndo and (self.pending or "h") or "e"
  if not self.on then return end

  local spr = self.sprite
  local frame = self:currentFrame()
  local w, h = spr.width, spr.height
  local bytes = composite(spr, frame)
  local c = self.cache[frame]

  -- First time this frame is touched: log what it looked like before.
  if c and not c.logged and c.w == w and c.h == h then
    self:keyframe("x", frame, c)
  end

  if not c or c.w ~= w or c.h ~= h then
    local nc = { w = w, h = h, bytes = bytes }
    self.cache[frame] = nc
    self:keyframe(kind, frame, nc)
    return
  end

  local x, y, dw, dh = diffRect(c.bytes, bytes, w, h)
  if x then
    self:push(kind, false, frame, x, y, dw, dh, codec.encode(crop(bytes, w, x, y, dw, dh)))
  else
    self:push(kind, false, frame, 0, 0, 0, 0, nil)
  end
  c.bytes = bytes
end

function Rec:start()
  self.on = true
  self.cache = {}
  self:look(self:currentFrame())
  self.dirty = true
end

function Rec:stop()
  self.on = false
  self.dirty = true
end

M.composite = composite
M.diffRect = diffRect
return M
