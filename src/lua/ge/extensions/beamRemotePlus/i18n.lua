-- In-game text translation.
--
-- Translations live in locales/translations/<lang>/beamRemotePlus.translation.json
-- (merged by BeamNG's core_locales with the game's own files), so translators
-- never have to touch Lua. The English fallbacks below are only used when the
-- translation system is not ready yet (very early during startup).

local M = {}

M.FALLBACK = {
  ['beamRemotePlus.toast.title'] = 'Beam-RemotePlus',
  ['beamRemotePlus.toast.pairingCode'] = 'Pairing code: {code} (or use "Automatic connection" in the app)',
  ['beamRemotePlus.toast.autoPairing'] = 'Automatic pairing with {ip}…',
  ['beamRemotePlus.toast.phoneConnected'] = 'Phone connected: {device} (player {player})',
  ['beamRemotePlus.toast.phoneDisconnected'] = 'Phone disconnected: {device}',
  ['beamRemotePlus.toast.enabled'] = 'Phone connections enabled',
  ['beamRemotePlus.toast.disabled'] = 'Phone connections disabled',
  ['beamRemotePlus.toast.portBusy'] = 'UDP port {port} is already in use: phones cannot connect',
  ['beamRemotePlus.label.host'] = "{name}'s PC",
}

-- Replaces {name} placeholders; unknown placeholders are left untouched so a
-- missing value is visible instead of silently empty.
function M.format(text, values)
  if not values then return text end
  return (text:gsub('{(%w+)}', function(key)
    local v = values[key]
    if v == nil then return '{' .. key .. '}' end
    return tostring(v)
  end))
end

-- translate: BeamNG's _tr (may be false/nil early during startup).
function M.new(translate)
  local self = {}

  function self.t(key, values)
    local text
    if type(translate) == 'function' then
      local ok, result = pcall(translate, key)
      if ok and type(result) == 'string' and result ~= '' and result ~= key then
        text = result
      end
    end
    return M.format(text or M.FALLBACK[key] or key, values)
  end

  return self
end

return M
