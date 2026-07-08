#!/usr/bin/env luajit
-- Tests unitaires du protocole Beam-RemotePlus, exécutables directement :
--   luajit test/protocol_test.lua
-- (depuis Beam-RemotePlus-Mod/). N'exigent pas BeamNG.drive : protocol.lua
-- est un module pur (seule dépendance : la FFI de LuaJIT, identique à
-- celle utilisée par le jeu).

local scriptDir = arg[0]:match('(.*/)') or './'
package.path = scriptDir .. '?.lua;' .. scriptDir .. '../src/lua/ge/extensions/beamRemotePlus/?.lua;' .. package.path

local t = require('minitest')
local protocol = require('protocol')

t.describe('Handshake (ping/pong)', function()
  t.it('reconnaît un message ping', function()
    t.assertTrue(protocol.isPingMessage('beamngremoteplus|ping|20367'))
  end)

  t.it('rejette un message qui ne commence pas par le préfixe ping', function()
    t.assertFalse(protocol.isPingMessage('beamng|20367'))
    t.assertFalse(protocol.isPingMessage(''))
  end)

  t.it('construit un message ping avec le bon code', function()
    t.assertEquals(protocol.buildPingMessage(20367), 'beamngremoteplus|ping|20367')
  end)

  t.it('valide un ping correspondant au code attendu', function()
    t.assertTrue(protocol.pingMatchesCode('beamngremoteplus|ping|20367', '20367'))
  end)

  t.it('rejette un ping avec un code différent', function()
    t.assertFalse(protocol.pingMatchesCode('beamngremoteplus|ping|99999', '20367'))
  end)

  t.it('rejette un ping quand aucun code n\'est disponible', function()
    t.assertFalse(protocol.pingMatchesCode('beamngremoteplus|ping|20367', nil))
  end)

  t.it('construit un pong avec code et version', function()
    t.assertEquals(protocol.buildPongMessage('20367'), 'beamngremoteplus|pong|20367|1')
  end)
end)

t.describe('Timeout client', function()
  t.it('pas expiré juste après un ping', function()
    t.assertFalse(protocol.isClientTimedOut(1000, 900, 10000))
  end)

  t.it('expiré après le délai', function()
    t.assertTrue(protocol.isClientTimedOut(20000, 1000, 10000))
  end)

  t.it('traite lastSeen nil comme "jamais vu" (donc expiré)', function()
    t.assertTrue(protocol.isClientTimedOut(20000, nil, 10000))
  end)
end)

t.describe('Utilitaires', function()
  t.it('clampUnit borne à [0,1]', function()
    t.assertEquals(protocol.clampUnit(-0.5), 0)
    t.assertEquals(protocol.clampUnit(1.5), 1)
    t.assertEquals(protocol.clampUnit(0.42), 0.42)
  end)

  t.it('gearFromIndex applique le même décalage que le protocole natif', function()
    t.assertEquals(protocol.gearFromIndex(-1), 0) -- marche arrière
    t.assertEquals(protocol.gearFromIndex(0), 1)  -- point mort
    t.assertEquals(protocol.gearFromIndex(3), 4)  -- 3e rapport
    t.assertEquals(protocol.gearFromIndex(nil), 0)
  end)
end)

t.describe('computeLightsBitmask', function()
  t.it('retourne 0 sans aucun feu actif', function()
    t.assertEquals(protocol.computeLightsBitmask({}), 0)
  end)

  t.it('détecte les feux de croisement seuls', function()
    t.assertEquals(
      protocol.computeLightsBitmask({ lowbeam = 1 }),
      protocol.LIGHT_BIT_LOW_BEAM
    )
  end)

  t.it('cumule plusieurs feux actifs', function()
    local mask = protocol.computeLightsBitmask({
      lowbeam = 1,
      signal_R = 1,
      hasABS = true,
      absActive = 1,
    })
    t.assertEquals(
      mask,
      protocol.LIGHT_BIT_LOW_BEAM + protocol.LIGHT_BIT_SIGNAL_RIGHT + protocol.LIGHT_BIT_ABS
    )
  end)

  t.it('ABS ignoré si le véhicule n\'en a pas (hasABS false)', function()
    t.assertEquals(
      protocol.computeLightsBitmask({ hasABS = false, absActive = 1 }),
      0
    )
  end)

  t.it('frein à main ignoré si valeur à 0', function()
    t.assertEquals(protocol.computeLightsBitmask({ parkingbrake = 0 }), 0)
  end)
end)

t.describe('buildTelemetryCallExpression (régression bug %q)', function()
  t.it('quote correctement une IP (ne doit pas lever une erreur au parsing Lua)', function()
    local expr = protocol.buildTelemetryCallExpression(
      '192.168.1.151', 27.7, 4200, 7000, 2, 0.42, 91.5, 0, 0
    )
    -- Avant le correctif, %s (au lieu de %q) produisait
    -- "onTelemetry(192.168.1.151, ...)" sans guillemets : Lua essayait de
    -- lire 192.168.1.151 comme un nombre et levait
    -- "malformed number near '192.168.1.151'". load() doit réussir.
    local chunk, err = load('return function() ' .. expr .. ' end')
    t.assertNotNil(chunk, 'load() a échoué : ' .. tostring(err))
  end)

  t.it('contient l\'IP entourée de guillemets dans le texte généré', function()
    local expr = protocol.buildTelemetryCallExpression(
      '192.168.1.151', 0, 0, 0, 0, 0, 0, 0, 0
    )
    t.assertTrue(
      expr:find('"192.168.1.151"', 1, true) ~= nil,
      'IP non quotée trouvée dans: ' .. expr
    )
  end)

  t.it('capture bien l\'IP en tant que string (et pas un nombre) à l\'exécution', function()
    local capturedIp, capturedSpeed
    local expr = protocol.buildTelemetryCallExpression(
      '10.0.0.42', 12.5, 3000, 7000, 3, 0.8, 90, 0, 0
    )
    -- simule extensions.beamRemotePlus_main.onTelemetry pour capturer l'appel
    local env = {
      extensions = {
        beamRemotePlus_main = {
          onTelemetry = function(ip, speed) capturedIp, capturedSpeed = ip, speed end,
        },
      },
    }
    local chunk = load(expr, 'test', 't', env)
    chunk()
    t.assertEquals(type(capturedIp), 'string')
    t.assertEquals(capturedIp, '10.0.0.42')
    t.assertCloseTo(capturedSpeed, 12.5)
  end)
end)

t.describe('Paquet de contrôle (steering/throttle/brake)', function()
  t.it('round-trip encode puis decode', function()
    local bytes = protocol.encodeControlPacket(0.3, 0.8, 0.1)
    t.assertEquals(#bytes, 12)
    local steering, throttle, brake = protocol.decodeControlPacket(bytes)
    t.assertCloseTo(steering, 0.3)
    t.assertCloseTo(throttle, 0.8)
    t.assertCloseTo(brake, 0.1)
  end)

  t.it('refuse un paquet de taille incorrecte', function()
    t.assertNil(protocol.decodeControlPacket('trop court'))
  end)

  t.it('encode en little-endian (identique à ce qu\'attend l\'app Dart)', function()
    local bytes = protocol.encodeControlPacket(1.0, 0.0, 0.0)
    -- 1.0 en float32 little-endian = 00 00 80 3F
    local b = { bytes:byte(1, 4) }
    t.assertEquals(b[1], 0x00)
    t.assertEquals(b[2], 0x00)
    t.assertEquals(b[3], 0x80)
    t.assertEquals(b[4], 0x3F)
  end)
end)

t.describe('Commandes (cmd|)', function()
  t.it('reconnaît un message cmd', function()
    t.assertTrue(protocol.isCmdMessage('cmd|next_vehicle'))
    t.assertTrue(protocol.isCmdMessage('cmd|prev_vehicle'))
  end)

  t.it('rejette un non-cmd', function()
    t.assertFalse(protocol.isCmdMessage('beamng|next'))
    t.assertFalse(protocol.isCmdMessage(''))
    t.assertFalse(protocol.isCmdMessage(nil))
  end)

  t.it('les constantes CMD_NEXT et CMD_PREV sont correctement préfixées', function()
    t.assertTrue(protocol.isCmdMessage(protocol.CMD_NEXT_VEHICLE))
    t.assertTrue(protocol.isCmdMessage(protocol.CMD_PREV_VEHICLE))
  end)

  t.it('CMD_NEXT_VEHICLE vaut exactement cmd|next_vehicle', function()
    t.assertEquals(protocol.CMD_NEXT_VEHICLE, 'cmd|next_vehicle')
  end)

  t.it('CMD_PREV_VEHICLE vaut exactement cmd|prev_vehicle', function()
    t.assertEquals(protocol.CMD_PREV_VEHICLE, 'cmd|prev_vehicle')
  end)

  t.it('une commande connue n\'est pas aussi un ping', function()
    t.assertFalse(protocol.isPingMessage(protocol.CMD_NEXT_VEHICLE))
  end)
end)

t.describe('Paquet de télémétrie', function()
  t.it('encode 32 octets (8 floats)', function()
    local bytes = protocol.encodeTelemetryPacket(25, 3500, 7000, 2, 0.6, 88.5, 16, 1)
    t.assertEquals(#bytes, 32)
  end)

  t.it('layout little-endian cohérent avec ModTelemetryPacket côté Dart', function()
    local ffi = require('ffi')
    local bytes = protocol.encodeTelemetryPacket(25, 3500, 7000, 2, 0.6, 88.5, 16, 1)
    local view = ffi.cast('float*', bytes)
    t.assertCloseTo(view[0], 25)    -- speed
    t.assertCloseTo(view[1], 3500)  -- rpm
    t.assertCloseTo(view[2], 7000)  -- redlineRpm
    t.assertCloseTo(view[3], 2)     -- gear
    t.assertCloseTo(view[4], 0.6)   -- fuel
    t.assertCloseTo(view[5], 88.5)  -- engineTemp
    t.assertCloseTo(view[6], 16)    -- lights
    t.assertCloseTo(view[7], 1)     -- shiftLight
  end)
end)

t.summary()
