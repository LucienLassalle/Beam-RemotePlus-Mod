-- Registry of connected phones. Each phone owns one virtual input device
-- (3 analog axes + 2 buttons), which is what makes local multiplayer work:
-- BeamNG's multiseat assigns every input device to its own player.
--
-- Dependencies are injected (input = core_input_virtualInput, clock = ms) so
-- the whole connection lifecycle is unit-testable.

local protocol = require('/lua/ge/extensions/beamRemotePlus/protocol')

local M = {}

M.DEVICE_NAME = 'BeamRemotePlus'
M.VIDPID = 'bngremoteplusv1' -- must match settings/inputmaps/<vidpid>.json
M.AXES = 3
M.BUTTONS = 2

M.AXIS_STEERING = 0
M.AXIS_THROTTLE = 1
M.AXIS_BRAKE = 2
M.BUTTON_SHIFT_UP = 0
M.BUTTON_SHIFT_DOWN = 1

function M.new(input, clock)
  local self = {}
  local clients = {}

  function self.get(ip) return clients[ip] end

  function self.count()
    local n = 0
    for _ in pairs(clients) do n = n + 1 end
    return n
  end

  -- Iterates over a snapshot so callbacks may disconnect clients safely.
  function self.each(fn)
    local snapshot = {}
    for ip, client in pairs(clients) do snapshot[#snapshot + 1] = { ip, client } end
    for _, entry in ipairs(snapshot) do fn(entry[1], entry[2]) end
  end

  -- Returns client, isNew, errorReason.
  function self.connect(ip, ping)
    local client = clients[ip]
    -- Same phone switching between controller and second-screen roles:
    -- start a fresh session with the new role.
    if client and (client.display == true) ~= (ping.role == protocol.ROLE_DISPLAY) then
      self.disconnect(ip)
      client = nil
    end
    if client then
      client.lastSeen = clock()
      return client, false
    end
    -- A second-screen phone only reads telemetry: no virtual device (it would
    -- compete with the player's real wheel), it follows player 0.
    if ping.role == protocol.ROLE_DISPLAY then
      client = {
        ip = ip, deviceName = ping.deviceName or ip, version = protocol.negotiateVersion(ping.version),
        display = true, state = { 0.5, 0, 0 }, holds = {}, player = 0, debug = false, lastSeen = clock(),
      }
      clients[ip] = client
      return client, true
    end
    if not input then return nil, false, 'virtual_input_unavailable' end
    -- The product name is what Options > Controls displays: with the phone
    -- name, each player recognises their own phone in local multiplayer.
    local productName = ping.deviceName and (M.DEVICE_NAME .. ' (' .. ping.deviceName .. ')') or M.DEVICE_NAME
    local deviceInst = input.createDevice(productName, M.VIDPID, M.AXES, M.BUTTONS, 0)
    if not deviceInst or deviceInst < 0 then return nil, false, 'device_creation_failed' end
    client = {
      ip = ip,
      deviceInst = deviceInst,
      deviceName = ping.deviceName or ip,
      version = protocol.negotiateVersion(ping.version),
      state = { 0.5, 0, 0 },
      holds = {},       -- active "hold" commands (horn...) to release on disconnect
      player = nil,     -- assigned by BeamNG (see assignPlayers)
      debug = false,    -- per-client debug acks
      forceEmit = true, -- first control packet always emits every axis
      lastSeen = clock(),
    }
    clients[ip] = client
    return client, true
  end

  function self.touch(ip)
    local client = clients[ip]
    if client then client.lastSeen = clock() end
    return client
  end

  -- onRelease(client, holdName) is called for every still-active hold so a
  -- phone that drops while honking does not leave the horn stuck on.
  function self.disconnect(ip, onRelease)
    local client = clients[ip]
    if not client then return nil end
    for name in pairs(client.holds) do
      if onRelease then pcall(onRelease, client, name) end
    end
    client.holds = {}
    if input and client.deviceInst then pcall(input.deleteDevice, client.deviceInst) end
    clients[ip] = nil
    return client
  end

  function self.disconnectAll(onRelease)
    self.each(function(ip) self.disconnect(ip, onRelease) end)
  end

  -- Returns the list of clients removed because they stopped sending.
  function self.expire(now, timeoutMs, onRelease)
    local expired = {}
    self.each(function(ip, client)
      if protocol.isClientTimedOut(now, client.lastSeen, timeoutMs) then
        expired[#expired + 1] = self.disconnect(ip, onRelease)
      end
    end)
    return expired
  end

  -- players: { ['vinput<N>'] = playerIndex } from onInputBindingsChanged.
  function self.assignPlayers(players)
    local changed = {}
    for device, player in pairs(players or {}) do
      for _, client in pairs(clients) do
        if client.deviceInst and 'vinput' .. client.deviceInst == device and client.player ~= player then
          client.player = player
          changed[#changed + 1] = client
        end
      end
    end
    return changed
  end

  -- Emits only the axes that changed (or all of them when forceEmit is set,
  -- needed after a vehicle switch so BeamNG gives this device priority).
  function self.applyControl(client, steering, throttle, brake)
    local values = { protocol.clampUnit(steering), protocol.clampUnit(throttle), protocol.clampUnit(brake) }
    local force = client.forceEmit
    client.forceEmit = false
    for axis = 0, 2 do
      local v = values[axis + 1]
      if force or client.state[axis + 1] ~= v then
        input.emit(client.deviceInst, 'axis', axis, 'change', v)
      end
    end
    client.state = values
    client.lastSeen = clock()
  end

  function self.pulseButton(client, button)
    input.emit(client.deviceInst, 'button', button, 'change', 1)
    input.emit(client.deviceInst, 'button', button, 'change', 0)
  end

  return self
end

return M
