-- Developer hot-reload (no effect for players).
--
-- scripts/deploy_local.sh copies a fresh zip into the user mods folder and
-- creates RELOAD_TRIGGER. When the trigger shows up, the zip is remounted
-- (BeamNG caches a zip's central directory, so a replaced file is not seen
-- otherwise) and the extension reloads itself. The trigger never exists on a
-- player's machine, so the check is a cheap no-op there.

local M = {}

M.MOD_ZIP_PATH = '/mods/repo/Beam-RemotePlus.zip'
M.RELOAD_TRIGGER = '/mods/repo/Beam-RemotePlus-reload.trigger'
M.CHECK_EVERY_TICKS = 180 -- ~3 s at 60 fps

local ticks = 0

-- Returns true when a reload was started (the caller must stop this frame).
function M.check()
  ticks = ticks + 1
  if ticks % M.CHECK_EVERY_TICKS ~= 0 then return false end
  if not (FS and FS:fileExists(M.RELOAD_TRIGGER)) then return false end
  log('I', 'beamRemotePlus', 'dev reload trigger found, remounting the mod zip')
  FS:removeFile(M.RELOAD_TRIGGER) -- removed first to avoid a reload loop
  if FS:isMounted(M.MOD_ZIP_PATH) then
    FS:unmount(M.MOD_ZIP_PATH)
    FS:mountList({ { srcPath = M.MOD_ZIP_PATH, mountPath = nil } })
  end
  extensions.reload('beamRemotePlus_main')
  return true
end

return M
