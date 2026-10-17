-- Commands of the phone's "More" sheet: what the vehicle can do beyond the
-- dashboard buttons. Two kinds, both shown by the phone in one list:
--   g:<id>   the game's own vehicle input actions (vehicle.json,
--            gameplay.json) the vehicle is fitted for, found by the
--            vehicle VM (lua/vehicle/extensions/beamRemotePlus/features.lua)
--            and titled by the app (its translations);
--   v:<name> the actions the vehicle declares itself (input_actions*.json,
--            jbeam inputActions: tailgate, crane, vehicle mods...), as the
--            game lists them in Options > Controls, titled by the game.
-- Pure: the game's action table and translator are passed as arguments.

local M = {}

M.GENERIC_PREFIX = 'g:'
M.VEHICLE_PREFIX = 'v:'

-- Same vehicle code as the matching input actions of the game.
M.GENERIC = {
  fog_lights = 'electrics.toggle_fog_lights()',
  four_wd = "for _, v in pairs(controller.getControllersByType('4wd')) do v.toggle4WD() end",
  range = "for _, v in pairs(controller.getControllersByType('4wd')) do v.toggleRange() end",
  diff_lock = "if #controller.getControllersByType('4wd') > 0 then for _, v in pairs(controller.getControllersByType('4wd')) do v.toggleDiffs() end else powertrain.toggleDefaultDiffs() end",
  two_step = "controller.getControllerSafe('twoStepLaunch').toggleTwoStep()",
  transbrake = "for _, v in pairs(controller.getControllersByType('braking/transbrake')) do v.toggleTransbrake() end",
  line_lock = "for _, v in pairs(controller.getControllersByType('lineLock')) do v.toggleLineLock() end",
  nitrous = "for _, v in pairs(controller.getControllersByType('nitrousOxideInjection')) do v.toggleActive() end",
  lightbar_mode = "for _, v in pairs(controller.getControllersByType('lightbar')) do v.toggleMode() end",
  couplers = 'beamstate.toggleCouplers()',
}

-- Entries for the ids the vehicle VM found, in its order.
function M.genericEntries(ids)
  local entries = {}
  for _, id in ipairs(type(ids) == 'table' and ids or {}) do
    if M.GENERIC[id] then entries[#entries + 1] = { id = M.GENERIC_PREFIX .. id, kind = 'press' } end
  end
  return entries
end

-- A vehicle action held like a key (it does something on release or
-- follows the key value), or a single press.
function M.kind(action)
  if action.onUp ~= nil or action.onChange ~= nil then return 'hold' end
  return 'press'
end

-- Actions of the vehicle model among the game's active actions
-- (core_input_actions.getActiveActions(), keyed "<model>__<name>"), the
-- ones the game marks unusable left out, and two-way axes too (a button
-- only gives one direction). translate: the game's _tr, may be nil.
function M.vehicleEntries(actions, model, translate)
  local prefix = tostring(model) .. '__'
  local found = {}
  for uniqueName, action in pairs(type(actions) == 'table' and actions or {}) do
    if type(action) == 'table' and action.vehicle == model and action.cat ~= 'vehicle_specific_unusable'
      and not action.isCentered and action.onRelative == nil
      and type(uniqueName) == 'string' and uniqueName:sub(1, #prefix) == prefix then
      local name = uniqueName:sub(#prefix + 1)
      local title
      if type(translate) == 'function' and type(action.title) == 'string' then
        local ok, text = pcall(translate, action.title)
        if ok and type(text) == 'string' and text ~= '' and text ~= action.title then title = text end
      end
      if not title and type(action.title) == 'string' and not action.title:find('^ui%.') then title = action.title end
      found[#found + 1] = {
        id = M.VEHICLE_PREFIX .. name, title = title or name, kind = M.kind(action),
        order = tonumber(action.order) or math.huge,
      }
    end
  end
  table.sort(found, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.title < b.title
  end)
  for _, entry in ipairs(found) do entry.order = nil end
  return found
end

return M
