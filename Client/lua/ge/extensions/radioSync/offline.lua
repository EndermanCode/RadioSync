-- RadioSync offline mode (singleplayer, no BeamMP server)
-- Runs the real server plugin (Server/RadioSync/main.lua, packed into the client zip by build.ps1)
-- inside the game with stand-ins for the BeamMP server API. The local player is pid 0 and owns
-- every vehicle; the music folder is the client's song cache, so songs never need a download.

local M = {}

local SERVER_FILE = "/lua/ge/extensions/radioSync/server.lua"
local PID = 0

local env = nil       -- environment the server plugin runs in, nil = not running
local events = {}     -- [event] = name of the server function
local timers = {}     -- { { event, interval, acc } }
local outbox = {}     -- server -> client messages, delivered on the next update

local function serverLog(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  log("I", "radioSync.offline", table.concat(parts, " "))
end

local function listFiles(dir, onlyDirs)
  local out = {}
  local ok, list = pcall(function() return FS:findFiles(dir .. "/", "*", 0, false, onlyDirs) end)
  if not ok or type(list) ~= "table" then return out end
  for _, path in ipairs(list) do
    if (FS:directoryExists(path) == true) == onlyDirs then table.insert(out, path) end
  end
  return out
end

local function playerVehicles()
  local t = {}
  for _, veh in ipairs(getAllVehicles()) do t[veh:getID()] = veh:getJBeamFilename() end
  return t
end

local function makeEnv(musicDir)
  local start = os.clockhp()
  local e = setmetatable({}, { __index = _G })
  e.RADIOSYNC_OFFLINE = { musicDir = musicDir }
  e.print = serverLog
  e.os = { time = os.time, clock = os.clock, date = os.date, remove = function() end }  -- no os.execute: no curl
  e.Util = { JsonEncode = jsonEncode, JsonDecode = jsonDecode }
  e.FS = {
    ListFiles = function(dir) return listFiles(dir, false) end,
    ListDirectories = function(dir) return listFiles(dir, true) end,
  }
  e.MP = {
    CreateTimer = function()
      return { GetCurrent = function() return os.clockhp() - start end }
    end,
    RegisterEvent = function(event, fnName) events[event] = fnName end,
    CreateEventTimer = function(event, ms)
      table.insert(timers, { event = event, interval = ms / 1000, acc = 0 })
    end,
    TriggerClientEvent = function(_, event, payload)
      table.insert(outbox, { event = event, payload = payload })
      return true
    end,
    GetPlayerVehicles = function() return playerVehicles() end,
    GetPlayerName = function() return "Offline" end,
    GetPlayerIdentifiers = function() return {} end,
    SendChatMessage = function() end,
  }
  return e
end

local function call(event, ...)
  local fnName = env and events[event]
  local fn = fnName and env[fnName]
  if type(fn) ~= "function" then return end
  local ok, err = pcall(fn, ...)
  if not ok then log("E", "radioSync.offline", event .. ": " .. tostring(err)) end
end

-- Loads the server plugin. musicDir without trailing slash.
function M.start(musicDir)
  if env then return true end
  local f = io.open(SERVER_FILE, "r")
  if not f then
    log("E", "radioSync.offline", "Server plugin missing: " .. SERVER_FILE)
    return false
  end
  local src = f:read("*a")
  f:close()
  local chunk, err = loadstring(src, "=radioSync offline server")
  if not chunk then
    log("E", "radioSync.offline", "Server plugin invalid: " .. tostring(err))
    return false
  end
  events, timers, outbox = {}, {}, {}
  env = makeEnv(musicDir)
  setfenv(chunk, env)
  local ok, runErr = pcall(chunk)
  if not ok then
    log("E", "radioSync.offline", "Server plugin failed: " .. tostring(runErr))
    env = nil
    return false
  end
  return true
end

function M.stop()
  env = nil
  events, timers, outbox = {}, {}, {}
end

function M.running()
  return env ~= nil
end

M.PID = PID

-- Client -> server event.
function M.send(event, data)
  call(event, PID, data or "")
end

function M.vehicleDeleted(gameVid)
  call("onVehicleDeleted", PID, gameVid)
end

-- Runs the server timers and hands queued server messages to deliver(event, payload).
function M.update(dtReal, deliver)
  if not env then return end
  for _, t in ipairs(timers) do
    t.acc = t.acc + dtReal
    if t.acc >= t.interval then
      t.acc = 0
      call(t.event)
    end
  end
  local queue = outbox
  outbox = {}
  for _, msg in ipairs(queue) do deliver(msg.event, msg.payload) end
end

return M
