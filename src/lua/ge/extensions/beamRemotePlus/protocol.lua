-- Logique pure du protocole Beam-RemotePlus, sans aucune dépendance aux
-- globales spécifiques à BeamNG (extensions, log, socket...), pour rester
-- testable avec un luajit autonome (voir Beam-RemotePlus-Mod/test/).

local ffi = require('ffi')

-- ffi.cdef enregistre les types dans un espace de noms C GLOBAL au
-- processus (pas par état Lua) : si ce module est rechargé (désactivation
-- puis réactivation du mod dans le gestionnaire), un second appel avec les
-- mêmes noms de types lève une erreur. On l'ignore : elle signifie juste
-- que les types sont déjà enregistrés depuis un chargement précédent.
pcall(function()
  ffi.cdef[[
  typedef struct { float steering, throttle, brake; } rp_control_t;
  typedef struct { float speed, rpm, redlineRpm, gear, fuel, engineTemp, lights, shiftLight; } rp_telemetry_t;
  ]]
end)

local M = {}

M.HOST_PORT = 4446   -- le mod écoute ici (ping + contrôle + commandes), côté PC
M.CLIENT_PORT = 4447 -- l'app mobile écoute ici (pong + télémétrie)
M.PING_PREFIX = 'beamngremoteplus|ping|'
M.PONG_PREFIX = 'beamngremoteplus|pong|'
M.PROTOCOL_VERSION = '1'
M.CLIENT_TIMEOUT_MS = 10000
M.TELEMETRY_INTERVAL_MS = 33 -- ~30Hz
M.HEARTBEAT_INTERVAL_MS = 5000

-- Commandes textuelles envoyées par l'app (préfixe 'cmd|').
-- Distinguables des paquets de contrôle binaires (12 octets exactement).
M.CMD_PREFIX       = 'cmd|'
M.CMD_NEXT_VEHICLE = 'cmd|next_vehicle'
M.CMD_PREV_VEHICLE = 'cmd|prev_vehicle'

function M.isPingMessage(data)
  return data ~= nil and data:sub(1, #M.PING_PREFIX) == M.PING_PREFIX
end

function M.isCmdMessage(data)
  return data ~= nil and data:sub(1, #M.CMD_PREFIX) == M.CMD_PREFIX
end

function M.buildPingMessage(code)
  return M.PING_PREFIX .. tostring(code)
end

function M.pingMatchesCode(data, code)
  if code == nil then return false end
  return data == M.buildPingMessage(code)
end

function M.buildPongMessage(code)
  return M.PONG_PREFIX .. tostring(code) .. '|' .. M.PROTOCOL_VERSION
end

function M.isClientTimedOut(now, lastSeen, timeoutMs)
  timeoutMs = timeoutMs or M.CLIENT_TIMEOUT_MS
  return (now - (lastSeen or 0)) > timeoutMs
end

function M.clampUnit(v)
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

function M.gearFromIndex(gearIndex)
  return (gearIndex or -1) + 1
end

-- Bits de la télémétrie : mêmes significations que les DL_x du protocole
-- OutGauge natif (voir lua/vehicle/protocols/outgauge.lua), pour rester
-- cohérent avec l'existant même si le layout binaire diffère.
M.LIGHT_BIT_LOW_BEAM = 1
M.LIGHT_BIT_HIGH_BEAM = 2
M.LIGHT_BIT_HANDBRAKE = 4
M.LIGHT_BIT_SIGNAL_LEFT = 8
M.LIGHT_BIT_SIGNAL_RIGHT = 16
M.LIGHT_BIT_OIL_WARNING = 32
M.LIGHT_BIT_ABS = 64

-- electrics: table simple {lowbeam=, highbeam=, parkingbrake=, signal_L=,
-- signal_R=, oil=, hasABS=, absActive=}, reflétant electrics.values côté
-- véhicule.
function M.computeLightsBitmask(electrics)
  local lights = 0
  if electrics.lowbeam == 1 then lights = lights + M.LIGHT_BIT_LOW_BEAM end
  if electrics.highbeam == 1 then lights = lights + M.LIGHT_BIT_HIGH_BEAM end
  if electrics.parkingbrake and electrics.parkingbrake > 0 then
    lights = lights + M.LIGHT_BIT_HANDBRAKE
  end
  if electrics.signal_L and electrics.signal_L ~= 0 then
    lights = lights + M.LIGHT_BIT_SIGNAL_LEFT
  end
  if electrics.signal_R and electrics.signal_R ~= 0 then
    lights = lights + M.LIGHT_BIT_SIGNAL_RIGHT
  end
  if electrics.oil and electrics.oil ~= 0 then
    lights = lights + M.LIGHT_BIT_OIL_WARNING
  end
  if electrics.hasABS and electrics.absActive and electrics.absActive ~= 0 then
    lights = lights + M.LIGHT_BIT_ABS
  end
  return lights
end

-- Construit l'expression Lua (sous forme de texte) à exécuter côté GE via
-- obj:queueGameEngineLua() pour transmettre la télémétrie. L'IP DOIT être
-- sérialisée avec %q (guillemets + échappement) et non %s : une IP comme
-- "192.168.1.151" non quotée serait interprétée par Lua comme un nombre
-- malformé (bug historique corrigé ici, voir test associé).
function M.buildTelemetryCallExpression(
  ip, speed, rpm, redlineRpm, gear, fuel, engineTemp, lights, shiftLight
)
  return string.format(
    'extensions.beamRemotePlus_main.onTelemetry(%q, %s, %s, %s, %s, %s, %s, %s, %s)',
    ip, speed, rpm, redlineRpm, gear, fuel, engineTemp, lights, shiftLight
  )
end

function M.encodeControlPacket(steering, throttle, brake)
  local packet = ffi.new('rp_control_t')
  packet.steering = steering
  packet.throttle = throttle
  packet.brake = brake
  return ffi.string(packet, ffi.sizeof(packet))
end

function M.decodeControlPacket(data)
  if #data ~= 12 then return nil end
  local packet = ffi.new('rp_control_t')
  ffi.copy(packet, data, 12)
  return packet.steering, packet.throttle, packet.brake
end

function M.encodeTelemetryPacket(
  speed, rpm, redlineRpm, gear, fuel, engineTemp, lights, shiftLight
)
  local packet = ffi.new('rp_telemetry_t')
  packet.speed = speed
  packet.rpm = rpm
  packet.redlineRpm = redlineRpm
  packet.gear = gear
  packet.fuel = fuel
  packet.engineTemp = engineTemp
  packet.lights = lights
  packet.shiftLight = shiftLight
  return ffi.string(packet, ffi.sizeof(packet))
end

return M
