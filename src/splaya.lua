-- s.playa: records every stroke into the .aseprite file and plays it back as
-- a timelapse. https://github.com/mitchellwinn/s-playa

SPLAYA_BUSY = false

local recorder, player, ui

local recs = {}        -- { sprite = Sprite, rec = Rec, listener = id }
local prefs
local listeners = {}

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
    if SPLAYA_BUSY then return end
    local ok, err = pcall(rec.onChange, rec, ev)
    if not ok then print("s.playa: " .. tostring(err)) end
  end)
  recs[#recs + 1] = entry
  if rec.on then rec:start() end
  return rec
end

local function active()
  if not app.sprite then return nil end
  return attach(app.sprite)
end

local function onSiteChange()
  if SPLAYA_BUSY then return end
  prune()
  local rec = active()
  if rec and rec.on and app.frame then
    local ok, err = pcall(rec.look, rec, app.frame.frameNumber)
    if not ok then print("s.playa: " .. tostring(err)) end
  end
end

local SAVE = { SaveFile = true, SaveFileAs = true, SaveFileCopyAs = true }

local function beforeCommand(ev)
  if SPLAYA_BUSY or not app.sprite then return end
  local rec = find(app.sprite)
  if not rec then return end
  if ev.name == "Undo" then rec.pending = "u"
  elseif ev.name == "Redo" then rec.pending = "r"
  elseif SAVE[ev.name] and rec.dirty then
    rec:save()
  end
end

local function afterCommand(ev)
  if not app.sprite then return end
  local rec = find(app.sprite)
  if rec then rec.pending = nil end
end

function init(plugin)
  SPLAYA_PATH = app.fs.joinPath(plugin.path, "src")
  recorder = dofile(app.fs.joinPath(SPLAYA_PATH, "recorder.lua"))
  player = dofile(app.fs.joinPath(SPLAYA_PATH, "player.lua"))
  ui = dofile(app.fs.joinPath(SPLAYA_PATH, "ui.lua"))
  prefs = plugin.preferences
  if prefs.auto == nil then prefs.auto = true end

  listeners.site = app.events:on("sitechange", onSiteChange)
  listeners.before = app.events:on("beforecommand", beforeCommand)
  listeners.after = app.events:on("aftercommand", afterCommand)

  plugin:newMenuGroup{ id = "splaya_menu", title = "s.playa Timelapse", group = "file_export" }

  plugin:newCommand{
    id = "SplayaRecord", title = "Record This Sprite", group = "splaya_menu",
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
    id = "SplayaPlay", title = "Play Timelapse...", group = "splaya_menu",
    onenabled = function() return app.sprite ~= nil end,
    onclick = function()
      local rec = active()
      if rec then ui.play(rec, prefs) end
    end,
  }

  plugin:newCommand{
    id = "SplayaExport", title = "Export Timelapse...", group = "splaya_menu",
    onenabled = function() return app.sprite ~= nil end,
    onclick = function()
      local rec = active()
      if not rec then return end
      local p = player.new(player.parse(rec.lines), rec.sprite.width, rec.sprite.height)
      if p:total() == 0 then
        app.alert{ title = "s.playa", text = "Nothing recorded yet." }
        return
      end
      ui.export(rec, p, prefs)
    end,
  }

  plugin:newMenuSeparator{ group = "splaya_menu" }

  plugin:newCommand{
    id = "SplayaAuto", title = "Record Sprites Automatically", group = "splaya_menu",
    onchecked = function() return prefs.auto ~= false end,
    onclick = function() prefs.auto = not (prefs.auto ~= false) end,
  }

  plugin:newCommand{
    id = "SplayaClear", title = "Delete Recording...", group = "splaya_menu",
    onenabled = function() return app.sprite ~= nil end,
    onclick = function()
      local rec = active()
      if not rec then return end
      local answer = app.alert{ title = "s.playa",
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
  for _, id in pairs(listeners) do app.events:off(id) end
  for _, r in ipairs(recs) do pcall(function() r.sprite.events:off(r.listener) end) end
  recs = {}
end
