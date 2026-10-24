# RadioSync – TODO / Ideen

## Erledigt
- [x] **Versionsprüfung Client ↔ Server** – `VERSION` in `radioSync.lua` und `main.lua` (build.ps1 bricht ab, wenn sie
  verschieden sind). Die App zeigt „Server-Plugin veraltet“ bzw. „Client veraltet“, der Server warnt im Log.
- [x] **Neuer Code ohne Spiel-Neustart** – `modScript.lua` lädt die Extension neu, wenn die Mod erneut aktiviert wird
  (z.B. Server mit neuerer `RadioSync.zip`). BeamMP-Event-Handler werden dabei ersetzt, nicht verdoppelt.
- [x] **Offline-Modus** (Einzelspieler) – eigene Musik aus dem Song-Cache-Ordner, Server-Plugin läuft lokal.
- [x] **App automatisch hinzufügen** beim Join (oben rechts, einmal pro Layout).

## Offen

### Bedienung
- [ ] **Tastenbelegung** – Weiter/Zurück, Pause, Lautstärke über BeamNG-Input-Actions (Tastatur, Lenkradknöpfe),
  ohne die App öffnen zu müssen.
- [ ] **Hinweis ohne App** – Wer die App entfernt hat, bekommt einen Chat-Hinweis, sobald ein Radio in der Nähe läuft.
  Solche Clients melden sich außerdem nicht für Live-Sender an (spart Server-Upload).

### Funktionen
- [ ] **Beifahrer / Musikwünsche** – Mitfahrer oder Spieler in der Nähe schlagen Songs vor, der Besitzer nimmt sie
  mit einem Klick an.
- [ ] **Weiche Übergänge** – kurzes Überblenden bei Senderwechsel und Song-Ende statt hartem Schnitt.
- [ ] **Playlist merken** – eigene Playlist lokal speichern, nach Rejoin bzw. offline wiederherstellen.
