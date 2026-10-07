-- GE-side telemetry router.
--
-- Every TELEMETRY_INTERVAL_MS, asks each vehicle followed by at least one
-- phone for a snapshot (collected in the vehicle VM by
-- lua/vehicle/extensions/beamRemotePlus/telemetry.lua), then fans the answer
-- out to every phone following that vehicle. One request per vehicle, not per
-- phone: two phones on the same car (local multiplayer passenger dash) cost
-- nothing extra.

local protocol = require('/lua/ge/extensions/beamRemotePlus/protocol')

local M = {}

M.VEHICLE_REQUEST = "if not extensions.beamRemotePlus_telemetry then extensions.load('beamRemotePlus/telemetry') end "
  .. 'if extensions.beamRemotePlus_telemetry then extensions.beamRemotePlus_telemetry.send() end'

-- Builds the datagram for one client according to its negotiated protocol.
function M.encodeFor(client, t)
  if client.version >= 2 then
    local msg = {}
    for k, v in pairs(t) do msg[k] = v end
    msg.player = client.player
    msg.vehicle = client.vehicleModel
    return protocol.buildTelemetryMessage(msg)
  end
  return protocol.encodeLegacyTelemetry(t)
end

--[[
deps:
  getVehicle(player) -> vehicle object or nil
  send(client, payload)
  clock() -> ms
  intervalMs (optional)
]]
function M.new(deps)
  local self = {}
  local lastRequest = {} -- [vehicleId] = ms
  local interval = deps.intervalMs or protocol.TELEMETRY_INTERVAL_MS

  -- Refreshes which vehicle every client follows and requests snapshots.
  -- Returns the number of requests sent (useful for tests/debug).
  function self.tick(registry)
    local now = deps.clock()
    local requested = 0
    local seen = {}
    registry.each(function(_, client)
      client.vehicleId = nil
      if client.player == nil then return end
      local vehicle = deps.getVehicle(client.player)
      if not vehicle then return end
      local id = vehicle:getID()
      client.vehicleId = id
      client.vehicleModel = vehicle.getJBeamFilename and vehicle:getJBeamFilename() or nil
      if seen[id] then return end
      seen[id] = true
      if now - (lastRequest[id] or 0) >= interval then
        lastRequest[id] = now
        vehicle:queueLuaCommand(M.VEHICLE_REQUEST)
        requested = requested + 1
      end
    end)
    for id in pairs(lastRequest) do
      if not seen[id] then lastRequest[id] = nil end
    end
    return requested
  end

  -- Called (through main.onTelemetry) by the vehicle VM. Returns the number
  -- of clients the snapshot was sent to.
  function self.dispatch(registry, vehicleId, t)
    if type(t) ~= 'table' then return 0 end
    local sent = 0
    registry.each(function(_, client)
      if client.vehicleId == vehicleId then
        deps.send(client, M.encodeFor(client, t))
        sent = sent + 1
      end
    end)
    return sent
  end

  return self
end

return M
