-- The game's own remote control (core_remoteController, UDP 4444). It
-- accepts the mod's pairing code, so while new phones are locked out it must
-- not pair them either.
--
-- Its socket cannot be closed from a mod: it is a local of
-- remoteController.lua and the game's Lua sandbox forbids debug.setupvalue.
-- Instead, the mod refuses the virtual input device it asks for when a
-- phone pairs: without a device the game sends no answer, so the phone
-- cannot pair. Phones already paired keep their device.
--
-- getRc(), getInput(): core_remoteController and core_input_virtualInput
-- (looked up on each call, they may load after the mod); debugLib: Lua's
-- debug library (debug.getupvalue is allowed by the sandbox).

local M = {}

-- vidpid of the devices created by remoteController.lua.
M.NATIVE_VIDPID = 'bngremotectrlv1'

-- Returns the index and value of the upvalue `name` of `fn`, or nil.
function M.findUpvalue(debugLib, fn, name)
  if type(fn) ~= 'function' then return nil end
  local i = 1
  while true do
    local upName, value = debugLib.getupvalue(fn, i)
    if upName == nil then return nil end
    if upName == name then return i, value end
    i = i + 1
  end
end

function M.new(getRc, getInput, debugLib)
  local self = {}
  local locked = false
  local wrapped = nil  -- the input module our guard is installed on
  local original = nil -- its createDevice before the guard
  local guard = nil

  local function rcModule()
    local rc = getRc()
    return type(rc) == 'table' and rc or nil
  end

  -- The pairing code, read without opening the port. Falls back to
  -- getQRCode() (which opens it) only when the code cannot be read.
  function self.getCode()
    local rc = rcModule()
    if not rc then return nil end
    if debugLib then
      local ok, _, code = pcall(M.findUpvalue, debugLib, rc.getQRCode, 'code')
      if ok and code then return tostring(code) end
    end
    if type(rc.getQRCode) ~= 'function' then return nil end
    local code = rc.getQRCode()
    return code and tostring(code) or nil
  end

  -- Opens the port (apps pair through it first); a no-op once open.
  function self.open()
    local rc = rcModule()
    if not (rc and type(rc.getQRCode) == 'function') then return false end
    return rc.getQRCode() ~= false
  end

  -- Installs the guard on core_input_virtualInput.createDevice, again if the
  -- game reloaded that module. Returns false when it cannot be installed.
  local function ensureGuard()
    local input = getInput()
    if type(input) ~= 'table' or type(input.createDevice) ~= 'function' then return false end
    if wrapped == input and input.createDevice == guard then return true end
    original = input.createDevice
    guard = function(name, vidpid, ...)
      if locked and vidpid == M.NATIVE_VIDPID then return -1 end
      return original(name, vidpid, ...)
    end
    input.createDevice = guard
    wrapped = input
    return true
  end

  -- Locked: the game's remote control cannot pair new phones. Returns true
  -- when that is enforced (always true when unlocking).
  function self.setLocked(value)
    locked = value and true or false
    local ok = ensureGuard()
    return ok or not locked
  end

  function self.isLocked() return locked end

  -- Puts the game's createDevice back (mod unloaded).
  function self.restore()
    locked = false
    if wrapped and wrapped.createDevice == guard then wrapped.createDevice = original end
    wrapped, original, guard = nil, nil, nil
  end

  return self
end

return M
