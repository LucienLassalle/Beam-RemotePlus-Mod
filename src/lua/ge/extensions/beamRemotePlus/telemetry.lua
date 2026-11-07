-- GE-side telemetry router.
--
-- Every TELEMETRY_INTERVAL_MS, asks each vehicle followed by at least one
-- phone for a snapshot (collected in the vehicle VM by
-- lua/vehicle/extensions/beamRemotePlus/telemetry.lua), then fans the answer
-- out to every phone following that vehicle. One request per vehicle, not per
-- phone: two phones on the same car (local multiplayer passenger dash) cost
-- nothing extra.

local protocol = require('/lua/ge/extensions/beamRemotePlus/protocol')
local radar = require('/lua/ge/extensions/beamRemotePlus/radar')
local json = require('/lua/ge/extensions/beamRemotePlus/json')

local M = {}

-- Changes on every load of the GE extension: a vehicle running an older
-- copy of the vehicle extension (mod updated while the game runs) reloads
-- it once, otherwise extensions.load() would keep the stale code forever.
M.LOAD_STAMP = tostring(os.time()) .. '-' .. tostring(math.random(1e6))

function M.vehicleRequest(stamp)
  return string.format(
    "local e = extensions.beamRemotePlus_telemetry "
      .. "if not e or e.loadStamp ~= %q then extensions.reload('beamRemotePlus_telemetry') e = extensions.beamRemotePlus_telemetry if e then e.loadStamp = %q end end "
      .. "if e then e.send() end",
    stamp, stamp)
end

M.VEHICLE_REQUEST = M.vehicleRequest(M.LOAD_STAMP)

M.RADAR_INTERVAL_MS = 100

-- Delta frames. A snapshot is mostly what does not change from one frame to
-- the next (the vehicle's limits and equipment, nominal pressures, the
-- radar computed at 10 Hz...), and a busy one does not fit in one Wi-Fi
-- packet: an app announcing protocol.FEATURE_DELTA gets, between full
-- frames, only the fields that changed since the previous frame
-- ("delta": true; a field gone is sent as null). A full frame every
-- FULL_FRAME_MS makes up for a lost one. Other apps keep getting full
-- frames.
M.FULL_FRAME_MS = 1000

-- Paced by the vehicle side and kept by the app until the next one: sent
-- when present, never compared nor cleared.
local UNTRACKED = { skeletonDamage = true }

-- Every field of a snapshot (and its radar) encoded once, for all the
-- phones following that vehicle: { [key] = json text }.
function M.encodeFields(t, targets)
  local fields = {}
  for k, v in pairs(t) do fields[tostring(k)] = json.encode(v) end
  if targets then fields.radar = json.encode(targets) end
  return fields
end

-- JSON object of encoded fields, keys sorted like json.encode does.
local function object(fields)
  local keys = {}
  for k in pairs(fields) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for i, k in ipairs(keys) do parts[i] = json.encode(k) .. ':' .. fields[k] end
  return '{' .. table.concat(parts, ',') .. '}'
end

-- The fields a delta frame carries: what changed since `sent`, null for
-- what is gone.
local function changes(fields, sent)
  local out = { delta = 'true' }
  for k, v in pairs(fields) do
    if UNTRACKED[k] or sent[k] ~= v then out[k] = v end
  end
  for k in pairs(sent) do
    if fields[k] == nil then out[k] = 'null' end
  end
  return out
end

-- Builds the datagram for one client according to its negotiated protocol
-- and features. fields: encodeFields() of the snapshot t; now: ms.
function M.encodeFor(client, t, fields, now)
  if client.version < 2 then return protocol.encodeLegacyTelemetry(t) end
  local mine = { type = json.encode('telemetry') }
  for k, v in pairs(fields) do mine[k] = v end
  if client.player ~= nil then mine.player = json.encode(client.player) end
  if client.vehicleModel ~= nil then mine.vehicle = json.encode(client.vehicleModel) end
  if not (client.features and client.features[protocol.FEATURE_DELTA]) then return object(mine) end

  local sent = client.telemetrySent
  local full = sent == nil or now - client.telemetryFullAt >= M.FULL_FRAME_MS
  local state = {}
  for k, v in pairs(mine) do
    if not UNTRACKED[k] then state[k] = v end
  end
  client.telemetrySent = state
  if full then
    client.telemetryFullAt = now
    return object(mine)
  end
  return object(changes(mine, sent))
end
--[[
deps:
  getVehicle(player) -> vehicle object or nil
  listVehicles() -> radar descriptions of the cars around (optional)
  send(client, payload)
  clock() -> ms
  intervalMs (optional)
]]
function M.new(deps)
  local self = {}
  local lastRequest = {} -- [vehicleId] = ms
  local radarCache = {} -- [vehicleId] = { at = ms, targets = {...} }
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
  -- Radar of a vehicle, recomputed at most every RADAR_INTERVAL_MS.
  local function radarFor(vehicleId)
    if not deps.listVehicles then return nil end
    local now = deps.clock()
    local cached = radarCache[vehicleId]
    if cached and now - cached.at < M.RADAR_INTERVAL_MS then return cached.targets end
    local all = deps.listVehicles()
    local me
    for _, v in ipairs(all) do if v.id == vehicleId then me = v end end
    local targets = me and radar.compute(me, all) or nil
    radarCache[vehicleId] = { at = now, targets = targets }
    return targets
  end

  function self.dispatch(registry, vehicleId, t)
    if type(t) ~= 'table' then return 0 end
    local fields = M.encodeFields(t, radarFor(vehicleId))
    local now = deps.clock()
    local sent = 0
    registry.each(function(_, client)
      if client.vehicleId == vehicleId then
        deps.send(client, M.encodeFor(client, t, fields, now))
        sent = sent + 1
      end
    end)
    return sent
  end

  -- Skeleton geometry of a vehicle (asked by a phone with cmd|skeleton),
  -- split into datagrams for every v2 phone following it. Returns the
  -- number of phones it was sent to.
  function self.dispatchSkeleton(registry, vehicleId, s)
    local messages = protocol.buildSkeletonMessages(s)
    if #messages == 0 then return 0 end
    local sent = 0
    registry.each(function(_, client)
      if client.vehicleId == vehicleId and client.version >= 2 then
        for _, message in ipairs(messages) do deps.send(client, message) end
        sent = sent + 1
      end
    end)
    return sent
  end

  return self
end

return M
