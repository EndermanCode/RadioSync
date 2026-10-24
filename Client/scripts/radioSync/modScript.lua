-- Runs whenever the mod is activated. If radioSync is already loaded (e.g. joining a server that
-- ships a newer RadioSync.zip without restarting the game), reload it so the new code runs.
-- BeamMP event handlers are keyed by source file, so registering them again replaces the old ones.
if extensions.isExtensionLoaded("radioSync") then
  extensions.reload("radioSync")
else
  load("radioSync")
end
setExtensionUnloadMode("radioSync", "manual")
