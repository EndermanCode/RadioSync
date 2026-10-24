# RadioSync – synchronisiertes Autoradio für BeamMP

Jedes Auto hat ein Radio. Der Besitzer stellt einen Sender ein oder baut eine Playlist.
Alle Spieler in der Nähe hören die Musik synchron mit – leiser und dumpfer, je weiter sie weg sind.

## Features
- **Eigene Radiosender** aus dem `music`-Ordner auf dem Server: jeder Unterordner = ein Sender,
  plus „Mix (alle Songs)“. Sender laufen durchgehend (gemischt) – wie echtes Radio, für alle gleich.
- **Playlist** pro Auto aus den Server-Songs, synchron für alle (±1 s), Loop: alles / Song / aus
- Songs einfach hochladen – Clients laden sie automatisch über die BeamMP-Verbindung und cachen sie
- Lautstärke nach Abstand (Kamera ↔ Auto), max. 3 Radios gleichzeitig hörbar
- Realistischer Klang („Echt“): im Auto wie aus den Boxen, von außen gedämpft + Stereo-Richtung
- Nur der Besitzer steuert sein Radio (vom Server geprüft); jeder hat eigene Lautstärke + Stumm
- Besitzer-Lautstärke „für alle“: lauter = für alle lauter und weiter hörbar
- Später joinende Spieler steigen an der richtigen Stelle ein

## Bauen
```powershell
.\build.ps1
```
Erzeugt in `release/`: `RadioSync.zip` (Client), `RadioSync-Server.zip`
und `RadioSync-BeamMP-Resources.zip` (alles zusammen).

## Installation (Server)
```
Resources/
  Client/RadioSync.zip
  Server/RadioSync/main.lua
  Server/RadioSync/config.json
  Server/RadioSync/music/          Songs + Unterordner = Sender
```
Server neu starten. Im Log erscheint `[RadioSync] Loaded` und `Music folder: X songs, Y stations`.

## Songs & Sender
```
music/
  Rock/      song1.mp3, song2.mp3   → Sender „Rock“
  Chill/     ...                    → Sender „Chill“
  lied.mp3                          → nur im Mix + Musik-Tab
```
- MP3/OGG/M4A/WAV/FLAC hochladen. Dateiname = Titel (`_` wird zu Leerzeichen). Kein Neustart nötig,
  der Server prüft den Ordner alle 30 s.
- Clients laden fehlende Songs im Hintergrund (Fortschritt im Tab „Musik“), gerade gespielte zuerst.
  Gespeichert im BeamNG-Userordner unter `ui/modules/apps/RadioSync/music/`.
- Tempo pro Spieler: `downloadKBps` (Standard 512 KB/s → 5-MB-Song ≈ 10 s).
- Braucht BeamMP-Server ≥ 3.1 (`FS.ListFiles`/`FS.ListDirectories`).

## Benutzung (Spieler)
1. Esc → **UI Apps** → App **„Radio Sync“** hinzufügen. Die Musik läuft in dieser App.
2. Ins eigene Auto setzen:
   - Tab **Sender**: Sender anklicken
   - Tab **Musik**: Songs zur Playlist hinzufügen
   - Tab **Playlist**: Reihenfolge, springen, entfernen
3. Andere Spieler in der Nähe hören automatisch mit.

## Konfiguration (`config.json`)
| Feld | Bedeutung |
|------|-----------|
| `maxDistance` | Meter, ab denen ein Radio nicht mehr hörbar ist |
| `maxQueueLength` | Max. Einträge pro Playlist |
| `rateLimitPerSecond` | Max. Radio-Befehle pro Spieler und Sekunde |
| `downloadKBps` | Song-Download-Tempo pro Spieler (KB/s) |
| `liveRadioTest` | Beim Start prüfen, ob der Host Live-Radio weiterleiten könnte (Ergebnis im Log) |
| `liveStations` | Internetsender, vom Server weitergeleitet: `id`, `title`, `url` |
| `admins` | Spielernamen oder BeamMP-IDs, die `/radio`-Befehle nutzen dürfen |

## Admin-Befehle (Chat)
| Befehl | Wirkung |
|---|---|
| `/radio status` | Anzahl Radios/Songs, Reichweite, Live-Radio-Status |
| `/radio off` | alle Radios aus |
| `/radio off <Name>` | Radios eines Spielers aus (Teil des Namens reicht) |
| `/radio range <Meter>` | Reichweite live ändern (bis Neustart) |
| `/radio live on\|off` | Live-Radio für alle an/aus |
| `/radio rescan` | Musikordner sofort neu einlesen |

Befehle erscheinen nicht im Chat der anderen.

## Song-Infos
- Server liest ID3-Tags (Interpret, Titel) → Anzeige „Interpret – Titel“ statt Dateiname.
- App zeigt das Cover aus der MP3 (eingebettetes Bild).
- Live-Radio: aktueller Titel aus dem Stream (ICY-Metadaten), falls der Sender ihn schickt.

## Live-Radio (Internetsender)
BeamNG sperrt für Mods jeden Internetzugriff (UI: „Format error“, Lua: „connect restricted“).
Deshalb holt der **Server** die Sender per `curl` und verteilt sie über die BeamMP-Verbindung.
- Nur Linux-Server mit `curl` (Test: `"liveRadioTest": true` → Log `Live-Radio-Test: MOEGLICH`).
- Sender in `config.json` → `liveStations` (`id`, `title`, `url`). Nur MP3-Streams, `http://` oder `https://`.
- Ein Sender wird nur geholt, solange ein Spieler ihn in Hörweite hat (+30 s Nachlauf).
- Upload pro zuhörendem Spieler ≈ Bitrate des Senders (128 kbit/s ≈ 16 KB/s).
- Alle 30 min startet `curl` neu → ca. 1 s Lücke. Temporäre Dateien `live_*.mp3` im Plugin-Ordner.

## Aufbau
```
Server/RadioSync/main.lua                 Fahrzeug-Radios, Sender, Song-Übertragung
Client/lua/ge/extensions/radioSync.lua    BeamMP-Events ↔ UI, Song-Cache, Abstand → Lautstärke
Client/scripts/radioSync/modScript.lua    lädt die Extension
Client/ui/modules/apps/RadioSync/         UI-App: Wiedergabe, Effekte, Bedienung
```
