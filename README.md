# RadioSync – synchronized car radio for BeamMP

🇬🇧 **English** · 🇩🇪 [Deutsch](README.de.md)

Every car has a radio. The owner tunes in to a station or builds a playlist.
All nearby players hear the music in sync – quieter and more muffled the farther away they are.

## Features
- **Custom radio stations** from the server's `music` folder: every subfolder = one station,
  plus "Mix (all songs)". Stations play continuously (shuffled) – like real radio, the same for everyone.
- **Playlist** per car from the server's songs, in sync for everyone (±1 s), loop: all / song / off
- Just upload songs – clients download them automatically over the BeamMP connection and cache them
- Volume based on distance (camera ↔ car), up to 3 radios audible at once
- Realistic sound ("Echt"): inside the car like from the speakers, muffled from outside + stereo direction
- Only the owner controls their radio (checked by the server); everyone has their own volume + mute
- Owner volume "for everyone": louder = louder for everyone and audible from farther away
- Players joining later start at the right position

## Building
```powershell
.\build.ps1
```
Creates in `release/`: `RadioSync.zip` (client), `RadioSync-Server.zip`
and `RadioSync-BeamMP-Resources.zip` (everything combined).

## Installation (server)
```
Resources/
  Client/RadioSync.zip
  Server/RadioSync/main.lua
  Server/RadioSync/config.json
  Server/RadioSync/music/          songs + subfolders = stations
```
Restart the server. The log shows `[RadioSync] Loaded` and `Music folder: X songs, Y stations`.

## Songs & stations
```
music/
  Rock/      song1.mp3, song2.mp3   → station "Rock"
  Chill/     ...                    → station "Chill"
  track.mp3                         → only in Mix + "Musik" tab
```
- Upload MP3/OGG/M4A/WAV/FLAC. File name = title (`_` becomes a space). No restart needed,
  the server checks the folder every 30 s.
- Clients download missing songs in the background (progress in the "Musik" tab), currently playing ones first.
  Stored in the BeamNG user folder under `ui/modules/apps/RadioSync/music/`.
- Speed per player: `downloadKBps` (default 512 KB/s → 5 MB song ≈ 10 s).
- Requires BeamMP server ≥ 3.1 (`FS.ListFiles`/`FS.ListDirectories`).

## Usage (players)
1. The **"Radio Sync"** app is added automatically (top right) when joining – the music plays inside this app.
   Removed it? Add it back via Esc → **UI Apps**. It is only added once per layout.
2. Get into your own car:
   - **Sender** tab (stations): click a station
   - **Musik** tab (music): add songs to the playlist
   - **Playlist** tab: reorder, skip to, remove
3. Other players nearby automatically hear it too.

> The in-game UI is currently in German.

## Configuration (`config.json`)
| Field | Meaning |
|------|-----------|
| `maxDistance` | Distance in meters beyond which a radio is no longer audible |
| `maxQueueLength` | Max. entries per playlist |
| `rateLimitPerSecond` | Max. radio commands per player per second |
| `downloadKBps` | Song download speed per player (KB/s) |
| `liveRadioTest` | On startup, check whether the host could relay live radio (result in the log) |
| `liveStations` | Internet stations relayed by the server: `id`, `title`, `url` |
| `admins` | Player names or BeamMP IDs allowed to use `/radio` commands |

## Admin commands (chat)
| Command | Effect |
|---|---|
| `/radio status` | Number of radios/songs, range, live radio status |
| `/radio off` | Turn off all radios |
| `/radio off <name>` | Turn off a player's radios (part of the name is enough) |
| `/radio range <meters>` | Change range live (until restart) |
| `/radio live on\|off` | Live radio on/off for everyone |
| `/radio rescan` | Rescan the music folder immediately |

Commands don't show up in other players' chat.

## Song info
- The server reads ID3 tags (artist, title) → shows "Artist – Title" instead of the file name.
- The app shows the cover art from the MP3 (embedded image).
- Live radio: current title from the stream (ICY metadata), if the station sends it.

## Live radio (internet stations)
BeamNG blocks all internet access for mods (UI: "Format error", Lua: "connect restricted").
That's why the **server** fetches the stations via `curl` and distributes them over the BeamMP connection.
- Linux servers with `curl` only (test: `"liveRadioTest": true` → log `Live-Radio-Test: MOEGLICH`).
- Stations in `config.json` → `liveStations` (`id`, `title`, `url`). MP3 streams only, `http://` or `https://`.
- A station is only fetched while a player has it within hearing range (+30 s grace period).
- Upload per listening player ≈ the station's bitrate (128 kbit/s ≈ 16 KB/s).
- `curl` restarts every 30 min → approx. 1 s gap. Temporary files `live_*.mp3` in the plugin folder.

## Structure
```
Server/RadioSync/main.lua                 Vehicle radios, stations, song transfer
Client/lua/ge/extensions/radioSync.lua    BeamMP events ↔ UI, song cache, distance → volume
Client/scripts/radioSync/modScript.lua    Loads the extension
Client/ui/modules/apps/RadioSync/         UI app: playback, effects, controls
```
