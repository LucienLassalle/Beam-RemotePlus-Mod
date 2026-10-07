#!/usr/bin/env luajit
-- Runs every *_test.lua of this folder:  luajit test/run.lua
-- No BeamNG required: game APIs are replaced by test/fakes.lua.

local testDir = arg[0]:match('(.*/)') or './'
local srcDir = testDir .. '../src/'
-- Modules require each other with their in-game absolute path
-- ('/lua/ge/extensions/beamRemotePlus/x'), resolved here against src/.
-- Vehicle-side modules use the game's vehicle path (lua/vehicle/?.lua).
package.path = srcDir .. '?.lua;' .. srcDir .. 'lua/vehicle/?.lua;' .. testDir .. '?.lua;' .. package.path

local suites = {}
local listing = io.popen('ls "' .. testDir .. '"')
for name in listing:lines() do
  if name:match('_test%.lua$') then suites[#suites + 1] = name end
end
listing:close()
table.sort(suites)

for _, suite in ipairs(suites) do
  print('== ' .. suite)
  dofile(testDir .. suite)
end

require('minitest').summary()
