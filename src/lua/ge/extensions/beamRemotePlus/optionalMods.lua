-- Optional mods Beam-RemotePlus works with (none of them is needed), and
-- whether each one is installed and enabled in the game.
--
-- Two sources, both factual:
--   1. the game's mod manager (core_modmanager.getMods()): every installed
--      mod with its enabled state, and for mods from the BeamNG.drive
--      repository their repository id (tagid), which stays the same across
--      versions and file names;
--   2. a file only that mod ships, looked up in the game's virtual file
--      system, which also finds a mod installed by hand (no repository id)
--      as long as it is enabled.

local M = {}

M.ENABLED = 'enabled'
M.DISABLED = 'disabled' -- installed but turned off in the mod manager
M.MISSING = 'missing'

-- In the order shown to the player.
M.CATALOG = {
  {
    -- Luuk's original (unsupported since 2024) and its maintained
    -- continuation "Tyre Wear and Thermals Redux": same data for the phone.
    id = 'tyreThermals',
    tagids = { 'MDQKSX6UR', 'MXFQY32S5' },
    files = { '/ui/modules/apps/TyreWearThermals/app.json', '/ui/modules/apps/tyrewearthermals/app.json' },
  },
  {
    id = 'f4', -- Carbonworks F4 by LucasBE: the fr04 vehicle itself
    tagids = { 'MYSB93TC7' },
    files = { '/vehicles/fr04/fr04.jbeam' },
  },
  {
    id = 'cf26', -- CF26, add-on of the F4 (its F3 configurations)
    tagids = { 'MSH2WZ9QV' },
    files = { '/vehicles/fr04/CF26_p2p.jbeam' },
  },
  {
    id = 'fr17',
    tagids = { 'MCSAUJ2PR' },
    files = { '/vehicles/FR17/FR17.jbeam' },
  },
}

--[[
deps:
  getMods()       -> core_modmanager.getMods(): { [modname] = { active, modData = { tagid } } },
                     nil while the mod manager is not available
  fileExists(path) -> bool, in the game's virtual file system (enabled mods only)
]]
function M.new(deps)
  local self = {}
  local states = {}

  local function stateOf(entry, installed)
    for _, path in ipairs(entry.files) do
      if deps.fileExists(path) then return M.ENABLED end
    end
    for _, tagid in ipairs(entry.tagids) do
      local mod = installed[tagid]
      if mod then return mod.active and M.ENABLED or M.DISABLED end
    end
    return M.MISSING
  end

  -- Reads both sources again. Returns true when a state changed.
  function self.refresh()
    -- Several entries may share a repository id (the same mod installed
    -- twice): an enabled one wins.
    local installed = {}
    local ok, mods = pcall(deps.getMods)
    for _, mod in pairs(ok and type(mods) == 'table' and mods or {}) do
      local tagid = type(mod) == 'table' and type(mod.modData) == 'table' and mod.modData.tagid or nil
      if tagid and not (installed[tagid] and installed[tagid].active) then installed[tagid] = mod end
    end
    local changed = false
    for _, entry in ipairs(M.CATALOG) do
      local state = stateOf(entry, installed)
      if states[entry.id] ~= state then
        states[entry.id] = state
        changed = true
      end
    end
    return changed
  end

  function self.state(id) return states[id] or M.MISSING end

  -- { tyreThermals = 'enabled', ... } (session message).
  function self.states()
    local all = {}
    for _, entry in ipairs(M.CATALOG) do all[entry.id] = self.state(entry.id) end
    return all
  end

  -- Every supported mod with its state, in catalog order (in-game panel).
  function self.list()
    local list = {}
    for _, entry in ipairs(M.CATALOG) do list[#list + 1] = { id = entry.id, state = self.state(entry.id) } end
    return list
  end

  return self
end

return M
