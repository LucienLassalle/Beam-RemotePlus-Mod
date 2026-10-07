-- Vehicle damage summary for the phone (damage schematic + warning icons),
-- read from the game's damageTracker. Pure: the reader is injected.

local M = {}

-- Body zones tracked by beamstate.lua (front/middle/rear x left/right),
-- each 0..1 = share of the zone's beams deformed or broken.
M.BODY_ZONES = { 'FL', 'FR', 'ML', 'MR', 'RL', 'RR' }

-- Engine damage flags of combustionEngine.lua worth showing to a driver.
M.ENGINE_FLAGS = {
  'radiatorLeak', 'oilpanLeak', 'oilRadiatorLeak', 'coolantOverheating',
  'oilOverheating', 'headGasketDamaged', 'pistonRingsDamaged',
  'rodBearingsDamaged', 'engineLockedUp', 'engineHydrolocked', 'engineDisabled',
  'starvedOfOil', 'oilLevelCritical', 'turbochargerDamaged',
  'superchargerDamaged', 'exhaustBroken', 'inductionSystemDamaged',
  'blockMelted', 'cylinderWallsMelted', 'catastrophicOverrevDamage',
}

local function truthy(v)
  return v == true or (type(v) == 'number' and v > 0)
end

-- getDamage(group, name) -> value (damageTracker.getDamage)
-- wheelNames: { 'FL', 'FR', ... }
-- Returns nil fields when nothing is damaged, so a pristine car costs
-- nothing in the telemetry frame.
function M.collect(getDamage, wheelNames)
  local result = {}

  local body, anyBody = {}, false
  for _, zone in ipairs(M.BODY_ZONES) do
    local v = tonumber(getDamage('body', zone))
    if v and v > 0.001 then
      body[zone] = math.floor(math.min(v, 1) * 100 + 0.5) / 100
      anyBody = true
    end
  end
  if anyBody then result.bodyDamage = body end

  local engine = {}
  for _, flag in ipairs(M.ENGINE_FLAGS) do
    if truthy(getDamage('engine', flag)) then engine[#engine + 1] = flag end
  end
  if #engine > 0 then result.engineDamage = engine end

  local flat, hot = {}, {}
  for _, name in ipairs(wheelNames or {}) do
    if truthy(getDamage('wheels', 'tire' .. name)) then flat[#flat + 1] = name end
    if truthy(getDamage('wheels', 'brakeOverHeat' .. name)) then hot[#hot + 1] = name end
  end
  if #flat > 0 then result.flatTires = flat end
  if #hot > 0 then result.hotBrakes = hot end
  return result
end

return M
