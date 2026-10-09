-- Drivetrain state for the phone: clutch temperature, broken powertrain
-- parts, shafts and engine position (damage schematic), wheelspin and
-- locked wheels (haptics). Pure: the game objects are passed as arguments.

local M = {}

-- Worst first.
local CLUTCH_SEVERITY = { damaged = 3, overheating = 2, hot = 1 }

local function round(v, decimals)
  v = tonumber(v)
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return nil end
  local m = 10 ^ (decimals or 0)
  return math.floor(v * m + 0.5) / m
end

local function sortedKeys(set)
  local list = {}
  for k in pairs(set) do list[#list + 1] = k end
  table.sort(list)
  return list
end

-- Clutch thermals of frictionClutch / centrifugalClutch devices (same
-- thresholds as the game's "Clutch overheating..." messages).
-- devices: powertrain.getDevices() (name -> device)
-- Returns temperature (°C) and state: nil (fine), 'hot', 'overheating'
-- (slipping, loses torque) or 'damaged' (permanently). With several
-- clutches, the hottest temperature and the worst state.
function M.clutch(devices)
  local temp, state
  for _, d in pairs(devices or {}) do
    local t = type(d) == 'table' and round(d.clutchTemperature, 0)
    if t then
      local s
      if d.clutchPermanentlyDamaged then
        s = 'damaged'
      elseif (tonumber(d.thermalEfficiency) or 1) < 1 then
        s = 'overheating'
      elseif tonumber(d.clutchWarningTemp) and t >= tonumber(d.clutchWarningTemp) then
        s = 'hot'
      end
      if temp == nil or t > temp then temp = t end
      if s and (state == nil or CLUTCH_SEVERITY[s] > CLUTCH_SEVERITY[state]) then state = s end
    end
  end
  return temp, state
end

-- Worst synchronizer wear of the manual gearboxes (0..1, 1 = the gear
-- cannot be engaged any more); nil without synchros or when unworn.
function M.synchroWear(devices)
  local worst
  for _, d in pairs(devices or {}) do
    if type(d) == 'table' and type(d.synchroWear) == 'table' then
      for _, w in pairs(d.synchroWear) do
        w = tonumber(w)
        if w and w > 0 and (worst == nil or w > worst) then worst = w end
      end
    end
  end
  return worst and round(math.min(worst, 1), 2) or nil
end

-- Names of the broken powertrain devices (driveshaft, wheelaxleFL,
-- gearbox, mainEngine...), sorted; nil when nothing is broken.
function M.broken(devices)
  local set, any = {}, false
  for name, d in pairs(devices or {}) do
    if type(d) == 'table' and d.isBroken == true then
      set[type(d.name) == 'string' and d.name or tostring(name)] = true
      any = true
    end
  end
  return any and sortedKeys(set) or nil
end

-- Shafts drawn on the phone's damage schematic, named like the game's
-- damage app: driveshaft (rear), driveshaft_F (front), wheelaxleFL...
function M.shafts(devices)
  local set = {}
  for name, d in pairs(devices or {}) do
    local n = type(d) == 'table' and type(d.name) == 'string' and d.name or tostring(name)
    if n:match('^driveshaft') or n:match('^wheelaxle') then set[n] = true end
  end
  local list = sortedKeys(set)
  return #list > 0 and list or nil
end

-- Where the engine sits along the car: 0 = front bumper, 1 = rear bumper.
-- enginePos, frontPos, backPos: { x, y, z } (the reference node and the
-- one behind it give the forward direction); nodes: every node position
-- (gives the length of the car).
function M.engineAt(enginePos, frontPos, backPos, nodes)
  if not (enginePos and frontPos and backPos) then return nil end
  local fx, fy, fz = frontPos.x - backPos.x, frontPos.y - backPos.y, frontPos.z - backPos.z
  local len = math.sqrt(fx * fx + fy * fy + fz * fz)
  if len < 1e-6 then return nil end
  fx, fy, fz = fx / len, fy / len, fz / len
  local function along(p) return p.x * fx + p.y * fy + p.z * fz end
  local front, rear
  for _, p in pairs(nodes or {}) do
    local a = along(p)
    if front == nil or a > front then front = a end
    if rear == nil or a < rear then rear = a end
  end
  if front == nil or front - rear < 0.5 then return nil end
  local at = (front - along(enginePos)) / (front - rear)
  return round(math.min(math.max(at, 0), 1), 2)
end

-- Largest wheelspin (tyre surface faster than the car) and locked-wheel
-- slip (wheel much slower than the car, braking), in m/s.
-- wheelSpeeds: tyre surface speeds (m/s); groundSpeed: car speed (m/s).
function M.spinLock(wheelSpeeds, groundSpeed)
  groundSpeed = math.abs(tonumber(groundSpeed) or 0)
  local spin, lock = 0, 0
  for _, speed in ipairs(wheelSpeeds or {}) do
    speed = math.abs(tonumber(speed) or 0)
    spin = math.max(spin, speed - groundSpeed)
    if groundSpeed > 3 and speed < groundSpeed * 0.5 then lock = math.max(lock, groundSpeed - speed) end
  end
  return round(spin, 2), round(lock, 2)
end

return M
