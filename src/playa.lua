-- Playa: records every stroke into the .aseprite file and plays it back as
-- a timelapse. https://github.com/mitchellwinn/playa

PLAYA_BUSY = false

local recorder, player, ui

local recs = {}        -- { sprite = Sprite, rec = Rec, listener = id }
local prefs
local listeners = {}
local sampler

local function find(spr)
  for i, r in ipairs(recs) do
    if r.sprite == spr then return r.rec, i end
  end
end

local function prune()
  local open = {}
  for _, s in ipairs(app.sprites) do open[#open + 1] = s end
  for i = #recs, 1, -1 do
    local alive = false
    for _, s in ipairs(open) do
      if s == recs[i].sprite then alive = true break end
    end
    if not alive then table.remove(recs, i) end
  end
end

local function attach(spr)
  local rec = find(spr)
  if rec then return rec end
  rec = recorder.load(spr)
  if rec.on == nil then rec.on = prefs.auto ~= false end
  local entry = { sprite = spr, rec = rec }
  entry.listener = spr.events:on("change", function(ev)
    if PLAYA_BUSY then return end
    local ok, err = pcall(rec.onChange, rec, ev)
    if not ok then print("Playa: " .. tostring(err)) end
  end)
  recs[#recs + 1] = entry
  if rec.on then rec:start() end
  return rec
end

local function active()
  if not app.sprite then return nil end
  return attach(app.sprite)
end

-- Only bookkeeping here: sitechange can fire in the middle of a stroke (when
-- the first stroke on a layer creates its cel), so no sprite reads.
local function onSiteChange()
  if PLAYA_BUSY then return end
  prune()
  active()
end

-- Cursor sampling: the timer feeds each stroke's path to its recording, so
-- playback can draw the stroke's pixels in the order they were laid down.
PLAYA_TICK = 0

function PLAYA_POINTER()
  local ed = app.editor
  if not ed then return nil end
  local ok, pos = pcall(function() return ed.spritePos end)
  if not ok or not pos then return nil end
  return pos.x, pos.y, PLAYA_TICK
end

local function onTick()
  PLAYA_TICK = PLAYA_TICK + 1
  if PLAYA_BUSY then return end
  for _, r in ipairs(recs) do
    if #r.rec.queue > 0 then
      local ok, err = pcall(r.rec.flush, r.rec)
      if not ok then r.rec.queue = {} print("Playa: " .. tostring(err)) end
    end
  end
  if not app.sprite then return end
  local rec = find(app.sprite)
  if not rec or not rec.on then return end
  local x, y, tick = PLAYA_POINTER()
  if x then rec:pointer(x, y, tick) end
end

local SAVE = { SaveFile = true, SaveFileAs = true, SaveFileCopyAs = true }

local function beforeCommand(ev)
  if PLAYA_BUSY or not app.sprite then return end
  local rec = find(app.sprite)
  if not rec then return end
  if ev.name == "Undo" then rec.pending = "u"
  elseif ev.name == "Redo" then rec.pending = "r"
  elseif ev.name ~= "" and not SAVE[ev.name] then
    rec.command = ev.name
  elseif SAVE[ev.name] then
    rec:flush()
    if rec.dirty then rec:save() end
  end
end

local function afterCommand(ev)
  if not app.sprite then return end
  local rec = find(app.sprite)
  if rec then
    rec.pending = nil
    rec.command = nil
  end
end

function init(plugin)
  PLAYA_PATH = app.fs.joinPath(plugin.path, "src")
  recorder = dofile(app.fs.joinPath(PLAYA_PATH, "recorder.lua"))
  player = dofile(app.fs.joinPath(PLAYA_PATH, "player.lua"))
  ui = dofile(app.fs.joinPath(PLAYA_PATH, "ui.lua"))
  prefs = plugin.preferences
  if prefs.auto == nil then prefs.auto = true end

  listeners.site = app.events:on("sitechange", onSiteChange)
  listeners.before = app.events:on("beforecommand", beforeCommand)
  listeners.after = app.events:on("aftercommand", afterCommand)

  -- Timer is unavailable in batch mode.
  if Timer and app.isUIAvailable ~= false then
    local ok, t = pcall(function() return Timer{ interval = 1 / 60, ontick = onTick } end)
    if ok and t then
      sampler = t
      sampler:start()
      PLAYA_DEFER = true
    end
  end

  plugin:newMenuGroup{ id = "playa_menu", title = "Playa", group = "file_export" }

  plugin:newCommand{
    id = "PlayaRecord", title = "Record This Sprite", group = "playa_menu",
    onenabled = function() return app.sprite ~= nil end,
    onchecked = function()
      local rec = app.sprite and find(app.sprite)
      return rec ~= nil and rec.on == true
    end,
    onclick = function()
      local rec = active()
      if not rec then return end
      if rec.on then rec:stop() else rec:start() end
    end,
  }

  plugin:newCommand{
    id = "PlayaPlay", title = "Play Timelapse...", group = "playa_menu",
    onenabled = function() return app.sprite ~= nil end,
    onclick = function()
      local rec = active()
      if rec then rec:flush() ui.play(rec, prefs) end
    end,
  }

  plugin:newCommand{
    id = "PlayaExport", title = "Export Timelapse...", group = "playa_menu",
    onenabled = function() return app.sprite ~= nil end,
    onclick = function()
      local rec = active()
      if not rec then return end
      rec:flush()
      local p = player.new(player.parse(rec.lines), rec.sprite.width, rec.sprite.height)
      if p:total() == 0 then
        app.alert{ title = "Playa", text = "Nothing recorded yet." }
        return
      end
      ui.export(rec, p, prefs)
    end,
  }

  plugin:newMenuSeparator{ group = "playa_menu" }

  plugin:newCommand{
    id = "PlayaAuto", title = "Record Sprites Automatically", group = "playa_menu",
    onchecked = function() return prefs.auto ~= false end,
    onclick = function() prefs.auto = not (prefs.auto ~= false) end,
  }

  plugin:newCommand{
    id = "PlayaClear", title = "Delete Recording...", group = "playa_menu",
    onenabled = function() return app.sprite ~= nil end,
    onclick = function()
      local rec = active()
      if not rec then return end
      local answer = app.alert{ title = "Playa",
        text = { "Delete this sprite's timelapse recording?",
                 "It is removed from the file the next time you save." },
        buttons = { "Delete", "Cancel" } }
      if answer == 1 then
        rec:clear()
        if rec.on then rec:start() end
      end
    end,
  }

  if app.sprite then onSiteChange() end
end

function exit(plugin)
  if sampler then sampler:stop() end
  for _, id in pairs(listeners) do app.events:off(id) end
  for _, r in ipairs(recs) do pcall(function() r.sprite.events:off(r.listener) end) end
  recs = {}
end
