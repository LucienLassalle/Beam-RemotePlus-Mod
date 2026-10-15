local t = require('minitest')
local fakes = require('fakes')
local nativeRemote = require('/lua/ge/extensions/beamRemotePlus/nativeRemote')

-- The game's Lua sandbox only allows reading upvalues.
local sandboxedDebug = { getupvalue = debug.getupvalue }

-- Same locals as the game's lua/ge/extensions/core/remoteController.lua; a
-- pairing phone gets an answer only once its virtual device exists.
local function fakeGameRemote(input)
  local env = { opened = 0, answers = 0 }
  local udpSocket = nil
  local code = 54880
  local M = {}
  function M.getQRCode()
    if udpSocket == nil then
      env.opened = env.opened + 1
      udpSocket = {}
    end
    return code
  end
  function env.pair(name)
    local id = input.createDevice(name, nativeRemote.NATIVE_VIDPID, 1, 2, 0)
    if id and id >= 0 then env.answers = env.answers + 1 end
    return id
  end
  env.module = M
  return env
end

local function setup()
  local input = fakes.input()
  local game = fakeGameRemote(input)
  local native = nativeRemote.new(function() return game.module end, function() return input end, sandboxedDebug)
  return native, game, input
end

t.describe('nativeRemote', function()
  t.it('reads the pairing code without opening the port', function()
    local native, game = setup()
    t.assertEquals(native.getCode(), '54880')
    t.assertEquals(game.opened, 0)
  end)
  t.it('opens the port once', function()
    local native, game = setup()
    t.assertTrue(native.open())
    t.assertTrue(native.open())
    t.assertEquals(game.opened, 1)
  end)
  t.it('refuses the game a device for a new phone while locked', function()
    local native, game = setup()
    t.assertTrue(native.setLocked(true))
    t.assertEquals(game.pair('Pixel'), -1)
    t.assertEquals(game.answers, 0)
  end)
  t.it('pairs again once unlocked', function()
    local native, game = setup()
    native.setLocked(true)
    game.pair('Pixel')
    native.setLocked(false)
    t.assertTrue(game.pair('Pixel') >= 0)
    t.assertEquals(game.answers, 1)
  end)
  t.it('never refuses the devices of the mod', function()
    local native, _, input = setup()
    native.setLocked(true)
    t.assertTrue(input.createDevice('BeamRemotePlus (Pixel)', 'bngremoteplusv1', 3, 2, 0) >= 0)
  end)
  t.it('installs the guard again if the game reloaded the input module', function()
    local input = fakes.input()
    local game = fakeGameRemote(input)
    local current = input
    local native = nativeRemote.new(function() return game.module end, function() return current end, sandboxedDebug)
    native.setLocked(true)
    current = fakes.input()
    t.assertTrue(native.setLocked(true))
    t.assertEquals(current.createDevice('Pixel', nativeRemote.NATIVE_VIDPID, 1, 2, 0), -1)
  end)
  t.it('puts the game function back when the mod unloads', function()
    local native, game, input = setup()
    local before = input.createDevice
    native.setLocked(true)
    native.restore()
    t.assertEquals(input.createDevice, before)
    t.assertTrue(game.pair('Pixel') >= 0)
  end)
  t.it('reports when the lock cannot be enforced', function()
    local native = nativeRemote.new(function() return nil end, function() return nil end, sandboxedDebug)
    t.assertFalse(native.setLocked(true))
    t.assertTrue(native.setLocked(false))
    t.assertNil(native.getCode())
  end)
end)
