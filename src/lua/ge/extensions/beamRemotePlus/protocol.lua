-- Pure Beam-RemotePlus wire protocol: no dependency on BeamNG globals, so it
-- can be unit-tested with a standalone luajit (see test/).
--
-- Wire summary (all UDP, see docs/PROTOCOL.md for the full specification):
--   app -> mod (HOST_PORT)  : discover probe, ping, 12-byte control packet,
--                             text commands ("cmd|<name>[|<arg>]")
--   mod -> app (CLIENT_PORT): hello, pong, telemetry, command acks
--
-- Protocol versions:
--   1: binary 36-byte telemetry, no command acks (apps <= 1.x)
--   2: JSON telemetry + JSON events (acks, session info)

local ffi = require('ffi')
local json = require('/lua/ge/extensions/beamRemotePlus/json')

-- ffi.cdef registers types in a process-wide C namespace (not per Lua
-- state): reloading this module would raise a redefinition error, which we
-- swallow. RULE: any layout change of a struct below MUST come with a new
-- type name (e.g. _v2 -> _v3), otherwise the stale layout silently stays
-- active after a reload.
pcall(function()
  ffi.cdef[[
  typedef struct { float steering, throttle, brake; } rp_control_t;
  typedef struct { float speed, rpm, redlineRpm, gear, fuel, engineTemp, lights, shiftLight, oilTemp; } rp_telemetry_v2_t;
  ]]
end)

local M = {}

M.HOST_PORT = 4446
M.CLIENT_PORT = 4447

M.PROTOCOL_VERSION = 2
M.LEGACY_PROTOCOL_VERSION = 1

M.PING_PREFIX = 'beamngremoteplus|ping|'
M.PONG_PREFIX = 'beamngremoteplus|pong|'
M.DISCOVER_MESSAGE = 'beamngremoteplus|discover'
M.HELLO_PREFIX = 'beamngremoteplus|hello|'
M.CMD_PREFIX = 'cmd|'

M.CONTROL_PACKET_SIZE = 12
M.MAX_DATAGRAM_SIZE = 512

M.CLIENT_TIMEOUT_MS = 10000
M.TELEMETRY_INTERVAL_MS = 33 -- ~30 Hz
M.HEARTBEAT_INTERVAL_MS = 5000

local function startsWith(s, prefix)
  return type(s) == 'string' and s:sub(1, #prefix) == prefix
end

-- Splits on '|' keeping empty fields ("a||b" -> {"a", "", "b"}).
function M.splitFields(s)
  local fields = {}
  for field in (s .. '|'):gmatch('([^|]*)|') do
    fields[#fields + 1] = field
  end
  return fields
end

-- Handshake ---------------------------------------------------------------

function M.isDiscoverMessage(data)
  return data == M.DISCOVER_MESSAGE
end

function M.isPingMessage(data)
  return startsWith(data, M.PING_PREFIX)
end

function M.isCmdMessage(data)
  return startsWith(data, M.CMD_PREFIX)
end

function M.buildPingMessage(code, version, deviceName, role)
  local msg = M.PING_PREFIX .. tostring(code)
  if version then
    msg = msg .. '|' .. tostring(version)
    if deviceName then
      msg = msg .. '|' .. tostring(deviceName):gsub('|', ' ')
      if role then msg = msg .. '|' .. role end
    end
  end
  return msg
end

M.ROLE_CONTROLLER = 'controller'
M.ROLE_DISPLAY = 'display' -- second screen: telemetry only, no inputs

-- Returns { code, version, deviceName, role } or nil. Apps speaking
-- protocol 1 only send the code, so a missing version means 1.
-- ping: beamngremoteplus|ping|<code>[|<version>[|<device>[|<role>]]]
function M.parsePing(data)
  if not M.isPingMessage(data) then return nil end
  local fields = M.splitFields(data:sub(#M.PING_PREFIX + 1))
  local code = fields[1]
  if not code or code == '' then return nil end
  local version = tonumber(fields[2]) or M.LEGACY_PROTOCOL_VERSION
  local deviceName = fields[3]
  if deviceName == '' then deviceName = nil end
  local role = fields[4] == M.ROLE_DISPLAY and M.ROLE_DISPLAY or M.ROLE_CONTROLLER
  return { code = code, version = version, deviceName = deviceName, role = role }
end

function M.pingMatchesCode(data, code)
  if code == nil then return false end
  local ping = M.parsePing(data)
  return ping ~= nil and ping.code == tostring(code)
end

-- The negotiated version is the lowest common one, so a newer app keeps
-- working with an older mod and vice versa.
function M.negotiateVersion(clientVersion)
  return math.min(tonumber(clientVersion) or M.LEGACY_PROTOCOL_VERSION, M.PROTOCOL_VERSION)
end

function M.buildPongMessage(code, version)
  return M.PONG_PREFIX .. tostring(code) .. '|' .. tostring(version or M.PROTOCOL_VERSION)
end

-- label: human readable PC name shown by the app when several PCs answer.
function M.buildHelloMessage(code, label)
  label = tostring(label or 'BeamNG.drive'):gsub('|', ' ')
  return M.HELLO_PREFIX .. tostring(code) .. '|' .. label
end

-- Commands ----------------------------------------------------------------

-- "cmd|horn|1" -> "horn", "1" ; "cmd|next_vehicle" -> "next_vehicle", nil
function M.parseCommand(data)
  if not M.isCmdMessage(data) then return nil end
  local fields = M.splitFields(data:sub(#M.CMD_PREFIX + 1))
  local name = fields[1]
  if not name or name == '' then return nil end
  local arg = fields[2]
  if arg == '' then arg = nil end
  return name, arg
end

function M.buildCommand(name, arg)
  if arg == nil then return M.CMD_PREFIX .. name end
  return M.CMD_PREFIX .. name .. '|' .. tostring(arg)
end

-- Control packet ----------------------------------------------------------

function M.clampUnit(v)
  v = tonumber(v) or 0
  if v ~= v then return 0 end -- NaN
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

function M.encodeControlPacket(steering, throttle, brake)
  local packet = ffi.new('rp_control_t')
  packet.steering = steering
  packet.throttle = throttle
  packet.brake = brake
  return ffi.string(packet, ffi.sizeof(packet))
end

function M.decodeControlPacket(data)
  if type(data) ~= 'string' or #data ~= M.CONTROL_PACKET_SIZE then return nil end
  local packet = ffi.new('rp_control_t')
  ffi.copy(packet, data, M.CONTROL_PACKET_SIZE)
  return packet.steering, packet.throttle, packet.brake
end

-- Legacy (v1) binary telemetry ----------------------------------------------

M.LIGHT_BIT_LOW_BEAM = 1
M.LIGHT_BIT_HIGH_BEAM = 2
M.LIGHT_BIT_HANDBRAKE = 4
M.LIGHT_BIT_SIGNAL_LEFT = 8
M.LIGHT_BIT_SIGNAL_RIGHT = 16
M.LIGHT_BIT_OIL_WARNING = 32
M.LIGHT_BIT_ABS = 64
M.LIGHT_BIT_TC = 128

local function num(v)
  v = tonumber(v)
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return 0 end
  return v
end

-- Native gear convention: 0 = R, 1 = N, 2+ = engaged gear + 1.
function M.gearFromIndex(gearIndex)
  return (tonumber(gearIndex) or -1) + 1
end

-- t: normalized telemetry table (see telemetry.lua / vehicle extension).
function M.computeLightsBitmask(t)
  local lights = 0
  if t.lowBeam then lights = lights + M.LIGHT_BIT_LOW_BEAM end
  if t.highBeam then lights = lights + M.LIGHT_BIT_HIGH_BEAM end
  if t.parkingBrake then lights = lights + M.LIGHT_BIT_HANDBRAKE end
  if t.signalLeft then lights = lights + M.LIGHT_BIT_SIGNAL_LEFT end
  if t.signalRight then lights = lights + M.LIGHT_BIT_SIGNAL_RIGHT end
  if t.lowPressure then lights = lights + M.LIGHT_BIT_OIL_WARNING end
  if t.absActive then lights = lights + M.LIGHT_BIT_ABS end
  if t.tcsActive then lights = lights + M.LIGHT_BIT_TC end
  return lights
end

function M.encodeLegacyTelemetry(t)
  local packet = ffi.new('rp_telemetry_v2_t')
  packet.speed = num(t.speed)
  packet.rpm = num(t.rpm)
  packet.redlineRpm = num(t.maxRpm)
  packet.gear = M.gearFromIndex(t.gearIndex)
  packet.fuel = num(t.fuel)
  packet.engineTemp = num(t.waterTemp)
  packet.lights = M.computeLightsBitmask(t)
  packet.shiftLight = t.shiftLight and 1 or 0
  packet.oilTemp = num(t.oilTemp)
  return ffi.string(packet, ffi.sizeof(packet))
end

-- v2 JSON messages ------------------------------------------------------------

-- Every v2 message is a JSON object with a "type" field so the app can route
-- it; unknown types must be ignored by the app (forward compatibility).
function M.buildTelemetryMessage(t)
  local msg = { type = 'telemetry' }
  for k, v in pairs(t) do msg[k] = v end
  return json.encode(msg)
end

-- Segments per skeleton datagram: ~3 KB, well under the IP fragment count
-- a Wi-Fi link loses often.
M.SKELETON_SEGMENTS_PER_MESSAGE = 150

-- Splits a vehicle skeleton ({ id, segments = { x1, y1, x2, y2, ... },
-- wheels, engine }, see the vehicle extension skeleton.lua) into
-- datagrams. Each one stands alone (offset + total count), so the app
-- assembles them in any order and asks again for what was lost.
function M.buildSkeletonMessages(s, perMessage)
  if type(s) ~= 'table' or type(s.id) ~= 'string' or type(s.segments) ~= 'table' then return {} end
  perMessage = perMessage or M.SKELETON_SEGMENTS_PER_MESSAGE
  local count = math.floor(#s.segments / 4)
  local messages = {}
  for offset = 0, count - 1, perMessage do
    local seg = {}
    for i = offset * 4 + 1, math.min(offset + perMessage, count) * 4 do seg[#seg + 1] = s.segments[i] end
    messages[#messages + 1] = json.encode({
      type = 'skeleton', id = s.id, offset = offset, count = count, seg = seg,
      wheels = s.wheels, engine = s.engine,
    })
  end
  return messages
end

-- error: short machine-readable reason (e.g. "no_vehicle"), shown verbatim
-- by the app's debug overlay.
function M.buildAckMessage(command, ok, error)
  return json.encode({ type = 'ack', cmd = command, ok = ok and true or false, error = error })
end

function M.buildSessionMessage(info)
  local msg = { type = 'session' }
  for k, v in pairs(info) do msg[k] = v end
  return json.encode(msg)
end

-- Timeouts ------------------------------------------------------------------

function M.isClientTimedOut(now, lastSeen, timeoutMs)
  timeoutMs = timeoutMs or M.CLIENT_TIMEOUT_MS
  return (now - (lastSeen or 0)) > timeoutMs
end

return M
