-- s.playa player: rebuilds the canvas from recorded lines, step by step.

local codec = dofile(app.fs.joinPath(SPLAYA_PATH, "codec.lua"))

local M = {}

function M.parse(lines)
  local entries = {}
  for i, line in ipairs(lines) do
    local kind, full, frame, x, y, w, h, t, data =
      line:match("^(%a),(%d),(%d+),(%-?%d+),(%-?%d+),(%d+),(%d+),(%d+),(.*)$")
    if kind then
      entries[#entries + 1] = {
        kind = kind, full = full == "1", frame = tonumber(frame),
        x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h),
        t = tonumber(t), data = data,
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

local Player = {}
Player.__index = Player

-- `steps` are indices of entries that change pixels and are not hidden.
function M.new(entries, width, height)
  local p = setmetatable({ entries = entries, width = width, height = height }, Player)
  p:refresh()
  return p
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
  self:reset()
end

function Player:reset()
  self.canvases = {}
  self.pos = 0       -- number of steps applied
  self.applied = 0   -- entries walked so far
  self.frame = 1
end

local function patchImage(e)
  if not e.img then
    local img = Image(ImageSpec{ width = e.w, height = e.h, colorMode = ColorMode.RGB })
    img.bytes = codec.decode(e.data)
    e.img = img
  end
  return e.img
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
  return self:canvas(self.frame)
end

function Player:total() return #self.steps end

return M
