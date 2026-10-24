-- RadioSync client extension (BeamNG GE Lua)
-- Bridges BeamMP server events and the RadioSync UI app, computes distance based volume.

local M = {}

local MUSIC_DIR = "/ui/modules/apps/RadioSync/music/"  -- song cache in the user folder, served to the UI
local MAX_ACTIVE = 3          -- loudest radios played at the same time
local GAIN_INTERVAL = 0.25    -- seconds between volume updates
local REQUEST_INTERVAL = 5    -- seconds between state requests until config arrives
local DOWNLOAD_TIMEOUT = 20   -- seconds without a chunk before a download is retried
local PROGRESS_INTERVAL = 0.5 -- seconds between download progress updates to the UI

local config = nil            -- received from server
local radios = {}             -- [serverVehId] = state
local handlersRegistered = false
local gainTimer = 0
local requestTimer = REQUEST_INTERVAL
local clockTime = 0           -- real seconds since load, used to age received states

local ready = {}              -- [file] = true when cached with the server's size
local downloadQueue = {}      -- files still to fetch, front = next
local download = nil          -- { file, total, received, chunks, lastChunk, retries }
local progressTimer = 0

local stationsList = {}       -- music folder stations from the server (current song + elapsed)
local reportedDurations = {}  -- [file] = true once sent to the server

local function isMP()
  return MPVehicleGE ~= nil and TriggerServerEvent ~= nil and AddEventHandler ~= nil
end

local function toUI(name, data)
  guihooks.trigger(name, data)
end

local function sendServer(event, data)
  if not isMP() then return end
  TriggerServerEvent(event, data and jsonEncode(data) or "")
end

---------------------------------------------------------------------------
-- Vehicle helpers
---------------------------------------------------------------------------

-- Server id ("pid-vid") and ownership of the vehicle the player currently controls.
-- Walking around (BeamNG's "unicycle" walking vehicle) counts as no vehicle, so the radio
-- can't be controlled after getting out and the walker never gets a radio of its own.
local function currentVehicle()
  local gameVid = be:getPlayerVehicleID(0)
  if not gameVid or gameVid < 0 or not MPVehicleGE then return nil, false end
  local veh = be:getObjectByID(gameVid)
  if not veh or veh:getJBeamFilename() == "unicycle" then return nil, false end
  local serverVid = MPVehicleGE.getServerVehicleID(gameVid)
  if not serverVid then return nil, false end
  return serverVid, MPVehicleGE.isOwn(gameVid) == true
end

local function distance(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Camera right vector (BeamNG: +X right, +Y forward), nil if unavailable.
local function cameraRight()
  local ok, right = pcall(function()
    local q = core_camera.getQuat()
    return q * vec3(1, 0, 0)
  end)
  return ok and right or nil
end

local INTERIOR_DISTANCE = 1.5 -- camera closer than this to the vehicle counts as sitting inside
local OWN_EXTERIOR_MIN = 0.5  -- own car heard from a chase/orbit camera never drops below this
local SHIELD_CLOSED = 0.25    -- other radios' level while sitting in a closed car
local SHIELD_OPEN = 0.8       -- ... while sitting in a wide open car
local DEFAULT_VOLUME = 0.7    -- owner volume of radios that don't report one

-- Owner volume 0..1 -> loudness factor (0.7 = 1.0) and reach factor (0.7 = 1.0, 1 = 1.26, 0 = 0.4).
local function ownerLevel(s)
  local v = s.volume or DEFAULT_VOLUME
  return 0.25 + 1.07 * v, 0.4 + 0.86 * v
end

-- True when the active camera is a first person interior view.
local function interiorCamera()
  local ok, name = pcall(function() return core_camera.getActiveCamName(0) end)
  if not ok or type(name) ~= "string" then return false end
  name = name:lower()
  return name:find("driver") ~= nil or name:find("interior") ~= nil
end

-- Returns gains[vid] = 0..1 and fx[vid] = { pan = -1..1, inside = bool, shield = 0..1 } for the
-- loudest radios. inside = the camera sits in this car's cabin (car speaker sound), else heard
-- from outside. shield = how much the listener's own car body blocks that outside radio.
local function computeGains()
  local gains, fx = {}, {}
  if not config then return gains, fx end
  local maxDist = config.maxDistance or 60
  local camPos = core_camera and core_camera.getPosition()
  local right = camPos and cameraRight()
  local playerGameVid = be:getPlayerVehicleID(0)
  local interiorCam = interiorCamera()

  -- Is the listener sitting in a car (not walking)? Then outside radios come through its body.
  local inCar, shield = false, 0
  local playerVeh = playerGameVid and playerGameVid >= 0 and be:getObjectByID(playerGameVid)
  if playerVeh and playerVeh:getJBeamFilename() ~= "unicycle" and camPos
      and (interiorCam or distance(playerVeh:getPosition(), camPos) < INTERIOR_DISTANCE) then
    local playerServerVid = MPVehicleGE.getServerVehicleID(playerGameVid)
    local ownOpen = playerServerVid and radios[playerServerVid] and radios[playerServerVid].open or 0
    inCar, shield = true, 1 - ownOpen
  end
  local shieldGain = SHIELD_OPEN + (SHIELD_CLOSED - SHIELD_OPEN) * shield

  local list = {}
  for serverVid in pairs(radios) do
    local gameVid = MPVehicleGE.getGameVehicleID(serverVid)
    local veh = gameVid and gameVid >= 0 and be:getObjectByID(gameVid)
    if veh then
      local g, pan, inside = 0, 0, false
      local own = gameVid == playerGameVid
      local pos = veh:getPosition()
      local d = camPos and distance(pos, camPos) or 0
      if own and (interiorCam or d < INTERIOR_DISTANCE or not camPos) then
        g, inside = 1, true
      elseif camPos then
        if d < INTERIOR_DISTANCE then
          -- Camera inside someone else's car.
          g, inside = 1, true
        else
          -- Open doors/windows and a turned-up radio carry further.
          local _, reachFactor = ownerLevel(radios[serverVid])
          local reach = maxDist * reachFactor * (1 + 0.5 * (radios[serverVid].open or 0))
          g = d < reach and (1 - d / reach) ^ 2 or 0
          if own then
            g = math.max(g, OWN_EXTERIOR_MIN)
          elseif inCar then
            g = g * shieldGain
          end
          if right then
            local dx, dy, dz = pos.x - camPos.x, pos.y - camPos.y, pos.z - camPos.z
            pan = (dx * right.x + dy * right.y + dz * right.z) / d
            pan = math.max(-1, math.min(1, pan)) * 0.8
          end
        end
      end
      g = g * ownerLevel(radios[serverVid])
      local blocked = (inCar and not inside and not own) and shield or 0
      if g > 0 then table.insert(list, { vid = serverVid, g = g, pan = pan, inside = inside, shield = blocked }) end
    end
  end

  table.sort(list, function(a, b) return a.g > b.g end)
  for i = 1, math.min(#list, MAX_ACTIVE) do
    local e = list[i]
    gains[e.vid] = math.floor(e.g * 1000) / 1000
    fx[e.vid] = { pan = math.floor(e.pan * 100) / 100, inside = e.inside, shield = math.floor(e.shield * 100) / 100 }
  end
  return gains, fx
end

---------------------------------------------------------------------------
-- Server -> client
---------------------------------------------------------------------------

-- Copy of a state with elapsed advanced by the time since it was received.
local function forUI(s)
  if not s then return nil end
  local c = {}
  for k, v in pairs(s) do c[k] = v end
  c.recv = nil
  if c.mode == "track" and not c.paused then
    c.elapsed = (c.elapsed or 0) + (clockTime - (s.recv or clockTime))
  end
  return c
end

---------------------------------------------------------------------------
-- Song cache (downloaded from the server music folder over BeamMP events)
---------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64VAL = {}
for i = 1, 64 do B64VAL[B64:byte(i)] = i - 1 end

local function unbase64(s)
  local out, n = {}, 0
  local floor, char, byte = math.floor, string.char, string.byte
  for i = 1, #s - 3, 4 do
    local a, b, c, d = byte(s, i, i + 3)
    local v = B64VAL[a] * 262144 + B64VAL[b] * 4096 + (B64VAL[c] or 0) * 64 + (B64VAL[d] or 0)
    n = n + 1
    if d == 61 then -- '='
      out[n] = c == 61 and char(floor(v / 65536)) or char(floor(v / 65536), floor(v / 256) % 256)
    else
      out[n] = char(floor(v / 65536), floor(v / 256) % 256, v % 256)
    end
  end
  return table.concat(out)
end

local function localSize(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  f:close()
  return size
end

local function serverSongs()
  return config and type(config.songs) == "table" and config.songs or {}
end

local function uiConfig()
  local c = {}
  for k, v in pairs(config or {}) do c[k] = v end
  c.songs = {}
  for i, s in ipairs(serverSongs()) do
    c.songs[i] = { file = s.file, title = s.title, size = s.size, folder = s.folder, ready = ready[s.file] == true }
  end
  c.musicDir = MUSIC_DIR
  return c
end

local function sendProgress()
  if not download then return end
  toUI("RadioSyncDownload", {
    file = download.file,
    pct = download.total and math.floor(download.received / download.total * 100) or 0,
    left = #downloadQueue,
  })
end

local function startNextDownload()
  if download or #downloadQueue == 0 then return end
  local file = table.remove(downloadQueue, 1)
  download = { file = file, received = 0, chunks = {}, lastChunk = clockTime, retries = 0 }
  sendServer("radioSync_getSong", { file = file })
  sendProgress()
end

-- Compares the server list with the cache and queues everything missing.
local function syncSongCache()
  ready = {}
  local queued = {}
  local newQueue = {}
  for _, s in ipairs(serverSongs()) do
    if localSize(MUSIC_DIR .. s.file) == s.size then
      ready[s.file] = true
    elseif not (download and download.file == s.file) and not queued[s.file] then
      queued[s.file] = true
      table.insert(newQueue, s.file)
    end
  end
  downloadQueue = newQueue
  startNextDownload()
end

-- Song needed right now (radio nearby plays it): fetch it next.
local function prioritize(file)
  if ready[file] or (download and download.file == file) then return end
  for i, f in ipairs(downloadQueue) do
    if f == file then
      table.remove(downloadQueue, i)
      table.insert(downloadQueue, 1, file)
      return
    end
  end
end

local function stationById(id)
  for _, st in ipairs(stationsList) do
    if st.id == id then return st end
  end
end

local function prioritizeState(s)
  if type(s) ~= "table" then return end
  if s.mode == "station" then
    local st = stationById(s.station)
    if st then
      -- Upcoming song first so the switch is seamless, then the current one on top.
      if st.nextFile then prioritize(st.nextFile) end
      if st.file then prioritize(st.file) end
    end
  elseif type(s.url) == "string" and s.url:sub(1, 6) == "music:" then
    prioritize(s.url:sub(7))
  end
end

-- Stations with elapsed advanced by the time since they were received.
local function stationsForUI()
  local list = {}
  for i, st in ipairs(stationsList) do
    local c = {}
    for k, v in pairs(st) do c[k] = v end
    c.recv = nil
    c.elapsed = (st.elapsed or 0) + (clockTime - (st.recv or clockTime))
    list[i] = c
  end
  return list
end

local function onStations(data)
  local ok, t = pcall(jsonDecode, data)
  if not ok or type(t) ~= "table" then return end
  stationsList = {}
  for _, st in ipairs(t) do
    if type(st) == "table" and type(st.id) == "string" then
      st.recv = clockTime
      table.insert(stationsList, st)
    end
  end
  for _, s in pairs(radios) do prioritizeState(s) end
  toUI("RadioSyncStations", stationsForUI())
end

local function finishDownload()
  local d = download
  download = nil
  local data = table.concat(d.chunks)
  local folder = d.file:match("^(.*)/[^/]+$")
  pcall(function() FS:directoryCreate(MUSIC_DIR .. (folder or ""), true) end)
  local f = io.open(MUSIC_DIR .. d.file, "wb")
  if f then
    f:write(data)
    f:close()
    ready[d.file] = true
    log("I", "radioSync", "Song cached: " .. d.file .. " (" .. #data .. " bytes)")
  else
    log("E", "radioSync", "Could not write " .. MUSIC_DIR .. d.file)
  end
  toUI("RadioSyncConfig", uiConfig())
  startNextDownload()
  if not download then toUI("RadioSyncDownload", {}) end
end

-- "<file>|<index>|<total>|<base64>"
local function onChunk(data)
  if type(data) ~= "string" or not download then return end
  local file, index, total, b64 = data:match("^([^|]+)|(%d+)|(%d+)|(.*)$")
  if file ~= download.file then return end
  index, total = tonumber(index), tonumber(total)
  if download.chunks[index] then return end
  download.chunks[index] = unbase64(b64)
  download.total = total
  download.received = download.received + 1
  download.lastChunk = clockTime
  if download.received >= total then finishDownload() end
end

local function onSongMissing(file)
  if download and download.file == file then
    download = nil
    startNextDownload()
    if not download then toUI("RadioSyncDownload", {}) end
  end
end

local function updateDownload(dtReal)
  if not download then return end
  progressTimer = progressTimer + dtReal
  if progressTimer >= PROGRESS_INTERVAL then
    progressTimer = 0
    sendProgress()
  end
  if clockTime - download.lastChunk > DOWNLOAD_TIMEOUT then
    if download.retries >= 2 then
      log("W", "radioSync", "Download failed: " .. download.file)
      onSongMissing(download.file)
    else
      -- Restart from scratch; the server replaces the running transfer.
      download.retries = download.retries + 1
      download.chunks, download.received, download.lastChunk = {}, 0, clockTime
      sendServer("radioSync_getSong", { file = download.file })
    end
  end
end

local function pushAllToUI()
  toUI("RadioSyncConfig", uiConfig())
  toUI("RadioSyncStations", stationsForUI())
  local all = {}
  for vid, s in pairs(radios) do all[vid] = forUI(s) end
  toUI("RadioSyncSnapshot", all)
end

local function onConfig(data)
  local ok, t = pcall(jsonDecode, data)
  if not ok or type(t) ~= "table" then return end
  config = t
  syncSongCache()
  for _, s in pairs(radios) do prioritizeState(s) end
  toUI("RadioSyncConfig", uiConfig())
end

local function onSnapshot(data)
  local ok, t = pcall(jsonDecode, data)
  if not ok or type(t) ~= "table" then return end
  radios = {}
  for vid, s in pairs(t) do
    if type(s) == "table" then
      s.recv = clockTime
      radios[vid] = s
      prioritizeState(s)
    end
  end
  pushAllToUI()
end

local function onState(data)
  local ok, t = pcall(jsonDecode, data)
  if not ok or type(t) ~= "table" or type(t.vid) ~= "string" then return end
  if type(t.state) == "table" then t.state.recv = clockTime end
  radios[t.vid] = t.state
  prioritizeState(t.state)
  toUI("RadioSyncState", { vid = t.vid, state = forUI(t.state) })
end

local function onRemove(vid)
  if type(vid) ~= "string" then return end
  radios[vid] = nil
  toUI("RadioSyncState", { vid = vid, state = nil })
end

-- Live radio: "<id>|<base64 mp3>" from the server, passed straight to the UI (it decodes).
local function onLive(data)
  if type(data) ~= "string" then return end
  local id, b64 = data:match("^([^|]+)|(.*)$")
  if id then toUI("RadioSyncLiveData", { id = id, data = b64 }) end
end

local function onLiveError(id)
  toUI("RadioSyncLiveError", { id = id })
end

-- "<id>|<StreamTitle>" whenever a live station starts a new song.
local function onLiveMeta(data)
  if type(data) ~= "string" then return end
  local id, title = data:match("^([^|]+)|(.*)$")
  if not id then return end
  for _, st in ipairs(config and config.liveStations or {}) do
    if st.id == id then st.nowPlaying = title end
  end
  toUI("RadioSyncLiveMeta", { id = id, title = title })
end

-- Tells the server which live stations this player needs (radios in earshot), so it only
-- relays those. Resent periodically in case the server restarted.
local LIVE_SUB_RESEND = 10
local liveSubKey, liveSubTime = nil, 0

local function updateLiveSubs(gains)
  local ids, seen = {}, {}
  for vid in pairs(gains) do
    local s = radios[vid]
    if s and s.mode == "live" and s.station and not seen[s.station] then
      seen[s.station] = true
      table.insert(ids, s.station)
    end
  end
  table.sort(ids)
  local key = table.concat(ids, ",")
  if key == liveSubKey and clockTime - liveSubTime < LIVE_SUB_RESEND then return end
  liveSubKey, liveSubTime = key, clockTime
  sendServer("radioSync_liveSub", { ids = ids })
end

local function registerHandlers()
  if handlersRegistered or not isMP() then return end
  AddEventHandler("radioSync_config", onConfig)
  AddEventHandler("radioSync_stations", onStations)
  AddEventHandler("radioSync_live", onLive)
  AddEventHandler("radioSync_liveError", onLiveError)
  AddEventHandler("radioSync_liveMeta", onLiveMeta)
  AddEventHandler("radioSync_snapshot", onSnapshot)
  AddEventHandler("radioSync_state", onState)
  AddEventHandler("radioSync_remove", onRemove)
  AddEventHandler("radioSync_chunk", onChunk)
  AddEventHandler("radioSync_songMissing", onSongMissing)
  handlersRegistered = true
end

---------------------------------------------------------------------------
-- Condition of the own cars: openness (doors, tailgate, windows, sunroof, broken glass) and
-- damage/crashes (beamstate.damage = deformation), polled from the vehicle Lua VM and synced
-- through the server so everyone hears it.
---------------------------------------------------------------------------

-- beamstate.damage spans orders of magnitude (light crash ~16k, hard crash ~450k), so the
-- scales below are logarithmic. (monetaryDamage stays 0 in multiplayer/on modded cars.)
local OPEN_POLL_INTERVAL = 0.3
local OPEN_RESEND = 2         -- seconds before an unconfirmed value is sent again
local CRASH_MIN = 3000        -- damage jump within one poll that counts as a crash
local CRASH_FULL = 300000     -- jump that gives the strongest crash effect
local DAMAGE_START = 20000    -- total damage where the radio starts to suffer
local DAMAGE_FULL = 500000    -- total damage for a completely broken sound
local openTimer = 0
local openSent = {}           -- [vid] = { open, damage, time }
local lastDamage = {}         -- [vid] = beamstate.damage at the last poll

-- Runs in the vehicle VM; %q = server vehicle id. Weights: door 0.35, tailgate/trunk 0.25,
-- each window up to 0.2, sunroof up to 0.3, each broken glass/window break group 0.25.
local OPEN_VE = [[
local o = 0
local e = electrics.values
for k, val in pairs(e) do
  local n = tostring(k):lower()
  if n:find("coupler_notattached$") and (tonumber(val) or 0) > 0.5 then
    if n:find("door") then o = o + 0.35
    elseif n:find("tailgate") or n:find("trunk") or n:find("hatch") then o = o + 0.25 end
  elseif n:find("sunroof") and n:find("linear") then
    o = o + 0.3 * math.max(0, math.min(1, tonumber(val) or 0))
  elseif (n:find("^glass") or n:find("^window")) and n:find("linear$") then
    o = o + 0.2 * math.max(0, math.min(1, tonumber(val) or 0))
  end
end
for k in pairs(beamstate.brokenBreakGroups or {}) do
  local n = tostring(k):lower()
  if n:find("glass") or n:find("window") or n:find("windshield") or n:find("windscreen") then o = o + 0.25 end
end
local damage = tonumber(beamstate.damage) or 0
obj:queueGameEngineLua(string.format("extensions.radioSync.onCarState(%%q, %%.2f, %%.0f)", %q, math.min(1, o), damage))
]]

-- Polls every own car with a radio, also while walking around it (doors opened from outside).
local function pollOpenness(dtReal)
  openTimer = openTimer + dtReal
  if openTimer < OPEN_POLL_INTERVAL then return end
  openTimer = 0
  for serverVid in pairs(radios) do
    local gameVid = MPVehicleGE.getGameVehicleID(serverVid)
    if gameVid and gameVid >= 0 and MPVehicleGE.isOwn(gameVid) then
      local veh = be:getObjectByID(gameVid)
      if veh then veh:queueLuaCommand(string.format(OPEN_VE, serverVid)) end
    end
  end
end

local function step05(x)
  return math.floor(math.max(0, math.min(1, x)) * 20 + 0.5) / 20
end

-- 0 at `from`, 1 at `to`, logarithmic in between.
local function logScale(x, from, to)
  if x <= from then return 0 end
  return math.min(1, math.log(x / from) / math.log(to / from))
end

function M.onCarState(vid, open, rawDamage)
  local s = radios[vid]
  open, rawDamage = tonumber(open), tonumber(rawDamage) or 0
  if not s or not open then return end
  open = step05(open)
  local damage = step05(logScale(rawDamage, DAMAGE_START, DAMAGE_FULL))

  -- Crash = damage jumped since the last poll (a vehicle reset lowers it, no crash).
  local crash = nil
  local last = lastDamage[vid]
  if last and rawDamage - last >= CRASH_MIN then
    crash = math.max(0.15, logScale(rawDamage - last, CRASH_MIN, CRASH_FULL))
  end
  lastDamage[vid] = rawDamage

  if crash then
    openSent[vid] = { open = open, damage = damage, time = clockTime }
    sendServer("radioSync_setCar", { vid = vid, open = open, damage = damage, crash = crash })
    return
  end
  if open == (s.open or 0) and damage == (s.damage or 0) then
    openSent[vid] = nil
    return
  end
  local sent = openSent[vid]
  if sent and sent.open == open and sent.damage == damage and clockTime - sent.time < OPEN_RESEND then return end
  openSent[vid] = { open = open, damage = damage, time = clockTime }
  sendServer("radioSync_setCar", { vid = vid, open = open, damage = damage })
end

---------------------------------------------------------------------------
-- Vehicle diagnose: collects door/window/roof related data from the current
-- vehicle (for automatic open-door detection later). Writes radiosync_diagnose.txt.
---------------------------------------------------------------------------

local DIAGNOSE_FILE = "/radiosync_diagnose.txt"
local diagnoseRun = 0

-- Runs inside the vehicle Lua VM, sends its report back via diagnoseResult().
local DIAGNOSE_VE = [[
local out = {}
local function add(s) out[#out + 1] = tostring(s) end
local function section(name, fn)
  add("== " .. name .. " ==")
  local ok, err = pcall(fn)
  if not ok then add("FEHLER: " .. tostring(err)) end
end
local function match(n)
  n = tostring(n):lower()
  return n:find("door") or n:find("latch") or n:find("hatch") or n:find("trunk") or n:find("tailgate")
    or n:find("window") or n:find("roof") or n:find("top") or n:find("glass") or n:find("convert")
    or n:find("coupler") or n:find("hood") or n:find("bonnet")
end
section("electrics", function()
  local keys = {}
  for k in pairs(electrics.values) do if match(k) then keys[#keys + 1] = tostring(k) end end
  table.sort(keys)
  for _, k in ipairs(keys) do add(k .. " = " .. tostring(electrics.values[k])) end
end)
section("controllers", function()
  for _, c in pairs(controller.getAllControllers()) do add(tostring(c.name) .. " : " .. tostring(c.typeName)) end
end)
section("beamstate", function()
  local keys = {}
  for k, val in pairs(beamstate) do keys[#keys + 1] = tostring(k) .. " : " .. type(val) end
  table.sort(keys)
  for _, k in ipairs(keys) do add(k) end
end)
section("damage", function()
  add("monetaryDamage = " .. tostring(beamstate.monetaryDamage))
  add("damage = " .. tostring(beamstate.damage))
end)
section("parts", function()
  local parts = (v.config and v.config.parts) or {}
  local keys = {}
  for slot, part in pairs(parts) do
    if match(slot) or match(part) then keys[#keys + 1] = tostring(slot) .. " = " .. tostring(part) end
  end
  table.sort(keys)
  for _, k in ipairs(keys) do add(k) end
end)
obj:queueGameEngineLua("extensions.radioSync.diagnoseResult(" .. string.format("%q", table.concat(out, "\n")) .. ")")
]]

local function startDiagnose()
  local veh = be:getPlayerVehicle(0)
  if not veh then
    toUI("RadioSyncDiagnose", { code = "noVehicle" })
    return
  end
  diagnoseRun = diagnoseRun + 1
  veh:queueLuaCommand(DIAGNOSE_VE)
end

function M.diagnoseResult(text)
  local veh = be:getPlayerVehicle(0)
  local name = veh and veh.getJBeamFilename and veh:getJBeamFilename() or "?"
  local header = string.format("##### Lauf %d – %s – Fahrzeug: %s #####", diagnoseRun, os.date("%H:%M:%S"), tostring(name))
  local report = header .. "\n" .. tostring(text) .. "\n\n"
  local path = DIAGNOSE_FILE
  local f = io.open(path, "a")
  if f then
    f:write(report)
    f:close()
  else
    path = nil
  end
  toUI("RadioSyncDiagnose", { text = report, path = path, run = diagnoseRun })
end

---------------------------------------------------------------------------
-- UI -> client (called via bngApi.engineLua)
---------------------------------------------------------------------------

local ownerCommands = {
  setStation = "radioSync_setStation",
  setLive = "radioSync_setLive",
  addSongs = "radioSync_addSongs",
  removeTrack = "radioSync_removeTrack",
  playIndex = "radioSync_playIndex",
  control = "radioSync_control",
}

function M.uiCommand(json)
  local ok, msg = pcall(jsonDecode, json)
  if not ok or type(msg) ~= "table" then return end

  if msg.cmd == "uiReady" then
    pushAllToUI()
    if not config then sendServer("radioSync_requestState") end
    return
  end

  if msg.cmd == "diagnose" then
    startDiagnose()
    return
  end

  -- Reports from the audio players.
  if msg.cmd == "ended" then
    sendServer("radioSync_ended", { vid = msg.vid, seq = msg.seq })
    return
  elseif msg.cmd == "songDuration" then
    if not reportedDurations[msg.file] then
      reportedDurations[msg.file] = true
      sendServer("radioSync_songDuration", { file = msg.file, duration = msg.duration })
    end
    return
  end

  local event = ownerCommands[msg.cmd]
  if not event then return end
  local vid, own = currentVehicle()
  if not vid or not own then return end
  local payload = msg.args or {}
  payload.vid = vid
  sendServer(event, payload)
end

---------------------------------------------------------------------------
-- Extension hooks
---------------------------------------------------------------------------

function M.onUpdate(dtReal)
  clockTime = clockTime + dtReal
  if not isMP() then return end
  registerHandlers()
  updateDownload(dtReal)
  pollOpenness(dtReal)

  if not config then
    requestTimer = requestTimer + dtReal
    if requestTimer >= REQUEST_INTERVAL then
      requestTimer = 0
      sendServer("radioSync_requestState")
    end
  end

  gainTimer = gainTimer + dtReal
  if gainTimer < GAIN_INTERVAL then return end
  gainTimer = 0

  local vid, own = currentVehicle()
  local gains, fx = computeGains()
  if config then updateLiveSubs(gains) end
  toUI("RadioSyncGains", {
    gains = gains,
    fx = fx,
    current = vid,
    own = own,
    myPid = MPConfig and MPConfig.getPlayerServerID and MPConfig.getPlayerServerID() or nil,
  })
end

function M.onExtensionLoaded()
  registerHandlers()
end

-- Reloaded level / reconnected: fetch everything again.
function M.onWorldReadyState(state)
  if state == 2 then
    config = nil
    download = nil
    downloadQueue = {}
    liveSubKey = nil
    requestTimer = REQUEST_INTERVAL
  end
end

return M
