-- Playa stroke order: decides how an edit's pixels appear during playback.
--
-- A recorded edit stores the pixels that changed, not how they got there, so
-- the order is rebuilt from what else was recorded:
--
--   freehand tools  pixels follow the cursor path (last pass wins); pixels
--                   the cursor never crossed spread out from the ones it did
--   bucket          floods out from where the cursor clicked
--   shapes, lines   grow from where the drag started
--   gradient        sweeps along the drag direction
--   moved pixels    (move tool, dropped selections, commands) the chunk
--                   slides from where it was to where it landed
--
-- Edits without any of that (older recordings) are walked end to end.

local M = {}

local MAX_PATH_POINTS = 200

local FREEHAND = { pencil = true, eraser = true, spray = true, jumble = true,
                   blur = true, contour = true, polygon = true }
local SHAPES = { line = true, curve = true, rectangle = true, filled_rectangle = true,
                 ellipse = true, filled_ellipse = true }
local PAINTS_ONE_COLOR = { pencil = true, eraser = true, spray = true, contour = true,
                           polygon = true }

local function alpha(c) return (c >> 24) & 255 end

local function parsePath(text)
  if not text then return nil end
  local body = text:match("^%-?%d+|(.*)$")
  if not body then return nil end
  local pts = {}
  for x, y, dt in body:gmatch("(%-?%d+):(%-?%d+):(%d+)") do
    pts[#pts + 1] = { x = tonumber(x), y = tonumber(y), dt = tonumber(dt) }
  end
  if #pts == 0 then return nil end
  if #pts > MAX_PATH_POINTS then
    local thin = {}
    for i = 1, MAX_PATH_POINTS do
      thin[i] = pts[math.floor((i - 1) * (#pts - 1) / (MAX_PATH_POINTS - 1)) + 1]
    end
    pts = thin
  end
  return pts
end
M.parsePath = parsePath

function M.pathStart(text)
  return text and tonumber(text:match("^(%-?%d+)|")) or nil
end

-- Squared distance from point to segment, and how far along it (0..1).
local function segDist2(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local len2 = dx * dx + dy * dy
  local t = 0
  if len2 > 0 then
    t = ((px - ax) * dx + (py - ay) * dy) / len2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
  end
  local cx, cy = ax + t * dx - px, ay + t * dy - py
  return cx * cx + cy * cy, t
end

-- Breadth-first walk over the changed pixels (8-connected) from `seeds`.
local function bfs(set, w, seeds)
  local dist, order = {}, {}
  local queue, head = {}, 1
  for _, s in ipairs(seeds) do
    if set[s] and not dist[s] then
      dist[s] = 0
      queue[#queue + 1] = s
    end
  end
  while head <= #queue do
    local i = queue[head]
    head = head + 1
    order[#order + 1] = i
    local x, y = i % w, i // w
    local d = dist[i] + 1
    for oy = -1, 1 do
      for ox = -1, 1 do
        if ox ~= 0 or oy ~= 0 then
          local nx, ny = x + ox, y + oy
          if nx >= 0 and nx < w and ny >= 0 then
            local j = ny * w + nx
            if set[j] and not dist[j] then
              dist[j] = d
              queue[#queue + 1] = j
            end
          end
        end
      end
    end
  end
  return order, dist
end

local function nearest(list, w, e, x, y)
  local best, pick = math.huge, list[1]
  for _, i in ipairs(list) do
    local dx, dy = e.x + i % w - x, e.y + i // w - y
    local d = dx * dx + dy * dy
    if d < best then best, pick = d, i end
  end
  return pick
end

-- Strategies: each returns a list of local pixel indices in drawing order,
-- plus optional per-pixel path times (ticks) for real-time playback.

local function byPath(set, list, w, e, pts)
  local n = #list
  local pathLen = 0
  for k = 2, #pts do
    local dx, dy = pts[k].x - pts[k - 1].x, pts[k].y - pts[k - 1].y
    pathLen = pathLen + math.sqrt(dx * dx + dy * dy)
  end
  local r = math.max(1.5, n / math.max(1, pathLen) / 2 + 1)
  local r2 = r * r
  local key, when, matched = {}, {}, {}
  for _, i in ipairs(list) do
    local gx, gy = e.x + i % w, e.y + i // w
    for k = #pts - 1, 1, -1 do
      local a, b = pts[k], pts[k + 1]
      local d2, t = segDist2(gx, gy, a.x, a.y, b.x, b.y)
      if d2 <= r2 then
        key[i] = k + t
        when[i] = a.dt + t * (b.dt - a.dt)
        matched[#matched + 1] = i
        break
      end
    end
  end
  if #matched == 0 then return nil end
  table.sort(matched, function(a, b) return key[a] < key[b] end)
  -- the rest spread out from the pixels the path touched
  return (bfs(set, w, matched)), when
end

-- Walk a line toward where the cursor stopped, or flood a blob out from it.
local function fromCursor(set, list, w, e, cursor)
  local seed = nearest(list, w, e, cursor.x, cursor.y)
  local visit, dist = bfs(set, w, { seed })
  local far = dist[visit[#visit]] or 0
  if far * far > 4 * #list then
    local rev = {}
    for k = #visit, 1, -1 do rev[#rev + 1] = visit[k] end
    return rev
  end
  return visit
end

local function endToEnd(set, list, w)
  local visit = bfs(set, w, { list[1] })
  return (bfs(set, w, { visit[#visit] }))
end

local function sweep(list, w, e, pts)
  local a, b = pts[1], pts[#pts]
  local dx, dy = b.x - a.x, b.y - a.y
  local sorted = {}
  for k, i in ipairs(list) do sorted[k] = i end
  local function proj(i) return (e.x + i % w - a.x) * dx + (e.y + i // w - a.y) * dy end
  table.sort(sorted, function(p, q) return proj(p) < proj(q) end)
  return sorted
end

-- Moved pixels ------------------------------------------------------------------

-- Looks for an offset (dx, dy) where most of the edit's new pixels are copies
-- of pixels that were (dx, dy) away before. Returns the slide or nil.
local function detectMove(before, patch, e, set, list, pts)
  local w, h = e.w, e.h
  local bw, bh = before.width, before.height
  local function beforeAt(lx, ly)
    local gx, gy = e.x + lx, e.y + ly
    if gx < 0 or gy < 0 or gx >= bw or gy >= bh then return nil end
    return before:getPixel(gx, gy)
  end

  local solid = {}
  for _, i in ipairs(list) do
    if alpha(set[i]) > 0 then solid[#solid + 1] = i end
  end
  if #solid < 3 then return nil end

  -- Where could each new pixel have come from? Vote on offsets.
  local index = {}
  for ly = 0, h - 1 do
    for lx = 0, w - 1 do
      local c = beforeAt(lx, ly)
      if c and alpha(c) > 0 then
        local bucket = index[c]
        if not bucket then bucket = {} index[c] = bucket end
        if #bucket <= 64 then bucket[#bucket + 1] = ly * w + lx end
      end
    end
  end
  local votes, candidates = {}, {}
  local step = math.max(1, #solid // 48)
  for k = 1, #solid, step do
    local i = solid[k]
    local bucket = index[set[i]]
    if bucket and #bucket <= 64 then
      local qx, qy = i % w, i // w
      for _, j in ipairs(bucket) do
        local dx, dy = qx - j % w, qy - j // w
        if dx ~= 0 or dy ~= 0 then
          local key = dx .. "," .. dy
          if not votes[key] then
            votes[key] = 0
            candidates[#candidates + 1] = { dx = dx, dy = dy, key = key }
          end
          votes[key] = votes[key] + 1
        end
      end
    end
  end
  if pts and #pts >= 2 then
    local dx, dy = pts[#pts].x - pts[1].x, pts[#pts].y - pts[1].y
    local key = dx .. "," .. dy
    if (dx ~= 0 or dy ~= 0) and not votes[key] then
      votes[key] = 0
      candidates[#candidates + 1] = { dx = dx, dy = dy, key = key }
    end
  end
  table.sort(candidates, function(a, b) return votes[a.key] > votes[b.key] end)

  -- A move explains every changed pixel: either it is a copy from (dx, dy)
  -- away, or it lies where the chunk used to be (the uncovered hole).
  local best, bestScore, bestMatched
  for k = 1, math.min(4, #candidates) do
    local c = candidates[k]
    local matched, count = {}, 0
    for _, i in ipairs(solid) do
      local src = beforeAt(i % w - c.dx, i // w - c.dy)
      if src == set[i] then
        matched[i] = true
        count = count + 1
      end
    end
    if count >= 3 then
      local footprint = {}
      for i in pairs(matched) do
        local sx, sy = i % w - c.dx, i // w - c.dy
        if sx >= 0 and sy >= 0 and sx < w and sy < h then footprint[sy * w + sx] = true end
      end
      local explained = 0
      for _, i in ipairs(list) do
        if matched[i] or footprint[i] then explained = explained + 1 end
      end
      local score = explained / #list
      if count < #solid * 0.3 then score = 0 end
      if not best or score > bestScore then best, bestScore, bestMatched = c, score, matched end
    end
  end
  if not best or bestScore < 0.9 then return nil end

  -- What shows through where the chunk used to be: the most common new color
  -- among pixels that changed but are not part of the chunk.
  local counts, hole, holeCount = {}, 0, -1
  for _, i in ipairs(list) do
    if not bestMatched[i] then
      local c = set[i]
      counts[c] = (counts[c] or 0) + 1
      if counts[c] > holeCount then hole, holeCount = c, counts[c] end
    end
  end
  local source = {}
  for i in pairs(bestMatched) do
    local sx, sy = i % w - best.dx, i // w - best.dy
    if sx >= 0 and sy >= 0 and sx < w and sy < h then source[sy * w + sx] = true end
  end

  local base, chunk = {}, {}
  for _, i in ipairs(list) do
    local lx, ly = i % w, i // w
    local color = set[i]
    if bestMatched[i] then
      color = source[i] and hole or beforeAt(lx, ly) or 0
      chunk[#chunk + 1] = { x = e.x + lx - best.dx, y = e.y + ly - best.dy, color = set[i] }
    end
    base[#base + 1] = { x = e.x + lx, y = e.y + ly, color = color }
  end
  local ticks = (pts and #pts >= 2) and (pts[#pts].dt - pts[1].dt) or 0
  return { move = true, dx = best.dx, dy = best.dy, base = base, chunk = chunk,
           ticks = ticks, pixels = base }
end

-- Entry point -----------------------------------------------------------------

-- before: canvas Image ahead of the edit; patch: Image of the edit's rect;
-- e: entry with x, y, w, h, path, tool, cmd.
-- Returns either a pixel order { pixels, rank, time, ticks } or a slide
-- { move = true, dx, dy, base, chunk, ticks }.
function M.compute(before, patch, e)
  local w, h = e.w, e.h
  local set, list = {}, {}
  local bw, bh = before.width, before.height
  local colors, distinct = {}, 0
  for py = 0, h - 1 do
    for px = 0, w - 1 do
      local gx, gy = e.x + px, e.y + py
      local old = (gx < bw and gy < bh) and before:getPixel(gx, gy) or 0
      local new = patch:getPixel(px, py)
      if old ~= new then
        local i = py * w + px
        set[i] = new
        list[#list + 1] = i
        if not colors[new] then colors[new] = true distinct = distinct + 1 end
      end
    end
  end
  local n = #list
  if n == 0 then return { pixels = {}, rank = {}, time = {}, ticks = 0 } end

  local pts = parsePath(e.path)
  local tool, cmd = e.tool, e.cmd
  local cursor = pts and pts[#pts]

  -- Moves: anything that is not plainly painting. A one-color painting tool
  -- that changed many colors was probably a quick move (Cmd/Ctrl drag).
  local painting = (FREEHAND[tool] or SHAPES[tool] or tool == "paint_bucket"
                    or tool == "gradient") and not cmd
  if not painting or (PAINTS_ONE_COLOR[tool] and distinct > 3) then
    local slide = detectMove(before, patch, e, set, list, pts)
    if slide then return slide end
  end

  local order, when
  if tool == "paint_bucket" and not cmd then
    order = cursor and (bfs(set, w, { nearest(list, w, e, cursor.x, cursor.y) })) or nil
  elseif tool == "gradient" and pts and #pts >= 2 and not cmd then
    order = sweep(list, w, e, pts)
  elseif SHAPES[tool] and pts and not cmd then
    order = (bfs(set, w, { nearest(list, w, e, pts[1].x, pts[1].y) }))
  elseif cmd then
    -- Fill, Stroke, Paste and friends: spread out from the middle
    order = (bfs(set, w, { nearest(list, w, e, e.x + w / 2, e.y + h / 2) }))
  elseif pts and #pts >= 2 then
    order, when = byPath(set, list, w, e, pts)
  end
  if not order then
    if cursor then order = fromCursor(set, list, w, e, cursor)
    else order = endToEnd(set, list, w) end
  end

  -- pixels in parts the walk could not reach (spray, dithering)
  local placed = {}
  for _, i in ipairs(order) do placed[i] = true end
  local seedX, seedY = order[1] % w, order[1] // w
  local rest = {}
  for _, i in ipairs(list) do if not placed[i] then rest[#rest + 1] = i end end
  table.sort(rest, function(a, b)
    local ax, ay, bx, by = a % w - seedX, a // w - seedY, b % w - seedX, b // w - seedY
    return ax * ax + ay * ay < bx * bx + by * by
  end)
  for _, i in ipairs(rest) do order[#order + 1] = i end

  local ticks = (when and pts and #pts >= 2) and (pts[#pts].dt - pts[1].dt) or 0
  local pixels, rank, time = {}, {}, {}
  local lastWhen = 0
  for k, i in ipairs(order) do
    pixels[k] = { x = e.x + i % w, y = e.y + i // w, color = set[i] }
    rank[k] = (k - 1) / n
    if when and when[i] then lastWhen = math.max(lastWhen, when[i]) end
    time[k] = ticks > 0 and (math.max(0, ((when and when[i]) or lastWhen) - pts[1].dt) / ticks) or rank[k]
  end
  for k = 2, n do if time[k] < time[k - 1] then time[k] = time[k - 1] end end
  -- tools other than freehand still take real time if the drag was recorded
  if ticks == 0 and pts and #pts >= 2 then ticks = pts[#pts].dt - pts[1].dt end
  return { pixels = pixels, rank = rank, time = time, ticks = ticks }
end

return M
