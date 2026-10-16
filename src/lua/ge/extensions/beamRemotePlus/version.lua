-- Release versions of the mod and of the app, as stamped at build time from
-- the version given to the build: "0.0.4-0.39" is version 0.0.4 built for
-- BeamNG.drive 0.39 (the suffix is ignored when comparing). A version that
-- is not a release number, or a missing one, is never compared.

local M = {}

-- "0.0.4", "v0.0.4-0.39" -> { 0, 0, 4 }; nil for nil or anything that does
-- not start with a release number.
function M.parse(text)
  if type(text) ~= 'string' then return nil end
  local major, minor, patch = text:match('^v?(%d+)%.(%d+)%.(%d+)')
  if not major then return nil end
  return { tonumber(major), tonumber(minor), tonumber(patch) }
end

-- -1 if a is older than b, 0 if they are the same release, 1 if a is
-- newer; nil when either one is not a release version.
function M.compare(a, b)
  local va, vb = M.parse(a), M.parse(b)
  if not va or not vb then return nil end
  for i = 1, 3 do
    if va[i] ~= vb[i] then return va[i] < vb[i] and -1 or 1 end
  end
  return 0
end

-- Which side should be updated so the app and the mod match: 'app' when
-- the app is older, 'mod' when the mod is older, nil when they match or
-- when either version is unknown.
function M.outdated(modVersion, appVersion)
  local c = M.compare(modVersion, appVersion)
  if c == 1 then return 'app' end
  if c == -1 then return 'mod' end
  return nil
end

return M
