-- RadioSync server plugin for BeamMP
-- Holds the radio state of every vehicle, runs the music folder radio stations
-- and streams song files to the clients over BeamMP events.

local PLUGIN = "[RadioSync]"

local config = {
  maxDistance = 60,
  maxQueueLength = 50,
  rateLimitPerSecond = 5,
  downloadKBps = 512,      -- per player song transfer speed
  liveRadioTest = true,    -- log once at startup whether this host could relay live radio
  liveStations = {},       -- { { id, title, url } } internet radio relayed by the server (Linux hosts)
  admins = {},             -- player names or BeamMP ids allowed to use /radio admin commands
}

local DEFAULT_VOLUME = 0.7    -- owner's radio volume (0..1) for new radios
local liveEnabled = true      -- /radio live on|off

-- Songs live in ./music on the server (subfolders = radio stations). Clients download them
-- in chunks over BeamMP events and cache them; songs are referenced as "music:<path>".
local MUSIC_EXT = { mp3 = true, ogg = true, oga = true, opus = true, m4a = true, aac = true, wav = true, flac = true, webm = true }
local MUSIC_RESCAN_SECONDS = 30
local CHUNK_SIZE = 32 * 1024
local TRANSFER_TICK_MS = 100
local MIX_STATION = "mix"

local radios = {}     -- [serverVehId "pid-vid"] = state
local songs = {}      -- { { file, title, size, folder } }
local songIndex = {}  -- [file] = song
local durations = {}  -- [file] = seconds (MP3 header or reported by a client)
local confirmedDurations = {} -- [file] = true once a client reported the real length
local stations = {}   -- [id] = { id, title, files, order, pos, file, startedAt, seq }
local transfers = {}  -- [pid] = { song, path, index, total }
local rescanCounter = 0
local rate = {}       -- [pid] = { t = windowStart, n = count }
local clock = MP.CreateTimer()

local function now()
  return clock:GetCurrent()
end

local function log(...)
  print(PLUGIN, ...)
end

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------

local function scriptDir()
  local src = debug.getinfo(1, "S").source or ""
  src = src:gsub("^@", "")
  return src:match("^(.*)[/\\]") or "."
end

local function loadConfig()
  local candidates = {
    scriptDir() .. "/config.json",
    "Resources/Server/RadioSync/config.json",
  }
  for _, path in ipairs(candidates) do
    local f = io.open(path, "r")
    if f then
      local raw = f:read("*a")
      f:close()
      local ok, data = pcall(Util.JsonDecode, raw)
      if ok and type(data) == "table" then
        for k, v in pairs(data) do config[k] = v end
        log("Config loaded from " .. path)
        return
      end
      log("Config at " .. path .. " is invalid JSON, using defaults")
      return
    end
  end
  log("No config.json found, using defaults")
end

---------------------------------------------------------------------------
-- Music folder
---------------------------------------------------------------------------

local function validSegment(name)
  return type(name) == "string" and #name > 0 and #name <= 150
    and not name:find("[/\\%c\"<>|]") and not name:find("%.%.") and name:sub(1, 1) ~= "."
end

-- "song.mp3" or "Folder/song.mp3" with an audio extension.
local function validSongPath(path)
  if type(path) ~= "string" or #path > 300 then return false end
  local folder, name = path:match("^([^/]+)/([^/]+)$")
  if not folder then name = path end
  if folder and not validSegment(folder) then return false end
  if not validSegment(name) then return false end
  local ext = name:match("%.([%w]+)$")
  return ext ~= nil and MUSIC_EXT[ext:lower()] == true
end

local function prettyName(name)
  return (name:gsub("%.[%w]+$", ""):gsub("_", " "))
end

-- RADIOSYNC_OFFLINE is only set when the client runs this plugin in singleplayer (offline mode).
local function musicDir()
  return RADIOSYNC_OFFLINE and RADIOSYNC_OFFLINE.musicDir or scriptDir() .. "/music"
end

local function fileSize(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  f:close()
  return size
end

local function listDir(fn, dir)
  local ok, list = pcall(fn, dir)
  return ok and type(list) == "table" and list or {}
end

-- Length of an MP3 from its first frame (Xing/Info/VBRI header, else CBR estimate).
local MP3_BITRATES = {
  [1] = { 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 },
  [2] = { 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 },
}
local MP3_RATES = { 44100, 48000, 32000 }

local function u32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  if not d then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function mp3Duration(path, size)
  local f = io.open(path, "rb")
  if not f then return nil end
  local head = f:read(10) or ""
  local offset = 0
  if head:sub(1, 3) == "ID3" and #head == 10 then
    local b = { head:byte(7, 10) }
    offset = 10 + ((b[1] % 128 * 128 + b[2] % 128) * 128 + b[3] % 128) * 128 + b[4] % 128
    if math.floor(head:byte(6) / 16) % 2 == 1 then offset = offset + 10 end
  end
  f:seek("set", offset)
  local data = f:read(16384) or ""
  f:close()

  for i = 1, #data - 200 do
    local b1, b2, b3, b4 = data:byte(i, i + 3)
    if b1 == 255 and b2 >= 224 then
      local version = math.floor(b2 / 8) % 4      -- 3 = MPEG1, 2 = MPEG2, 0 = MPEG2.5
      local layer = math.floor(b2 / 2) % 4        -- 1 = Layer III
      local brIndex = math.floor(b3 / 16)
      local srIndex = math.floor(b3 / 4) % 4
      if version ~= 1 and layer == 1 and brIndex > 0 and brIndex < 15 and srIndex < 3 then
        local mpeg1 = version == 3
        local rate = MP3_RATES[srIndex + 1] / (mpeg1 and 1 or (version == 2 and 2 or 4))
        local spf = mpeg1 and 1152 or 576
        local mono = math.floor(b4 / 64) == 3
        local side = mpeg1 and (mono and 17 or 32) or (mono and 9 or 17)
        local x = i + 4 + side
        local tag = data:sub(x, x + 3)
        if tag == "Xing" or tag == "Info" then
          local flags = u32(data, x + 4)
          if flags and flags % 2 == 1 then
            local frames = u32(data, x + 8)
            if frames and frames > 0 then return frames * spf / rate end
          end
        elseif data:sub(i + 36, i + 39) == "VBRI" then
          local frames = u32(data, i + 36 + 14)
          if frames and frames > 0 then return frames * spf / rate end
        end
        local kbps = MP3_BITRATES[mpeg1 and 1 or 2][brIndex]
        return (size - offset - (i - 1)) * 8 / (kbps * 1000)
      end
    end
  end
end

-- Text tags (artist, title) from ID3v2 (2.2/2.3/2.4) or ID3v1, converted to UTF-8.
local function utf8char(cp)
  local floor, char = math.floor, string.char
  if cp < 0x80 then return char(cp) end
  if cp < 0x800 then return char(0xC0 + floor(cp / 64), 0x80 + cp % 64) end
  if cp < 0x10000 then return char(0xE0 + floor(cp / 4096), 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64) end
  return char(0xF0 + floor(cp / 262144), 0x80 + floor(cp / 4096) % 64, 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
end

local function latin1(s)
  return (s:gsub("[\128-\255]", function(c) return utf8char(c:byte()) end))
end

-- enc: 0 = ISO-8859-1, 1 = UTF-16 with BOM, 2 = UTF-16BE, 3 = UTF-8
local function id3Decode(enc, s)
  if enc == 0 then return latin1((s:gsub("%z.*$", ""))) end
  if enc == 3 then return (s:gsub("%z.*$", "")) end
  local be = enc == 2
  local i = 1
  if enc == 1 and #s >= 2 then
    local a, b = s:byte(1, 2)
    if a == 0xFE and b == 0xFF then be, i = true, 3 elseif a == 0xFF and b == 0xFE then be, i = false, 3 end
  end
  local out = {}
  while i + 1 <= #s do
    local a, b = s:byte(i, i + 1)
    local u = be and (a * 256 + b) or (b * 256 + a)
    i = i + 2
    if u == 0 then break end
    if u >= 0xD800 and u < 0xDC00 and i + 1 <= #s then
      local c, d = s:byte(i, i + 1)
      local lo = be and (c * 256 + d) or (d * 256 + c)
      i = i + 2
      u = 0x10000 + (u - 0xD800) * 1024 + (lo - 0xDC00)
    end
    out[#out + 1] = utf8char(u)
  end
  return table.concat(out)
end

local function cleanTag(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("[%c]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return nil end
  return s:sub(1, 100)
end

local function readTags(path, size)
  local f = io.open(path, "rb")
  if not f then return nil end
  local artist, title
  local head = f:read(10) or ""
  if head:sub(1, 3) == "ID3" and #head == 10 then
    local ver, flags = head:byte(4), head:byte(6)
    local b = { head:byte(7, 10) }
    local tagSize = ((b[1] % 128 * 128 + b[2] % 128) * 128 + b[3] % 128) * 128 + b[4] % 128
    local data = f:read(math.min(tagSize, 4 * 1024 * 1024)) or ""
    local pos = 1
    if math.floor(flags / 64) % 2 == 1 and ver >= 3 then
      local e = { data:byte(1, 4) }
      if ver == 3 then
        pos = pos + 4 + u32(data, 1)
      else
        pos = pos + ((e[1] * 128 + e[2]) * 128 + e[3]) * 128 + e[4]
      end
    end
    while pos + 10 <= #data and not (artist and title) do
      local id, fsize, hdr
      if ver == 2 then
        id = data:sub(pos, pos + 2)
        local x, y, z = data:byte(pos + 3, pos + 5)
        fsize, hdr = (x * 256 + y) * 256 + z, 6
      else
        id = data:sub(pos, pos + 3)
        local s1, s2, s3, s4 = data:byte(pos + 4, pos + 7)
        if ver == 4 then
          fsize = ((s1 * 128 + s2) * 128 + s3) * 128 + s4
        else
          fsize = ((s1 * 256 + s2) * 256 + s3) * 256 + s4
        end
        hdr = 10
      end
      if id:byte(1) == 0 or fsize <= 0 then break end
      local body = data:sub(pos + hdr, pos + hdr + fsize - 1)
      if id == "TIT2" or id == "TT2" then
        title = cleanTag(id3Decode(body:byte(1), body:sub(2)))
      elseif id == "TPE1" or id == "TP1" then
        artist = cleanTag(id3Decode(body:byte(1), body:sub(2)))
      end
      pos = pos + hdr + fsize
    end
  end
  if not title and size and size > 128 then
    f:seek("set", size - 128)
    local v1 = f:read(128) or ""
    if v1:sub(1, 3) == "TAG" then
      title = cleanTag(latin1((v1:sub(4, 33):gsub("%z.*$", ""))))
      artist = artist or cleanTag(latin1((v1:sub(34, 63):gsub("%z.*$", ""))))
    end
  end
  f:close()
  if not title and not artist then return nil end
  return { artist = artist, title = title }
end

local tagCache = {}   -- [file] = { size, tags }

-- Duration used by the stations: known value, else a guess from the file size (192 kbps).
local function songDuration(song)
  return durations[song.file] or song.size * 8 / 192000
end

local function shuffled(list, avoidFirst)
  local t = {}
  for i, v in ipairs(list) do t[i] = v end
  for i = #t, 2, -1 do
    local j = math.random(i)
    t[i], t[j] = t[j], t[i]
  end
  if avoidFirst and #t > 1 and t[1] == avoidFirst then t[1], t[#t] = t[#t], t[1] end
  return t
end

local function stationNext(st)
  st.pos = st.pos + 1
  if st.pos > #st.order then
    st.order = shuffled(st.files, st.file)
    st.pos = 1
  end
  st.file = st.order[st.pos]
  st.startedAt = now()
  st.seq = st.seq + 1
end

local function publicStations()
  local list = {}
  local t = now()
  for _, st in pairs(stations) do
    local song = songIndex[st.file]
    table.insert(list, {
      id = st.id,
      title = st.title,
      count = #st.files,
      file = st.file,
      songTitle = song and song.title or "",
      elapsed = t - st.startedAt,
      duration = song and songDuration(song) or 0,
      seq = st.seq,
      nextFile = st.order[st.pos + 1],
    })
  end
  table.sort(list, function(a, b)
    if (a.id == MIX_STATION) ~= (b.id == MIX_STATION) then return a.id == MIX_STATION end
    return a.title:lower() < b.title:lower()
  end)
  return list
end

local function broadcastStations(target)
  MP.TriggerClientEvent(target or -1, "radioSync_stations", Util.JsonEncode(publicStations()))
end

-- Builds stations from the song list; running stations keep their current song.
local function rebuildStations()
  local byId = {}
  local function add(id, title, file)
    byId[id] = byId[id] or { id = id, title = title, files = {} }
    table.insert(byId[id].files, file)
  end
  for _, s in ipairs(songs) do
    add(MIX_STATION, "Mix (alle Songs)", s.file)
    if s.folder then add("folder:" .. s.folder, prettyName(s.folder), s.file) end
  end

  local new = {}
  for id, def in pairs(byId) do
    local old = stations[id]
    if old and songIndex[old.file] then
      old.title, old.files = def.title, def.files
      old.order, old.pos = shuffled(def.files, old.file), 0
      new[id] = old
    else
      local st = { id = id, title = def.title, files = def.files, order = shuffled(def.files), pos = 0, seq = 0 }
      stationNext(st)
      new[id] = st
    end
  end
  stations = new
end

-- Rescans ./music (root + one level of subfolders). Returns true when the song list changed.
local function scanMusic()
  if not FS or not FS.ListFiles then
    log("FS.ListFiles not available, music folder disabled (update BeamMP-Server)")
    return false
  end
  local dir = musicDir()
  local list = {}
  local function addFiles(folder)
    local path = folder and (dir .. "/" .. folder) or dir
    for _, entry in pairs(listDir(FS.ListFiles, path)) do
      local name = tostring(entry):match("([^/\\]+)$")
      local file = folder and (folder .. "/" .. name) or name
      if validSongPath(file) then
        local size = fileSize(path .. "/" .. name)
        if size and size > 0 then
          table.insert(list, { file = file, title = prettyName(name), size = size, folder = folder })
        end
      end
    end
  end
  addFiles(nil)
  if FS.ListDirectories then
    for _, entry in pairs(listDir(FS.ListDirectories, dir)) do
      local folder = tostring(entry):match("([^/\\]+)$")
      if validSegment(folder) then addFiles(folder) end
    end
  end
  table.sort(list, function(a, b) return a.file:lower() < b.file:lower() end)

  local changed = #list ~= #songs
  if not changed then
    for i, s in ipairs(list) do
      if s.file ~= songs[i].file or s.size ~= songs[i].size then changed = true break end
    end
  end
  if changed then
    local oldSizes = {}
    for _, s in ipairs(songs) do oldSizes[s.file] = s.size end
    songs = list
    songIndex = {}
    for _, s in ipairs(songs) do
      songIndex[s.file] = s
      if oldSizes[s.file] ~= s.size then
        durations[s.file] = nil
        confirmedDurations[s.file] = nil
        if s.file:lower():match("%.mp3$") then
          local ok, d = pcall(mp3Duration, dir .. "/" .. s.file, s.size)
          if ok and d and d > 1 and d < 36000 then durations[s.file] = d end
        end
      end
      -- "Artist – Title" from the tags, else the file name.
      local cached = tagCache[s.file]
      if not cached or cached.size ~= s.size then
        local ok, tags = pcall(readTags, dir .. "/" .. s.file, s.size)
        cached = { size = s.size, tags = ok and tags or nil }
        tagCache[s.file] = cached
      end
      local tags = cached.tags
      if tags and tags.title then
        s.title = tags.artist and (tags.artist .. " – " .. tags.title) or tags.title
      end
    end
    rebuildStations()
    local count = 0
    for _ in pairs(stations) do count = count + 1 end
    log("Music folder: " .. #songs .. " songs, " .. count .. " stations")
  end
  return changed
end

---------------------------------------------------------------------------
-- Live radio relay check (option for a later version)
---------------------------------------------------------------------------

-- Checks whether this host lets plugins run curl and reach a radio stream. Never blocks:
-- curl runs in the background and writes to a file that the tick reads LIVE_TEST_WAIT s later.
local LIVE_TEST_PREFIX = "Live-Radio-Test: "
local LIVE_TEST_WAIT = 10
local LIVE_TEST_URL = "http://stream.radioparadise.com/mp3-192"
local liveTest = nil   -- { file, at }

local function startLiveRadioTest()
  if not os.execute then
    log(LIVE_TEST_PREFIX .. "NICHT moeglich (os.execute ist gesperrt)")
    return
  end
  local file = scriptDir() .. "/livetest.txt"
  os.remove(file)
  local cmd
  if package.config:sub(1, 1) == "\\" then
    cmd = 'start "" /b cmd /c "(curl --version & curl -s -L -m 4 -o NUL -w BYTES:%{size_download} '
      .. LIVE_TEST_URL .. ') > "' .. file .. '" 2>&1"'
  else
    cmd = '(curl --version | head -n 1; curl -s -L -m 4 -o /dev/null -w "BYTES:%{size_download}" "'
      .. LIVE_TEST_URL .. '") > "' .. file .. '" 2>&1 &'
  end
  log(LIVE_TEST_PREFIX .. "laeuft im Hintergrund, Ergebnis in " .. LIVE_TEST_WAIT .. " s")
  local ok, err = pcall(os.execute, cmd)
  if not ok then
    log(LIVE_TEST_PREFIX .. "NICHT moeglich (Programme starten gesperrt: " .. tostring(err) .. ")")
    return
  end
  liveTest = { file = file, at = now() + LIVE_TEST_WAIT }
end

local function checkLiveRadioTest()
  if not liveTest or now() < liveTest.at then return end
  local f = io.open(liveTest.file, "r")
  local out = f and f:read("*a") or ""
  if f then f:close() end
  os.remove(liveTest.file)
  liveTest = nil

  local bytes = tonumber(out:match("BYTES:(%d+)") or "") or 0
  local version = out:match("(curl %S+)")
  if bytes >= 1024 then
    log(LIVE_TEST_PREFIX .. "MOEGLICH (" .. tostring(version) .. ", " .. bytes .. " Bytes in 4 s empfangen)")
  elseif not version then
    log(LIVE_TEST_PREFIX .. "NICHT moeglich (curl fehlt oder Programme starten gesperrt)")
  else
    log(LIVE_TEST_PREFIX .. "NICHT moeglich (curl da, aber kein Internet-Stream erreichbar)")
  end
end

---------------------------------------------------------------------------
-- Live radio relay: curl writes the station into a file in the background, the tick
-- reads what's new and sends it to the players that subscribed to that station.
---------------------------------------------------------------------------

local LIVE_READ_EVERY = 3        -- transfer ticks (x100 ms) between file reads
local LIVE_MAX_READ = 64 * 1024  -- bytes per read
local LIVE_IDLE_STOP = 30        -- seconds without listeners before curl is stopped
local LIVE_ROTATE = 1800         -- curl --max-time; a new file starts afterwards
local LIVE_NO_DATA = 15          -- seconds without data until the station counts as failed
local LIVE_RETRY = 60            -- seconds before a failed station is tried again

local live = {}       -- [id] = { def, proc, idleSince, failedAt }
local liveSubs = {}   -- [pid] = { [id] = true }
local liveReadCounter = 0
local isWindows = package.config:sub(1, 1) == "\\"

local function liveById(id)
  return type(id) == "string" and live[id] or nil
end

local function liveFile(id, gen)
  return scriptDir() .. "/live_" .. id .. "_" .. gen .. ".mp3"
end

local function livePidFile(id)
  return scriptDir() .. "/live_" .. id .. ".pid"
end

local function killPidFile(pidFile)
  local f = io.open(pidFile, "r")
  if not f then return end
  local pid = tonumber(f:read("*l") or "")
  f:close()
  os.remove(pidFile)
  if pid then os.execute("kill " .. pid .. " >/dev/null 2>&1") end
end

local function stopLive(st)
  if not st.proc then return end
  killPidFile(livePidFile(st.def.id))
  os.remove(st.proc.file)
  os.remove(st.proc.headers)
  st.proc = nil
end

-- curl asks for ICY metadata (current song title); the response headers go to a separate file
-- so the tick can read icy-metaint and strip the metadata blocks out of the audio.
local function startLive(st)
  stopLive(st)
  local gen = (st.gen or 0) + 1
  st.gen = gen
  local file = liveFile(st.def.id, gen)
  local headers = file .. ".headers"
  os.remove(file)
  os.remove(headers)
  local cmd = 'curl -s -L -A "RadioSync" -H "Icy-MetaData: 1" --max-time ' .. LIVE_ROTATE
    .. ' -D "' .. headers .. '" -o "' .. file .. '" "' .. st.def.url .. '" >/dev/null 2>&1 & echo $! > "'
    .. livePidFile(st.def.id) .. '"'
  local ok = pcall(os.execute, cmd)
  if not ok then
    st.failedAt = now()
    return
  end
  st.proc = { file = file, headers = headers, pos = 0, startedAt = now(), lastData = now() }
end

-- Reads icy-metaint from the last response in the headers file (after redirects).
local function readMetaint(p)
  local f = io.open(p.headers, "r")
  if not f then return nil end
  local text = f:read("*a") or ""
  f:close()
  local metaint
  for v in text:lower():gmatch("icy%-metaint:%s*(%d+)") do metaint = tonumber(v) end
  return metaint
end

local function validUtf8(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    local len = c < 0x80 and 1 or (c >= 0xC2 and c < 0xE0) and 2 or (c >= 0xE0 and c < 0xF0) and 3
      or (c >= 0xF0 and c < 0xF5) and 4 or nil
    if not len or i + len - 1 > n then return false end
    for j = i + 1, i + len - 1 do
      local d = s:byte(j)
      if d < 0x80 or d > 0xBF then return false end
    end
    i = i + len
  end
  return true
end

-- Splits relayed bytes into audio and ICY metadata: every <metaint> audio bytes comes one length
-- byte (x16) and that much metadata. Returns the audio and a new StreamTitle (or nil).
local function stripIcy(p, data)
  local out, i, n, title = {}, 1, #data, nil
  p.untilMeta = p.untilMeta or p.metaint
  while i <= n do
    if p.metaLeft == -1 then
      local len = data:byte(i) * 16
      i = i + 1
      if len == 0 then
        p.metaLeft, p.untilMeta = nil, p.metaint
      else
        p.metaLeft, p.metaBuf = len, {}
      end
    elseif p.metaLeft then
      local take = math.min(p.metaLeft, n - i + 1)
      p.metaBuf[#p.metaBuf + 1] = data:sub(i, i + take - 1)
      i = i + take
      p.metaLeft = p.metaLeft - take
      if p.metaLeft == 0 then
        local meta = table.concat(p.metaBuf):gsub("%z+$", "")
        local t = meta:match("StreamTitle='(.-)';")
        if t then title = t end
        p.metaLeft, p.metaBuf, p.untilMeta = nil, nil, p.metaint
      end
    else
      local take = math.min(p.untilMeta, n - i + 1)
      out[#out + 1] = data:sub(i, i + take - 1)
      i = i + take
      p.untilMeta = p.untilMeta - take
      if p.untilMeta == 0 then p.metaLeft = -1 end
    end
  end
  if title then
    if not validUtf8(title) then title = latin1(title) end
    title = title:gsub("[%c|]", ""):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 120)
  end
  return table.concat(out), title
end

local function liveListeners(id)
  local n = 0
  for _, set in pairs(liveSubs) do
    if set[id] then n = n + 1 end
  end
  return n
end

local function setupLive()
  live = {}
  if type(config.liveStations) ~= "table" then return end
  for _, def in ipairs(config.liveStations) do
    if type(def) == "table" and type(def.id) == "string" and def.id:match("^[%w_%-]+$")
        and type(def.url) == "string" and def.url:match("^https?://") and not def.url:find("[\"'`$\\%s]") then
      live[def.id] = { def = { id = def.id, title = tostring(def.title or def.id), url = def.url } }
      -- Leftover curl from a previous server run.
      killPidFile(livePidFile(def.id))
    end
  end
  if next(live) and isWindows then
    log("Live-Radio: nur auf Linux-Servern unterstuetzt")
    live = {}
  end
end

local function publicLive()
  local list = {}
  if not liveEnabled then return list end
  for _, def in ipairs(config.liveStations or {}) do
    if type(def) == "table" and live[def.id] then
      table.insert(list, { id = def.id, title = live[def.id].def.title, nowPlaying = live[def.id].nowPlaying })
    end
  end
  return list
end

-- Starts/stops curl by listener count and relays new bytes. Chunk format: "<id>|<base64>".
local function liveTick(base64)
  liveReadCounter = liveReadCounter + 1
  if liveReadCounter < LIVE_READ_EVERY then return end
  liveReadCounter = 0
  local t = now()
  for id, st in pairs(live) do
    local listeners = liveEnabled and liveListeners(id) or 0
    if listeners == 0 then
      st.idleSince = st.idleSince or t
      if st.proc and t - st.idleSince > LIVE_IDLE_STOP then stopLive(st) end
    else
      st.idleSince = nil
      if not st.proc and (not st.failedAt or t - st.failedAt > LIVE_RETRY) then
        st.failedAt = nil
        startLive(st)
      end
    end

    local p = st.proc
    if p then
      local f = io.open(p.file, "rb")
      local data
      if f then
        f:seek("set", p.pos)
        data = f:read(LIVE_MAX_READ)
        f:close()
      end
      if data and #data > 0 then
        p.pos = p.pos + #data
        p.lastData = t
        if not p.headersRead then
          p.headersRead = true
          p.metaint = readMetaint(p)
        end
        local audio, title = data, nil
        if p.metaint and p.metaint > 0 then audio, title = stripIcy(p, data) end
        if title and title ~= "" and title ~= st.nowPlaying then
          st.nowPlaying = title
          MP.TriggerClientEvent(-1, "radioSync_liveMeta", id .. "|" .. title)
        end
        if #audio > 0 then
          local payload = id .. "|" .. base64(audio)
          for pid, set in pairs(liveSubs) do
            if set[id] then MP.TriggerClientEvent(pid, "radioSync_live", payload) end
          end
        end
      elseif t - p.lastData > LIVE_NO_DATA then
        if p.pos == 0 then
          log("Live-Radio " .. id .. ": keine Daten von " .. st.def.url)
          st.failedAt = t
          stopLive(st)
          MP.TriggerClientEvent(-1, "radioSync_liveError", id)
        else
          -- curl ended (--max-time rotation or connection lost): next file.
          startLive(st)
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64CHARS = {}
for i = 1, 64 do B64CHARS[i - 1] = B64:sub(i, i) end

local function base64(data)
  local out, n = {}, 0
  local floor = math.floor
  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    n = n + 1
    out[n] = B64CHARS[floor(v / 262144) % 64] .. B64CHARS[floor(v / 4096) % 64]
      .. (b and B64CHARS[floor(v / 64) % 64] or "=") .. (c and B64CHARS[v % 64] or "=")
  end
  return table.concat(out)
end

local function decode(data)
  if type(data) ~= "string" or #data == 0 or #data > 16384 then return nil end
  local ok, t = pcall(Util.JsonDecode, data)
  if ok and type(t) == "table" then return t end
end

local function rateLimited(pid)
  local t = now()
  local r = rate[pid]
  if not r or t - r.t >= 1 then
    rate[pid] = { t = t, n = 1 }
    return false
  end
  r.n = r.n + 1
  return r.n > config.rateLimitPerSecond
end

-- Sender must own the vehicle ("pid-vid") and the vehicle must exist.
local function ownsVehicle(pid, vehId)
  if type(vehId) ~= "string" then return false end
  local ownerPid, vid = vehId:match("^(%d+)%-(%d+)$")
  if not ownerPid or tonumber(ownerPid) ~= pid then return false end
  local vehicles = MP.GetPlayerVehicles(pid)
  return type(vehicles) == "table" and vehicles[tonumber(vid)] ~= nil
end

---------------------------------------------------------------------------
-- Vehicle radios
---------------------------------------------------------------------------

-- Snapshot of a state as sent to clients (elapsed computed at send time).
local function publicState(s)
  local elapsed = 0
  if s.mode == "track" then
    elapsed = (s.paused and s.pausedAt or now()) - s.startedAt
  end
  return {
    mode = s.mode,          -- "station" | "live" | "track"
    station = s.station,
    url = s.url,
    title = s.title,
    paused = s.paused,
    elapsed = elapsed,
    seq = s.seq,
    index = s.index,
    queue = s.queue,
    loop = s.loop,
    open = s.open,          -- 0..1 how open the car is (doors, tailgate, sunroof, broken glass)
    volume = s.volume,      -- 0..1 set by the owner, changes loudness and reach for everyone
    damage = s.damage,      -- 0..1 how broken the radio sounds
    crashSeq = s.crashSeq,  -- increments on every crash, clients play a dropout
    crashPower = s.crashPower,
  }
end

local function broadcastState(vehId, target)
  local s = radios[vehId]
  local payload = Util.JsonEncode({ vid = vehId, state = s and publicState(s) or nil })
  MP.TriggerClientEvent(target or -1, "radioSync_state", payload)
end

local function broadcastRemove(vehId)
  MP.TriggerClientEvent(-1, "radioSync_remove", vehId)
end

local function sendConfig(pid)
  MP.TriggerClientEvent(pid, "radioSync_config", Util.JsonEncode({
    maxDistance = config.maxDistance,
    maxQueueLength = config.maxQueueLength,
    songs = songs,
    liveStations = publicLive(),
  }))
end

local function sendSnapshot(pid)
  local all = {}
  for vehId, s in pairs(radios) do
    all[vehId] = publicState(s)
  end
  MP.TriggerClientEvent(pid, "radioSync_snapshot", Util.JsonEncode(all))
end

local function removeRadio(vehId)
  if radios[vehId] then
    radios[vehId] = nil
    broadcastRemove(vehId)
  end
end

-- Start the queue entry at index i (track mode).
local function playIndex(s, i)
  local track = s.queue[i]
  if not track then return false end
  s.index = i
  s.url = track.url
  s.title = track.title
  s.startedAt = now()
  s.paused = false
  s.pausedAt = nil
  s.seq = s.seq + 1
  return true
end

local function newState()
  return {
    mode = "track",
    station = nil,
    url = nil,
    title = nil,
    queue = {},
    index = 0,
    startedAt = now(),
    paused = false,
    pausedAt = nil,
    seq = 0,
    loop = "all",   -- "all" | "one" | "off"
    open = 0,
    volume = DEFAULT_VOLUME,
    damage = 0,
    crashSeq = 0,
    crashPower = 0,
  }
end

-- Queue position after the current track, honoring the loop mode (nil = stop).
local function nextIndex(s, manual)
  if s.loop == "one" and not manual then return s.index end
  local i = s.index + 1
  if i > #s.queue then
    if s.loop == "off" then return nil end
    i = 1
  end
  return i
end

local function advance(vehId, s)
  local i = nextIndex(s, false)
  if not i or not playIndex(s, i) then
    removeRadio(vehId)
    return
  end
  broadcastState(vehId)
end

---------------------------------------------------------------------------
-- Client -> server events
---------------------------------------------------------------------------

-- Wrap a handler with decode, rate limit and owner check.
local function ownerHandler(fn)
  return function(pid, data)
    if rateLimited(pid) then return end
    local msg = decode(data)
    if not msg then return end
    if not ownsVehicle(pid, msg.vid) then
      log("Rejected " .. tostring(msg.vid) .. " from " .. tostring(MP.GetPlayerName(pid)) .. " (not owner)")
      return
    end
    fn(pid, msg)
  end
end

-- { vid, stationId } tunes the car radio to a music folder station.
radioSync_setStation = ownerHandler(function(pid, msg)
  local st = stations[msg.stationId]
  if not st then return end
  local s = radios[msg.vid] or newState()
  s.mode = "station"
  s.station = st.id
  s.url = nil
  s.title = st.title
  s.paused = false
  s.pausedAt = nil
  s.seq = s.seq + 1
  radios[msg.vid] = s
  broadcastState(msg.vid)
end)

-- { vid, liveId } tunes the car radio to an internet station relayed by the server.
radioSync_setLive = ownerHandler(function(pid, msg)
  local st = liveById(msg.liveId)
  if not st or not liveEnabled then return end
  local s = radios[msg.vid] or newState()
  s.mode = "live"
  s.station = st.def.id
  s.url = nil
  s.title = st.def.title
  s.paused = false
  s.pausedAt = nil
  s.seq = s.seq + 1
  radios[msg.vid] = s
  broadcastState(msg.vid)
end)

-- { ids = { "1live", ... } } live stations this player needs right now (own car / cars in earshot).
function radioSync_liveSub(pid, data)
  if rateLimited(pid) then return end
  local msg = decode(data)
  if not msg or type(msg.ids) ~= "table" then return end
  local set = {}
  for _, id in ipairs(msg.ids) do
    if liveById(id) then set[id] = true end
  end
  liveSubs[pid] = set
end

-- { vid, files = { "song.mp3", ... } } adds songs from the music folder to the playlist.
radioSync_addSongs = ownerHandler(function(pid, msg)
  if type(msg.files) ~= "table" then return end
  local s = radios[msg.vid] or newState()
  radios[msg.vid] = s
  local added = 0
  for _, file in ipairs(msg.files) do
    local song = type(file) == "string" and songIndex[file]
    if song and #s.queue < config.maxQueueLength then
      table.insert(s.queue, { url = "music:" .. song.file, title = song.title })
      added = added + 1
    end
  end
  if added == 0 then return end
  if s.mode ~= "track" or not s.url then
    s.mode = "track"
    s.station = nil
    playIndex(s, #s.queue - added + 1)
  end
  broadcastState(msg.vid)
end)

-- { vid, index } removes a playlist entry.
radioSync_removeTrack = ownerHandler(function(pid, msg)
  local s = radios[msg.vid]
  local i = tonumber(msg.index)
  if not s or not i or not s.queue[i] then return end
  table.remove(s.queue, i)
  if s.mode == "track" then
    if i == s.index then
      if not playIndex(s, math.min(i, #s.queue)) then
        s.url, s.title, s.index = nil, nil, 0
        s.seq = s.seq + 1
      end
    elseif i < s.index then
      s.index = s.index - 1
    end
  end
  broadcastState(msg.vid)
end)

-- { vid, index } jumps to a playlist entry.
radioSync_playIndex = ownerHandler(function(pid, msg)
  local s = radios[msg.vid]
  if not s then return end
  s.mode = "track"
  s.station = nil
  if playIndex(s, tonumber(msg.index) or 1) then
    broadcastState(msg.vid)
  end
end)

-- { vid, cmd = "play"|"pause"|"next"|"prev"|"stop"|"clear"|"seek"|"loop"|"volume", pos, mode, value }
radioSync_control = ownerHandler(function(pid, msg)
  local s = radios[msg.vid]
  if not s then return end
  local cmd = msg.cmd
  if cmd == "pause" and not s.paused then
    s.paused = true
    s.pausedAt = now()
  elseif cmd == "play" and s.paused then
    if s.mode == "track" then
      s.startedAt = now() - (s.pausedAt - s.startedAt)
    end
    s.paused = false
    s.pausedAt = nil
  elseif cmd == "next" and s.mode == "track" then
    local i = nextIndex(s, true)
    if not i or not playIndex(s, i) then return end
  elseif cmd == "loop" then
    if msg.mode ~= "all" and msg.mode ~= "one" and msg.mode ~= "off" then return end
    s.loop = msg.mode
  elseif cmd == "volume" then
    local v = tonumber(msg.value)
    if not v then return end
    v = math.floor(math.max(0, math.min(1, v)) * 20 + 0.5) / 20
    if v == s.volume then return end
    s.volume = v
  elseif cmd == "prev" and s.mode == "track" then
    if now() - s.startedAt > 3 or s.index <= 1 then
      playIndex(s, math.max(1, s.index))
    else
      playIndex(s, s.index - 1)
    end
  elseif cmd == "seek" and s.mode == "track" then
    local pos = tonumber(msg.pos)
    if not pos or pos < 0 then return end
    s.startedAt = (s.paused and s.pausedAt or now()) - pos
  elseif cmd == "stop" then
    removeRadio(msg.vid)
    return
  elseif cmd == "clear" then
    s.queue = {}
    if s.mode == "track" then
      removeRadio(msg.vid)
      return
    end
  else
    return
  end
  broadcastState(msg.vid)
end)

local function step05(x)
  return math.floor(math.max(0, math.min(1, x)) * 20 + 0.5) / 20
end

-- { vid, open, damage, crash } owner reports the car's condition:
-- open/damage 0..1, crash = strength of a crash that just happened (optional).
radioSync_setCar = ownerHandler(function(pid, msg)
  local s = radios[msg.vid]
  if not s then return end
  local changed = false
  local open, damage, crash = tonumber(msg.open), tonumber(msg.damage), tonumber(msg.crash)
  if open and step05(open) ~= s.open then
    s.open = step05(open)
    changed = true
  end
  if damage and step05(damage) ~= s.damage then
    s.damage = step05(damage)
    changed = true
  end
  if crash and crash > 0 then
    s.crashSeq = s.crashSeq + 1
    s.crashPower = step05(crash)
    changed = true
  end
  if changed then broadcastState(msg.vid) end
end)

-- { vid, seq } owner's player reached the end of the current playlist track.
radioSync_ended = ownerHandler(function(pid, msg)
  local s = radios[msg.vid]
  if s and s.mode == "track" and s.seq == msg.seq and not s.paused then
    advance(msg.vid, s)
  end
end)

-- { file, duration } any player reports the real length of a song (from its audio player).
function radioSync_songDuration(pid, data)
  if rateLimited(pid) then return end
  local msg = decode(data)
  local song = msg and type(msg.file) == "string" and songIndex[msg.file]
  local d = msg and tonumber(msg.duration)
  if not song or not d or confirmedDurations[song.file] then return end
  -- Plausible for 24..400 kbps.
  if d < song.size * 8 / 400000 or d > song.size * 8 / 24000 then return end
  -- The audio player is more reliable than the MP3 header guess.
  durations[song.file] = d
  confirmedDurations[song.file] = true
end

-- Client (re)loaded: send config, stations and every active radio.
function radioSync_requestState(pid, data)
  if rateLimited(pid) then return end
  sendConfig(pid)
  broadcastStations(pid)
  sendSnapshot(pid)
end

-- { file } client wants a song from the music folder; replaces any running transfer.
function radioSync_getSong(pid, data)
  if rateLimited(pid) then return end
  local msg = decode(data)
  local song = msg and type(msg.file) == "string" and songIndex[msg.file]
  if not song then
    MP.TriggerClientEvent(pid, "radioSync_songMissing", tostring(msg and msg.file or ""))
    return
  end
  transfers[pid] = {
    song = song,
    path = musicDir() .. "/" .. song.file,
    index = 0,
    total = math.max(1, math.ceil(song.size / CHUNK_SIZE)),
  }
end

-- Sends the next chunks of every running transfer.
-- Chunk format: "<file>|<index>|<total>|<base64>" (index is 1-based).
function radioSync_transferTick()
  if next(live) then pcall(liveTick, base64) end
  local perTick = math.max(1, math.floor(config.downloadKBps * 1024 / CHUNK_SIZE * TRANSFER_TICK_MS / 1000 + 0.5))
  for pid, t in pairs(transfers) do
    local f = io.open(t.path, "rb")
    if not f then
      transfers[pid] = nil
      MP.TriggerClientEvent(pid, "radioSync_songMissing", t.song.file)
    else
      f:seek("set", t.index * CHUNK_SIZE)
      for _ = 1, perTick do
        local data = f:read(CHUNK_SIZE)
        if not data or #data == 0 then break end
        t.index = t.index + 1
        MP.TriggerClientEvent(pid, "radioSync_chunk",
          t.song.file .. "|" .. t.index .. "|" .. t.total .. "|" .. base64(data))
        if t.index >= t.total then break end
      end
      f:close()
      if t.index >= t.total then transfers[pid] = nil end
    end
  end
end

---------------------------------------------------------------------------
-- Admin chat commands (/radio ...), allowed for names/BeamMP ids in config.admins
---------------------------------------------------------------------------

local function isAdmin(pid)
  local name = tostring(MP.GetPlayerName(pid) or ""):lower()
  local ids = {}
  local ok, idents = pcall(MP.GetPlayerIdentifiers, pid)
  if ok and type(idents) == "table" then
    for _, v in pairs(idents) do ids[tostring(v):lower()] = true end
  end
  for _, a in ipairs(config.admins or {}) do
    local key = tostring(a):lower()
    if key == name or ids[key] then return true end
  end
  return false
end

local function reply(pid, text)
  MP.SendChatMessage(pid, "[RadioSync] " .. text)
end

local ADMIN_HELP = {
  "/radio status – Radios, Sender, Reichweite",
  "/radio off – alle Radios aus",
  "/radio off <Name> – Radios eines Spielers aus",
  "/radio range <Meter> – Reichweite aendern (bis Neustart)",
  "/radio live on|off – Live-Radio an/aus",
  "/radio rescan – Musikordner sofort neu einlesen",
}

local function adminCommand(pid, args)
  local cmd = (args[1] or "help"):lower()
  if cmd == "help" then
    for _, line in ipairs(ADMIN_HELP) do reply(pid, line) end

  elseif cmd == "status" then
    local n, liveRunning = 0, 0
    for _ in pairs(radios) do n = n + 1 end
    for _, st in pairs(live) do if st.proc then liveRunning = liveRunning + 1 end end
    reply(pid, string.format("%d Radios, %d Songs, Reichweite %d m, Live-Radio %s (%d aktiv)",
      n, #songs, config.maxDistance, liveEnabled and "an" or "aus", liveRunning))

  elseif cmd == "off" then
    local who = args[2] and table.concat(args, " ", 2):lower()
    local count = 0
    for vehId in pairs(radios) do
      local owner = tonumber(vehId:match("^(%d+)%-"))
      local ownerName = owner and tostring(MP.GetPlayerName(owner) or ""):lower() or ""
      if not who or ownerName:find(who, 1, true) then
        removeRadio(vehId)
        count = count + 1
      end
    end
    reply(pid, count .. " Radio(s) ausgeschaltet")

  elseif cmd == "range" then
    local m = tonumber(args[2])
    if not m or m < 1 or m > 1000 then
      reply(pid, "Nutzung: /radio range <1-1000>")
      return
    end
    config.maxDistance = math.floor(m)
    sendConfig(-1)
    reply(pid, "Reichweite jetzt " .. config.maxDistance .. " m")

  elseif cmd == "live" then
    local on = (args[2] or ""):lower()
    if on ~= "on" and on ~= "off" then
      reply(pid, "Nutzung: /radio live on|off")
      return
    end
    liveEnabled = on == "on"
    if not liveEnabled then
      for _, st in pairs(live) do stopLive(st) end
      for vehId, s in pairs(radios) do
        if s.mode == "live" then removeRadio(vehId) end
      end
    end
    sendConfig(-1)
    reply(pid, "Live-Radio " .. (liveEnabled and "an" or "aus"))

  elseif cmd == "rescan" then
    scanMusic()
    sendConfig(-1)
    broadcastStations()
    reply(pid, #songs .. " Songs gefunden")

  else
    reply(pid, "Unbekannt. /radio help")
  end
end

function radioSync_onChatMessage(pid, name, message)
  if type(message) ~= "string" then return end
  local text = message:match("^%s*/radio(.*)$")
  if not text or (text ~= "" and not text:match("^%s")) then return end
  if not isAdmin(pid) then
    reply(pid, "Keine Berechtigung")
    return 1
  end
  local args = {}
  for word in text:gmatch("%S+") do table.insert(args, word) end
  local ok, err = pcall(adminCommand, pid, args)
  if not ok then reply(pid, "Fehler: " .. tostring(err)) end
  return 1
end

---------------------------------------------------------------------------
-- BeamMP events
---------------------------------------------------------------------------

function radioSync_onVehicleDeleted(pid, vid)
  removeRadio(pid .. "-" .. vid)
end

function radioSync_onPlayerDisconnect(pid)
  local prefix = pid .. "-"
  for vehId in pairs(radios) do
    if vehId:sub(1, #prefix) == prefix then removeRadio(vehId) end
  end
  rate[pid] = nil
  transfers[pid] = nil
  liveSubs[pid] = nil
end

-- Advances stations and playlists, picks up new/removed songs in the music folder.
function radioSync_tick()
  if liveTest then pcall(checkLiveRadioTest) end

  rescanCounter = rescanCounter + 1
  if rescanCounter >= MUSIC_RESCAN_SECONDS then
    rescanCounter = 0
    if scanMusic() then
      sendConfig(-1)
      broadcastStations()
    end
  end

  local t = now()
  local changed = false
  for _, st in pairs(stations) do
    local song = songIndex[st.file]
    if not song or t - st.startedAt > songDuration(song) + 1 then
      stationNext(st)
      changed = true
    end
  end
  if changed then broadcastStations() end

  -- Fallback auto-advance in case the owner's client never reports "ended".
  for vehId, s in pairs(radios) do
    local song = s.mode == "track" and s.url and songIndex[s.url:sub(7)]
    if song and not s.paused and durations[song.file] and t - s.startedAt > durations[song.file] + 5 then
      advance(vehId, s)
    end
  end
end

math.randomseed(os.time())
if not RADIOSYNC_OFFLINE then loadConfig() end
scanMusic()
setupLive()
if config.liveRadioTest and not RADIOSYNC_OFFLINE then pcall(startLiveRadioTest) end

MP.RegisterEvent("onVehicleDeleted", "radioSync_onVehicleDeleted")
MP.RegisterEvent("onPlayerDisconnect", "radioSync_onPlayerDisconnect")
MP.RegisterEvent("onChatMessage", "radioSync_onChatMessage")

MP.RegisterEvent("radioSync_requestState", "radioSync_requestState")
MP.RegisterEvent("radioSync_setStation", "radioSync_setStation")
MP.RegisterEvent("radioSync_setLive", "radioSync_setLive")
MP.RegisterEvent("radioSync_liveSub", "radioSync_liveSub")
MP.RegisterEvent("radioSync_addSongs", "radioSync_addSongs")
MP.RegisterEvent("radioSync_removeTrack", "radioSync_removeTrack")
MP.RegisterEvent("radioSync_playIndex", "radioSync_playIndex")
MP.RegisterEvent("radioSync_control", "radioSync_control")
MP.RegisterEvent("radioSync_ended", "radioSync_ended")
MP.RegisterEvent("radioSync_setCar", "radioSync_setCar")
MP.RegisterEvent("radioSync_songDuration", "radioSync_songDuration")
MP.RegisterEvent("radioSync_getSong", "radioSync_getSong")

MP.RegisterEvent("radioSync_tick", "radioSync_tick")
MP.CreateEventTimer("radioSync_tick", 1000)
MP.RegisterEvent("radioSync_transferTick", "radioSync_transferTick")
MP.CreateEventTimer("radioSync_transferTick", TRANSFER_TICK_MS)

log("Loaded")
