-- Playa player: rebuilds the canvas from recorded lines, step by step.

local codec = dofile(app.fs.joinPath(PLAYA_PATH, "codec.lua"))
local order = dofile(app.fs.joinPath(PLAYA_PATH, "order.lua"))

local PIXEL_CAP = 40   -- most animation units one stroke gets in Pixels mode
local IDLE_MAX = 90    -- longest pause kept in Real time mode, in ticks (1/60 s)

local M = {}

function M.parse(lines)
  local entries = {}
  for i, line in ipairs(lines) do
    local kind, full, frame, x, y, w, h, t, data, path =
      line:match("^(%a),(%d),(%d+),(%-?%d+),(%-?%d+),(%d+),(%d+),(%d+),([^,]*),?(.*)$")
    if kind then
      entries[#entries + 1] = {
        kind = kind, full = full == "1", frame = tonumber(frame),
        x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h),
        t = tonumber(t), data = data, path = path ~= "" and path or nil,
      }
    end
  end
  return entries
end

-- Mark entries hidden when they were later undone (and the undo itself), so
-- the timelapse can show only the strokes that survived.
function M.hideUndone(entries)
  local stack = {}
  for _, e in ipairs(entries) do
    e.hidden = false
    if e.kind == "e" or e.kind == "r" then
      stack[#stack + 1] = e
    elseif e.kind == "u" then
      local top = table.remove(stack)
      if top then
        top.hidden = true
        e.hidden = true
      end
    elseif e.kind == "h" then
      stack = {}
    end
  end
end

function M.showAll(entries)
  for _, e in ipairs(entries) do e.hidden = false end
end

-- Active drawing time: gaps longer than `idle` seconds count as breaks.
function M.drawingTime(entries, idle)
  idle = idle or 120
  local total, last = 0, nil
  for _, e in ipairs(entries) do
    if last then
      local gap = e.t - last
      if gap > 0 then total = total + math.min(gap, idle) end
    end
    last = e.t
  end
  return total
end

-- Player -------------------------------------------------------------------

local function patchImage(e)
  if not e.img then
    local img = Image(ImageSpec{ width = e.w, height = e.h, colorMode = ColorMode.RGB })
    img.bytes = codec.decode(e.data)
    e.img = img
  end
  return e.img
end

local Player = {}
Player.__index = Player

-- `steps` are indices of entries that change pixels and are not hidden.
-- mode: "strokes" (one unit per edit), "pixels" (strokes draw in pixel by
-- pixel), "realtime" (strokes draw at recorded speed, pauses kept up to a cap)
function M.new(entries, width, height, mode)
  local p = setmetatable({ entries = entries, width = width, height = height,
                           mode = mode or "strokes" }, Player)
  p:refresh()
  return p
end

local function animated(e)
  return e.kind == "e" and not e.full and e.w > 0
end

function Player:refresh()
  self.steps = {}
  local maxW, maxH = 0, 0
  for i, e in ipairs(self.entries) do
    if not e.hidden and e.w > 0 then self.steps[#self.steps + 1] = i end
    if e.full then
      maxW = math.max(maxW, e.w)
      maxH = math.max(maxH, e.h)
    end
  end
  if maxW > 0 then self.width, self.height = maxW, maxH end
  -- which strokes are hidden changes what each stroke drew over
  for _, e in ipairs(self.entries) do e.order = nil end
  self:timeline()
end

function Player:setMode(mode)
  self.mode = mode
  self:timeline()
end

-- Units per step: cum[s] is where step s is fully drawn, gap[s] the pause
-- before it starts drawing.
function Player:timeline()
  self:reset()
  local mode = self.mode
  if mode ~= "strokes" then
    for s = 1, #self.steps do
      local e = self.entries[self.steps[s]]
      if animated(e) and not e.order then
        self:seek(s - 1)
        e.order = order.compute(self:canvas(e.frame), patchImage(e), e)
      end
    end
    self:reset()
  end

  self.cum, self.gap = {}, {}
  local total, prevEnd, prevT = 0, nil, nil
  for s, idx in ipairs(self.steps) do
    local e = self.entries[idx]
    local gap, cost = 0, 1
    if mode == "pixels" and animated(e) then
      cost = math.max(1, math.min(#e.order.pixels, PIXEL_CAP))
    elseif mode == "realtime" then
      local start = order.pathStart(e.path)
      if start and prevEnd and start >= prevEnd then
        gap = start - prevEnd
      elseif prevT then
        gap = (e.t - prevT) * 60
      end
      gap = math.max(0, math.min(gap, IDLE_MAX))
      if animated(e) then
        cost = e.order.ticks > 0 and e.order.ticks or math.min(#e.order.pixels, PIXEL_CAP) * 2
        cost = math.max(1, cost)
      end
      if start then prevEnd = start + (e.order and e.order.ticks or 0) end
      prevT = e.t
    end
    total = total + gap + cost
    self.gap[s] = gap
    self.cum[s] = total
  end
  self.units = total
end

function Player:totalUnits() return self.units or #self.steps end

-- The picture at a point on the timeline, drawing part of a stroke when the
-- point falls inside one.
function Player:at(u)
  local cum = self.cum
  local n = #self.steps
  if n == 0 or u <= 0 then return self:seek(0) end
  if u >= cum[n] then return self:seek(n) end
  local lo, hi = 1, n
  while lo < hi do
    local mid = (lo + hi) // 2
    if cum[mid] >= u then hi = mid else lo = mid + 1 end
  end
  local s = lo
  local startU = (s > 1 and cum[s - 1] or 0) + self.gap[s]
  local span = cum[s] - startU
  local f = span > 0 and (u - startU) / span or 1
  if f >= 1 then return self:seek(s) end
  local e = self.entries[self.steps[s]]
  if f <= 0 or self.mode == "strokes" or not e.order then return self:seek(s - 1) end

  self:seek(s - 1)
  local img = Image(self:canvas(e.frame))
  local marks = self.mode == "realtime" and e.order.time or e.order.rank
  for k, px in ipairs(e.order.pixels) do
    if marks[k] >= f then break end
    img:drawPixel(px.x, px.y, px.color)
  end
  self.partial = img
  self.frame = e.frame
  return img
end

function Player:reset()
  self.canvases = {}
  self.pos = 0       -- number of steps applied
  self.applied = 0   -- entries walked so far
  self.frame = 1
  self.partial = nil
end


function Player:canvas(frame)
  local c = self.canvases[frame]
  if not c then
    c = Image(ImageSpec{ width = self.width, height = self.height, colorMode = ColorMode.RGB })
    self.canvases[frame] = c
  end
  return c
end

function Player:apply(e)
  if e.hidden or e.w == 0 then return end
  local patch = patchImage(e)
  if e.full then
    local c = Image(ImageSpec{ width = self.width, height = self.height, colorMode = ColorMode.RGB })
    c:drawImage(patch, Point(0, 0), 255, BlendMode.SRC)
    self.canvases[e.frame] = c
  else
    self:canvas(e.frame):drawImage(patch, Point(e.x, e.y), 255, BlendMode.SRC)
  end
  self.frame = e.frame
end

-- Advance until `n` steps have been applied (rewinds when going backward).
function Player:seek(n)
  self.partial = nil
  n = math.max(0, math.min(n, #self.steps))
  if n < self.pos then self:reset() end
  while self.pos < n do
    self.pos = self.pos + 1
    local target = self.steps[self.pos]
    for i = self.applied + 1, target do self:apply(self.entries[i]) end
    self.applied = target
  end
  return self:current()
end

function Player:current()
  return self.partial or self:canvas(self.frame)
end

function Player:total() return #self.steps end

return M
