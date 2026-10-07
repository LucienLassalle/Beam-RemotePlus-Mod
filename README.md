# Beam-RemotePlus — BeamNG.drive mod

Drive BeamNG.drive with your phone. This mod is the game-side half of
[Beam-RemotePlus-Mobile](https://github.com/LucienLassalle/Beam-RemotePlus-Mobile),
a modern replacement for BeamNG's unmaintained official
[remote control app](https://github.com/BeamNG/remotecontrol).

## Features

- **Automatic pairing** on the local network: no QR code, no typing (the
  game's QR screen is unreliable since 0.39). The pairing code is also shown
  in game.
- **Analog steering, throttle and brake** through a virtual controller.
- **Full dashboard telemetry**: speed, RPM, gear label (P/R/N/D/S...), fuel,
  water/oil temperatures, boost, warning lights, indicators, ABS/ESC/TCS,
  cruise control, odometer, g-forces, tyre pressures, drive mode...
- **Vehicle functions**: horn and high beams (held), hazards, indicators,
  lights, parking brake, starter, ESC/drive mode, gearbox mode, cruise
  control, gears, recovery, vehicle and camera switching.
- **Local multiplayer**: one phone per player, each phone shows up under its
  own name in Options > Controls.
- **On by default**, with a switch to block phones: the *Enable Beam-RemotePlus
  (phones)* action in **Options > Controls > General** (bind it to any key) or
  the optional **Beam-RemotePlus** UI app.
- **Debug mode** for developers: verbose logs and command acknowledgements
  shown in the app.
- English and French.

## Installation

1. Download `Beam-RemotePlus.zip` from the
   [latest release](https://github.com/LucienLassalle/Beam-RemotePlus-Mod/releases/latest).
2. Put it in your BeamNG user folder `mods/` (or drag it onto the game window).
3. Enable **Beam-RemotePlus** in the mod manager. That's it: it starts with the
   game from now on.
4. Install the app, put the phone on the same network (or use its hotspot) and
   tap **Automatic connection**.

The mod uses UDP ports **4446** (PC) and **4447** (phone). Allow them in your
firewall if the phone cannot find the PC.

## Development

```bash
scripts/test_mod.sh        # unit tests (luajit)
scripts/build_mod.sh 2.1.0 # dist/Beam-RemotePlus.zip, version stamped
scripts/deploy_local.sh    # build + copy to the local game + hot reload
```

- Architecture and how to add a command or a language: [CONTRIBUTING.md](CONTRIBUTING.md)
- Wire protocol: [docs/PROTOCOL.md](docs/PROTOCOL.md)
- Releasing: publish a GitHub release with a `vX.Y.Z` tag; CI attaches the
  zip, SBOMs (SPDX + CycloneDX) and checksums.

## License

[CC BY-NC-SA 4.0](LICENSE): you may share and adapt this mod for
non-commercial purposes, with attribution, under the same license.
