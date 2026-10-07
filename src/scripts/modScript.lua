-- Run by the mod manager when the mod is mounted (game startup or activation).
--
-- Official pattern (see lua/ge/main.lua): flag the extension as "manual" so
-- the mod manager loads it right after this script and it survives level
-- changes. If it is already running (mod updated while the game runs), it is
-- reloaded so the new code is used instead of the in-memory one.
local extName = 'beamRemotePlus_main'
setExtensionUnloadMode(extName, 'manual')
if extensions.isExtensionLoaded and extensions.isExtensionLoaded(extName) then
  extensions.reload(extName)
end
