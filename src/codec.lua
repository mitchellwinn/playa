-- s.playa codec: compact text encoding for RGBA pixel data.
--
-- Pixels are run-length encoded as 32-bit values, then base64'd so they can
-- live in Aseprite's string properties (which cannot hold NUL bytes).
--
-- RLE token header byte h:
--   0..127   run: (h + 1) copies of the next 4-byte pixel
--   128..255 literal: (h - 127) raw 4-byte pixels follow

local M = {}

local spack, sunpack, schar, sbyte = string.pack, string.unpack, string.char, string.byte
local concat = table.concat

function M.rle(bytes)
  local n = #bytes // 4
  local px = {}
  for k = 1, n do px[k] = sunpack("<I4", bytes, k * 4 - 3) end

  local out = {}
  local k = 1
  while k <= n do
    local p = px[k]
    local r = 1
    while k + r <= n and px[k + r] == p and r < 128 do r = r + 1 end
    if r >= 2 then
      out[#out + 1] = schar(r - 1) .. spack("<I4", p)
      k = k + r
    else
      local lits = {}
      local j = k
      while j <= n and #lits < 128 and not (j < n and px[j] == px[j + 1]) do
        lits[#lits + 1] = spack("<I4", px[j])
        j = j + 1
      end
      out[#out + 1] = schar(127 + #lits) .. concat(lits)
      k = j
    end
  end
  return concat(out)
end

function M.unrle(data)
  local out = {}
  local i, len = 1, #data
  while i <= len do
    local h = sbyte(data, i)
    if h < 128 then
      out[#out + 1] = string.rep(data:sub(i + 1, i + 4), h + 1)
      i = i + 5
    else
      local count = h - 127
      out[#out + 1] = data:sub(i + 1, i + count * 4)
      i = i + 1 + count * 4
    end
  end
  return concat(out)
end

-- base64 -------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local enc, dec = {}, {}
for i = 1, 64 do
  local c = B64:sub(i, i)
  enc[i - 1] = c
  dec[sbyte(c)] = i - 1
end

function M.b64(s)
  local out = {}
  local len = #s
  for i = 1, len, 3 do
    local a, b, c = sbyte(s, i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    out[#out + 1] = enc[(n >> 18) & 63] .. enc[(n >> 12) & 63]
      .. (b and enc[(n >> 6) & 63] or "=")
      .. (c and enc[n & 63] or "=")
  end
  return concat(out)
end

function M.unb64(s)
  local out = {}
  for i = 1, #s, 4 do
    local a, b, c, d = sbyte(s, i, i + 3)
    local n = (dec[a] << 18) | (dec[b] << 12) | ((dec[c] or 0) << 6) | (dec[d] or 0)
    if c == 61 then
      out[#out + 1] = schar((n >> 16) & 255)
    elseif d == 61 then
      out[#out + 1] = schar((n >> 16) & 255, (n >> 8) & 255)
    else
      out[#out + 1] = schar((n >> 16) & 255, (n >> 8) & 255, n & 255)
    end
  end
  return concat(out)
end

function M.encode(bytes) return M.b64(M.rle(bytes)) end
function M.decode(text) return M.unrle(M.unb64(text)) end

return M
