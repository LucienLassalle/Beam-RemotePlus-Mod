-- Persistent user settings of the mod, stored as JSON in the BeamNG user
-- folder (settings/beamRemotePlus.json) so they survive game restarts and
-- mod updates.
--
-- File access is injected (readJson/writeJson) to keep this module testable;
-- in game they are BeamNG's jsonReadFile/jsonWriteFile.

local M = {}

M.FILE_PATH = '/settings/beamRemotePlus.json'

-- enabled: phones are allowed to connect. ON by default: installing the mod
-- is the user's opt-in, a second switch to find would only be friction.
-- debug: verbose logs + positive command acks sent to the app.
M.DEFAULTS = {
  enabled = true,
  debug = false,
  showPairingToast = true,
}

local function copyDefaults()
  local values = {}
  for k, v in pairs(M.DEFAULTS) do values[k] = v end
  return values
end

-- Unknown keys and wrongly typed values are ignored so a hand-edited or
-- corrupted file can never break the mod.
function M.sanitize(raw)
  local values = copyDefaults()
  if type(raw) ~= 'table' then return values end
  for k, default in pairs(M.DEFAULTS) do
    if type(raw[k]) == type(default) then values[k] = raw[k] end
  end
  return values
end

function M.new(io)
  local self = { values = copyDefaults() }

  function self.load()
    local ok, raw = pcall(io.readJson, M.FILE_PATH)
    self.values = M.sanitize(ok and raw or nil)
    return self.values
  end

  function self.save()
    return pcall(io.writeJson, M.FILE_PATH, self.values)
  end

  function self.get(key)
    return self.values[key]
  end

  function self.set(key, value)
    if M.DEFAULTS[key] == nil or type(value) ~= type(M.DEFAULTS[key]) then
      return false
    end
    self.values[key] = value
    self.save()
    return true
  end

  return self
end

return M
