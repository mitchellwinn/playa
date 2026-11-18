-- Playa stroke order: decides the order a stroke's pixels appear in.
--
-- A recorded edit stores the pixels that changed, not the order they were
-- painted. When the cursor path was recorded, each pixel is placed where the
-- path last passed over it. Pixels the path never touched (fills, shapes, wide
-- brushes) spread out from the ones it did. Without a path, the order is
-- guessed from the shape: lines are walked end to end, finishing where the
-- cursor stopped; blobs flood out from the cursor or an edge.

local M = {}

local MAX_PATH_POINTS = 200

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

-- Breadth-first distances over the changed pixels (8-connected).
-- `seeds` is a list of indices; returns visit order and distance table.
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

-- before: canvas Image ahead of the edit; patch: Image of the edit's rect;
-- e: entry with x, y, w, h, path.
-- Returns { pixels = { {x, y, color}... }, rank = {0..1}, time = {0..1},
--           ticks = stroke duration in ticks (0 when unknown) }
function M.compute(before, patch, e)
  local w, h = e.w, e.h
  local set, list = {}, {}
  local bw, bh = before.width, before.height
  for py = 0, h - 1 do
    for px = 0, w - 1 do
      local gx, gy = e.x + px, e.y + py
      local old = (gx < bw and gy < bh) and before:getPixel(gx, gy) or 0
      local new = patch:getPixel(px, py)
      if old ~= new then
        local i = py * w + px
        set[i] = new
        list[#list + 1] = i
      end
    end
  end
  local n = #list
  if n == 0 then return { pixels = {}, rank = {}, time = {}, ticks = 0 } end

  local key, when = {}, {}   -- sort key and path time (ticks) per pixel
  local pts = parsePath(e.path)
  local ticks = 0
  local matched = {}

  if pts and #pts >= 2 then
    ticks = pts[#pts].dt - pts[1].dt
    local pathLen = 0
    for k = 2, #pts do
      local dx, dy = pts[k].x - pts[k - 1].x, pts[k].y - pts[k - 1].y
      pathLen = pathLen + math.sqrt(dx * dx + dy * dy)
    end
    local thickness = n / math.max(1, pathLen)
    local r = math.max(1.5, thickness / 2 + 1)
    local r2 = r * r
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
  end

  local order = {}
  if #matched > 0 then
    table.sort(matched, function(a, b) return key[a] < key[b] end)
    -- the rest spread out from the pixels the path touched
    local spread = bfs(set, w, matched)
    for _, i in ipairs(spread) do order[#order + 1] = i end
  else
    local cursor = pts and pts[#pts]
    local seed = list[1]
    if cursor then
      local best = math.huge
      for _, i in ipairs(list) do
        local dx, dy = e.x + i % w - cursor.x, e.y + i // w - cursor.y
        local d = dx * dx + dy * dy
        if d < best then best, seed = d, i end
      end
      local visit, dist = bfs(set, w, { seed })
      local far = dist[visit[#visit]] or 0
      if far * far > 4 * n then
        -- a line that ended at the cursor: walk it from the other end
        for k = #visit, 1, -1 do order[#order + 1] = visit[k] end
      else
        order = visit   -- a blob: flood out from where the cursor was
      end
    else
      local visit = bfs(set, w, { seed })
      local visit2 = bfs(set, w, { visit[#visit] })  -- start from an extreme end
      order = visit2
    end
  end

  -- pixels in parts the walk could not reach (spray, dithering)
  local placed = {}
  for _, i in ipairs(order) do placed[i] = true end
  local seedX, seedY = order[1] and order[1] % w or 0, order[1] and order[1] // w or 0
  local rest = {}
  for _, i in ipairs(list) do if not placed[i] then rest[#rest + 1] = i end end
  table.sort(rest, function(a, b)
    local ax, ay, bx, by = a % w - seedX, a // w - seedY, b % w - seedX, b // w - seedY
    return ax * ax + ay * ay < bx * bx + by * by
  end)
  for _, i in ipairs(rest) do order[#order + 1] = i end

  local pixels, rank, time = {}, {}, {}
  local lastWhen = 0
  for k, i in ipairs(order) do
    pixels[k] = { x = e.x + i % w, y = e.y + i // w, color = set[i] }
    rank[k] = (k - 1) / n
    if when[i] then lastWhen = math.max(lastWhen, when[i]) end
    time[k] = ticks > 0 and (math.max(0, (when[i] or lastWhen) - pts[1].dt) / ticks) or rank[k]
  end
  -- real-time order must still be monotonic for partial drawing
  for k = 2, n do if time[k] < time[k - 1] then time[k] = time[k - 1] end end
  return { pixels = pixels, rank = rank, time = time, ticks = ticks }
end

return M
