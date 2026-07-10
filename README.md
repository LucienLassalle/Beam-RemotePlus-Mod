# BeamNG RemotePlus — Mod

A BeamNG.drive mod that upgrades the game's built-in remote control feature with real telemetry, analog pedals, vehicle switching, camera control, and vehicle recovery — designed as the companion mod for the [Beam-RemotePlus-Mobile](https://github.com/LucienLassalle/Beam-RemotePlus-Mobile) Android app.

This project is part of a modern **replacement for BeamNG's official [remotecontrol](https://github.com/BeamNG/remotecontrol) app, which is no longer maintained**.

## Why this mod exists

BeamNG's native remote control channel has two long-standing limitations:

1. Its telemetry call is broken and never actually sends data to the connected app.
2. Its virtual pedals only support a single steering axis and two on/off buttons — no analog throttle or brake.

This mod fixes both, while reusing BeamNG's existing native QR code and pairing flow — no extra configuration is needed in-game.

## Features

- **Live telemetry** sent to the phone: speed, RPM, redline RPM, current gear, fuel level, engine temperature, and light/warning indicators (high/low beam, handbrake, turn signals, ABS).
- **Fully analog throttle and brake**, plus steering, via a virtual input device.
- **Vehicle switching** (next/previous) triggered from the phone.
- **Camera cycling** (next/previous) triggered from the phone.
- **Manual gear shifting** (up/down) triggered from the phone.
- **Vehicle recovery** (reset/unstuck), mirroring the native "Insert" key behavior — a short press nudges the vehicle, holding it rewinds further.

## Important: this mod requires the companion app

This mod has **no user interface of its own** and does nothing on its own. It only works together with the [Beam-RemotePlus-Mobile](https://github.com/LucienLassalle/Beam-RemotePlus-Mobile) Android app, which connects to it over your local network. Install both the mod and the app to use any of the features above.

## Installation

1. Download `Beam-RemotePlus.zip` from the [Releases page](https://github.com/LucienLassalle/Beam-RemotePlus-Mod/releases) of this repository.
2. Place the `.zip` file in your BeamNG.drive `mods` folder (or install it directly through BeamNG's in-game **Repository/Mod Manager** if available).
3. In BeamNG.drive, open the **Mod Manager** and make sure **Beam-RemotePlus** is enabled.
4. Launch or reload into a level, then pair with it using the [Beam-RemotePlus-Mobile app](https://github.com/LucienLassalle/Beam-RemotePlus-Mobile) as described in its README (scan the QR code from **Options > Controls > Hardware > Remote Control App**).

## Known issue: app says "install the mod" even though it's already installed

This is a **known, currently unfixed bug**. BeamNG doesn't always reload a mod's game-side extension right after it's (re)activated in the Mod Manager, so the app may not detect it immediately.

**Workaround:** in BeamNG's Mod Manager, **disable the mod, then re-enable it**. This forces the game to reload the extension correctly, and the app should detect it within a few seconds.

## Reporting issues

If you run into a problem, please [open an issue](https://github.com/LucienLassalle/Beam-RemotePlus-Mod/issues) on this repository. You can write it in **English or French**.
