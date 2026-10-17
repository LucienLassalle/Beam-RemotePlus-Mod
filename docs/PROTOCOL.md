# Beam-RemotePlus protocol (version 2)

All messages are UDP datagrams on the local network.

| Direction | Port | Content |
|---|---|---|
| phone → PC | **4446** | discovery probe, ping, control packets, commands |
| PC → phone | **4447** | hello, pong, telemetry, events |

The game's native remote control (`core_remoteController`, UDP 4444)
provides the **pairing code**: the mod reuses its 5-digit code. Its port
accepts the same code: while new phones are locked out, the mod refuses the
virtual device it creates for a new phone, so that phone gets no answer.

**Handshake prefix.** Discovery and pairing messages start with
`beamremoteplus|`. Apps up to 0.0.3 use `beamngremoteplus|`. The mod accepts
both and always answers with the prefix of the request. An app that does not
know the mod's version sends both until the first answer, then keeps the
prefix of that answer.

## 1. Discovery (optional, no code needed)

```
phone → broadcast:4446   beamremoteplus|discover
PC    → phone:4447       beamremoteplus|hello|<code>|<label>
```

`<label>` is a readable PC name ("Loka's PC"), never contains `|`.

**Pairing QR code.** The in-game panel shows a QR code holding
`beamremoteplus://pair?code=<code>&host=<PC address>#<code>` (`&host=` is
left out when the PC address is unknown). The app pings that address
first, then the broadcast addresses. The `#<code>` end keeps the code
readable by apps that only look for it after `#`.

## 2. Pairing (ping / pong)

```
phone → PC:4446   beamremoteplus|ping|<code>|<version>|<device name>[|<role>[|<app version>]]
PC    → phone     beamremoteplus|pong|<code>|<negotiated version>
```

- `<version>`: highest protocol version the app speaks (2). Version 1 apps
  only send `beamremoteplus|ping|<code>`.
- The negotiated version is `min(app, mod)`. With version 1 the mod sends
  the legacy binary telemetry (section 5).
- `<role>` (optional): `controller` (default) or `display`.
- `display` (optional): **second screen**. The phone gets the telemetry of
  player 1 but no virtual input device, its control packets are ignored and
  every command except `debug` and `skeleton` is refused with `display_only`. A phone that
  changes role starts a new session.
- `<app version>` (optional, after the role): release version of the app
  (`0.0.5`, `0.0.5-0.39`, the version given to the build).
  The mod compares it with its own version to tell which side needs an
  update. Older apps do not send it.
- The phone pings every 500 ms until it receives the pong, then every 2 s:
  if the mod restarted and forgot the phone, the ping re-creates the session. Once paired, any
  packet (the 60 Hz control packets) keeps the session alive; a phone silent
  for **10 s** is disconnected.

## 3. Control packet (12 bytes)

Three little-endian `float32`, each clamped to `[0, 1]`:

| Offset | Field | Meaning |
|---|---|---|
| 0 | steering | 0 = full right, 0.5 = centre, 1 = full left |
| 4 | throttle | 0..1 |
| 8 | brake | 0..1 |

Sent at ~60 Hz. Each phone gets its own virtual input device named
`BeamRemotePlus (<device name>)` (input map `bngremoteplusv1`), which BeamNG
assigns to a player in local multiplayer.

**Watchdog.** A driving phone that sends no control packet for **1 s**
(Wi-Fi drop, app closed or frozen) no longer accelerates: the mod centres
its steering, releases its hold commands (horn...) and, from the car's
telemetry, brakes a moving car at 0.6 for up to **5 s** (with the throttle
when it reverses in arcade mode, where the pedals swap). Once the car is
below 0.5 m/s, the pedals are released and the handbrake holds it, so an
arcade gearbox never reverses. The next control packet gives the controls
back at once and releases that handbrake. A second screen never brakes.

## 4. Commands

```
cmd|<name>            press commands
cmd|<name>|1 / |0     hold commands (pressed / released)
```

| Command | Kind | Effect (same as the game's input action) |
|---|---|---|
| `horn` | hold | horn |
| `highbeam` | hold | high beams while held (headlight flash) |
| `starter` | hold | ignition / starter key |
| `recover` | hold | rewind like the Insert key (short = small reset) |
| `handbrake` | hold | parking brake while held (drifting) |
| `hazard`, `signal_left`, `signal_right` | press | indicators |
| `lights` | press | cycle headlights |
| `parkingbrake` | press | toggle parking brake |
| `esc_mode` | press | next drive mode / ESC mode |
| `shifter_mode` | press | cycle gearbox modes |
| `cruise_set`, `cruise_resume`, `cruise_off`, `cruise_up`, `cruise_down` | press | cruise control |
| `flashers` | press | emergency lights on / off (off also stops the siren) |
| `siren` | press | siren on / off (on also switches the emergency lights on) |
| `drs` | press | opens / closes the DRS wing of the vehicle mods that have one (CF26, FR17) |
| `push_to_pass` | press | starts / stops the Push-to-Pass boost of the CF26 vehicle mod |
| `pit_limiter` | press | pit limiter on / off on the fr04 vehicle mods (F4, CF26) |
| `gear_up`, `gear_down` | press | sequential shift |
| `next_vehicle`, `prev_vehicle` | press | switch vehicle (player's own) |
| `cam_next`, `cam_prev` | press | camera |
| `debug` | hold | `1` = acknowledge every command, `0` = errors only |
| `skeleton` | press | sends the skeleton of the vehicle (`skeleton` messages below) |
| `leave` | press | the player disconnects on purpose: the car is stopped like after a lost signal (watchdog above), then the phone is disconnected once the handbrake holds it (a second screen at once); never acknowledged |
| `actions` | press | lists the commands of the "More" sheet for the vehicle (`actions` message below) |
| `action\|<id>` | press | runs one of them (pressed then released) |
| `action_down\|<id>`, `action_up\|<id>` | press | holds one of them down, releases it (released by the mod when the phone disconnects or loses the signal) |

Version 1 aliases: `recover_start` = `recover|1`, `recover_stop` = `recover|0`.

Hold commands still active when a phone disconnects are released by the mod.

## 5. Messages from the mod

### Version 2: JSON

Every datagram is a JSON object with a `type`. **Unknown types and unknown
fields must be ignored** (forward compatibility).

**`telemetry`** (~30 Hz). A field is **omitted** when the vehicle does not
provide it (show "n/a", do not assume 0).

| Field | Unit / type |
|---|---|
| `speed`, `airspeed` | m/s |
| `rpm`, `maxRpm`, `idleRpm` | rpm |
| `gear` | label shown by the car: `P`, `R`, `N`, `D`, `S5`, `1`... |
| `gearIndex`, `maxGearIndex` | int (-1 = R, 0 = N) |
| `gearboxMode` | string |
| `fuel` | 0..1 |
| `fuelVolume`, `fuelCapacity` | litres (kWh for electric cars) |
| `waterTemp`, `oilTemp`, `envTemp` | °C |
| `boost` | turbo boost as reported by the game |
| `engineRunning` | bool |
| `ignitionLevel` | 0 off, 1 accessory, 2 on, 3 starting |
| `engineLoad`, `throttle`, `brake`, `clutch` | 0..1 (actual vehicle values) |
| `parkingBrake`, `lowBeam`, `highBeam`, `signalLeft`, `signalRight`, `hazard` | bool |
| `lowPressure`, `checkEngine`, `lowFuel` | bool (warning lights) |
| `hasAbs`, `absActive`, `hasEsc`, `escActive`, `hasTcs`, `tcsActive` | bool |
| `cruiseActive` | bool |
| `cruiseSpeed` | m/s |
| `hasLightbar`, `hasSiren` | `true` when the vehicle is fitted with emergency lights / a siren (police, ambulance, fire, pace car), omitted otherwise |
| `lightbar` | `0` off, `1` emergency lights, `2` lights + siren (fitted vehicles only) |
| `hasDrs`, `drsOpen` | DRS of the vehicle mods that have one (CF26, FR17): present, wing open |
| `hasPushToPass`, `pushToPass`, `pushToPassLeft` | Push-to-Pass of the CF26 vehicle mod: present, boost active, seconds of boost left |
| `hasPitLimiter`, `pitLimiter` | pit limiter of the fr04 vehicle mods (F4, CF26): present, on |
| `odometer`, `trip` | metres |
| `gx`, `gy`, `gz` | smoothed acceleration, m/s² |
| `driftAngle` | degrees -180..180 from where the car points to where it goes, counter-clockwise seen from above (positive: it goes to the left of its nose); omitted below 3 m/s |
| `shiftLight` | bool |
| `tirePressures` | object `{ "FL": kPa, "FR": kPa, ... }` |
| `tirePressuresNominal` | same, the pressures set in the vehicle configuration (compare to them, race cars run low pressures) |
| `driveMode` | object `{ "key": "...", "name": "..." }`: drive mode, or the ESC mode (`"esc": true`) on vehicles without drive modes; `"color"`: its color in the game UI (`"98FB00"`), when it has one |
| `wheelSlip` | largest wheel slip velocity, m/s |
| `wheelSpin`, `wheelLock` | largest wheelspin (tyre faster than the car) and locked-wheel slip, m/s |
| `brakeTemps` | `{ "FL": °C, ... }` brake disc surface temperature |
| `clutchTemp` | clutch temperature, °C (manual / DCT / centrifugal clutches only) |
| `clutchState` | `hot`, `overheating` (slipping) or `damaged`; omitted when fine |
| `brokenParts` | array of broken powertrain devices: `driveshaft`, `wheelaxleFL`, `mainEngine`... |
| `powertrain` | `combustion`, `electric` or `hybrid`. For electric cars `fuel` is the battery charge (0..1) and `fuelVolume` / `fuelCapacity` are in kWh, as the game reports them |
| `motorPower` | power of the electric motors, kW (negative = regenerative braking) |
| `gearboxWear` | worst synchronizer wear of a manual gearbox, 0..1 (1 = gear lost); omitted when unworn |
| `gearGrinding` | bool, a shift just ground the gears (set for 2 s by the game) |
| `lowAirPressure` | bool, air brakes pressure low (trucks, buses) |
| `drivetrain` | `{ "shafts": ["driveshaft", "wheelaxleRL", ...], "engineAt": 0..1 }` (0 = front bumper, 1 = rear) |
| `bodyDamage` | `{ "FL": 0..1, "FR", "ML", "MR", "RL", "RR" }`, omitted when intact |
| `engineDamage` | array of failures: `radiatorLeak`, `oilpanLeak`, `coolantOverheating`, `engineLockedUp`..., and the live dangers `turbochargerHot`, `overRevDanger`, `overTorqueDanger`, `engineIsHydrolocking` |
| `flatTires`, `hotBrakes` | arrays of wheel names (`hotBrakes` = brakes fading) |
| `brokenBrakes`, `brokenWheels` | arrays of wheel names (molten brake, wheel torn off) |
| `fuelLeak` | bool, fuel tank damaged |
| `batteryDamaged` | bool, traction battery damaged (electric cars) |
| `tyres` | `{ "FL": { "temp", "working", "condition", "brake", "surface"?, "core"? } }` (°C, condition % left), only with the *Tyre Thermals and Wear* mod |
| `radar` | array of the 12 nearest cars within 50 m, nearest first: `{ "x": m right, "y": m ahead, "heading": ° relative, "length", "width" }` (`[]` when nobody is around) |
| `player` | player index (0-based) |
| `vehicle` | vehicle model (`scintilla`, `bolide`...) |
| `skeleton` | id of the vehicle skeleton (changes with the vehicle or its configuration): ask for its geometry with `cmd\|skeleton` when it is not the one you have |
| `skeletonDamage` | one digit per skeleton segment, `0` intact .. `9` badly bent or broken (the game's detailed damage app scale), `""` = intact. Sent at most 4 times a second when it changes and every 2 s; keep the last one |

**`skeleton`**: the vehicle structure seen from above (the beams of the
game's detailed damage app), answer to `cmd|skeleton`, split into
datagrams of 150 segments that can arrive in any order.

```json
{"type":"skeleton","id":"2412-1f3a","offset":150,"count":2412,
 "seg":[-80,200,80,200, ...],
 "wheels":{"FL":[-78,141,31,22]},"engine":[0,120]}
```

- Coordinates are integer **centimetres**, `x` to the right and `y`
  forward of the vehicle reference node. `seg` holds `x1, y1, x2, y2` for
  segments `offset` .. `offset + n - 1` of `count`; segment `i` is digit
  `i` of `skeletonDamage`.
- `wheels`: centre `x, y`, radius and width (cm) by wheel name. Tyre beams
  are not in `seg`. `engine`: engine (or electric motor) position.
- Missing datagrams: ask again with `cmd|skeleton`.

**`ack`**: result of a command. Always sent on failure, on success only in
debug mode.

```json
{"type":"ack","cmd":"horn|1","ok":false,"error":"no_vehicle"}
```

Errors: `unknown_command`, `bad_argument`, `no_vehicle`, `display_only`,
`unavailable:<feature>`.

**`session`**: sent when the player is assigned, when debug mode is
switched on and when an optional mod is enabled, disabled, installed or
removed.

```json
{"type":"session","modVersion":"0.0.3","player":0,"commands":["cam_next", "..."],
 "optionalMods":{"tyreThermals":"enabled","f4":"enabled","cf26":"disabled","fr17":"missing"}}
```

`optionalMods` (not sent by older mods): state of every optional mod the
mod works with, `enabled`, `disabled` (installed but turned off in the mod
manager) or `missing`. Ids: `tyreThermals` (Tyre Thermals and Wear by Luuk,
or its continuation Tyre Wear and Thermals Redux), `f4` (Carbonworks F4),
`cf26`, `fr17`. Unknown ids must be ignored.

`playerColor` (not sent by older mods, nor to a second screen or an
unassigned phone): `#rrggbb` colour the game gives the player, the one of
its name tag above the car in local multiplayer.

**`kicked`**: the player removed this phone from the in-game panel. The
session is already closed on the mod side: the app must stop pinging (it
would reconnect at once otherwise) and go back to its pairing screen. The
phone may pair again later, unless new phones are locked out.

```json
{"type":"kicked"}
```

**`actions`**: answer to `cmd|actions`, the commands of the vehicle the
phone drives, beyond the dashboard buttons:

```json
{"type":"actions","vehicle":"pickup","actions":[
  {"id":"g:four_wd","kind":"press"},
  {"id":"v:toggle_tailgate","kind":"press","title":"Toggle tailgate"}]}
```

- `g:<id>`: a generic command of the game the vehicle is fitted for, in
  this order: `fog_lights`, `four_wd`, `range` (low range), `diff_lock`,
  `two_step`, `transbrake`, `line_lock`, `nitrous`, `lightbar_mode`,
  `couplers` (trailer). No title: the app translates the id.
- `v:<name>`: an action the vehicle declares itself, like its key
  binding in Options > Controls, with its `title` in the game language.
- `kind`: `press` (send `action`) or `hold` (send `action_down`, then
  `action_up` on release).

### Version 1: binary telemetry (36 bytes)

Nine little-endian `float32`: speed (m/s), rpm, redline rpm, gear (0 = R,
1 = N, 2+ = gear + 1), fuel (0..1), water temperature, lights bitmask (1 low
beam, 2 high beam, 4 handbrake, 8 left, 16 right, 32 oil, 64 ABS, 128 TC),
shift light (0/1), oil temperature.
