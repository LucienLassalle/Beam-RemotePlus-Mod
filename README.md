# BeamNG RemotePlus — mod

A BeamNG.drive mod that extends the game's built-in remote control with **real
telemetry**, **analog pedals**, **vehicle switching**, **camera rotation**,
**gear shifting** and **vehicle recovery**. It is the companion mod of the
Android app
[Beam-RemotePlus-Mobile](https://github.com/LucienLassalle/Beam-RemotePlus-Mobile).

Together they form a **modern replacement for BeamNG's official
[remotecontrol](https://github.com/BeamNG/remotecontrol) app**, which is no
longer maintained.

---

## Why this mod

BeamNG's native remote control channel has two long-standing limitations:

1. its telemetry call is broken and never sends any data to the app;
2. its virtual device has only **one axis** for steering and **two on/off
   buttons** — no analog throttle or brake.

This mod fixes both, by **reusing BeamNG's native safety code**
(`core_remoteController`): no extra configuration on the game side.

---

## Features

- **Live telemetry** sent to the phone: speed, RPM, rev-limiter RPM, engaged
  gear, fuel level, water **and oil** temperatures, and indicators (high/low
  beam, handbrake, turn signals, oil warning light, ABS, **traction control /
  TC**, shift light).
- **Fully analog throttle and brake**, plus steering, via a 3-axis virtual
  input device.
- **Vehicle switching** (previous / next) from the phone.
- **Camera rotation** (previous / next) from the phone.
- **Gear shifting** (up / down) for a manual gearbox.
- **Vehicle recovery** (reset / unstuck), reproducing the native "Insert" key:
  short press = small reposition, long press = rewind further back in the
  position history.
- **Automatic discovery**: the mod answers the app's probes on the local
  network by returning the PC's address and the pairing code — connection with
  no QR code and no camera.
- **In-game pairing code display** at startup (toast message + console),
  essential since BeamNG's QR UI is broken (0.39).
- **Automatic activation on startup**: once enabled in the mod manager, the mod
  reloads its extension on every game launch (via `scripts/modScript.lua`),
  with no need to disable/re-enable it.

---

## This mod requires the companion app

The mod **has no UI of its own** and does nothing on its own. It only works
with the
[Beam-RemotePlus-Mobile](https://github.com/LucienLassalle/Beam-RemotePlus-Mobile)
app, which connects to it over the local network. Install both.

---

## Installation

1. Get `Beam-RemotePlus.zip`:
   - from the [Releases page](https://github.com/LucienLassalle/Beam-RemotePlus-Mod/releases),
   - or directly from `out/Beam-RemotePlus.zip` in this repo (built and tracked
     by Git: always up to date).
2. Put the `.zip` in BeamNG.drive's `mods/` folder (or drag it onto the game
   window / the mod manager).
3. In the **mod manager**, enable **Beam-RemotePlus**. This is the only manual
   step: after that the mod reloads itself on every startup.
4. Load a level with a vehicle. The mod listens on UDP port **4446** and shows
   the pairing code. Connect from the app (automatic connection recommended).

---

## Using it from the app

| From the app | In-game effect |
|---|---|
| Automatic connection | `beamngremoteplus\|discover` probe (broadcast 4446) → the mod replies `hello\|<code>\|<PC name>` on 4447. |
| Wheel / pedals | Analog axes of the `BeamRemotePlus` virtual device. |
| Gear buttons | Pulses of the `shiftUp` / `shiftDown` virtual buttons. |
| Prev./next vehicle | `core_input_vehicleSwitching.switchCycleVehicle`. |
| Prev./next camera | `core_camera.setVehicleCameraByIndexOffset`. |
| Recovery | `recovery.startRecovering()` / `stopRecovering()` on the player's vehicle. |

The virtual device shows up under **Options > Controls**; its default bindings
are in `src/settings/inputmaps/bngremoteplusv1.json` (direct passthrough, no
response curve).

---

## BeamNG 0.39+ compatibility

BeamNG 0.39 **did not break the protocol** — the native `core_remoteController`
backend and `getQRCode()` still work (verified on 0.39.4). What is broken is the
in-game **"Remote Control" UI** (Options > Controls > Hardware): the QR code
does not render reliably (canvas render race condition on the game side).
Without a displayable QR, the app could no longer pair.

This mod works around the problem:

- it **calls `getQRCode()` at startup**, which opens the native socket (port
  4444) and generates the code even if the user never opens the Options panel;
- it **shows the code** in-game (toast + console);
- it **answers the app's automatic discovery**, which then needs neither the QR
  nor the code.

> **Security note:** discovery returns the pairing code to anyone who sends a
> probe on the local network. In practice this is equivalent to brute-forcing
> the 5-digit code and is acceptable on a home LAN. It should be made optional
> if the mod is used on an untrusted network.

---

## Known issue: the app says "install the mod" while it is enabled

BeamNG does not always reload the extension on the game side right after a
(re)activation in the mod manager. **Workaround:** disable then re-enable the
mod — this forces the extension to reload, and the app detects it within a few
seconds. Automatic activation on startup avoids this on subsequent launches.

---

## Development

```bash
bash scripts/build_mod.sh   # packages src/ -> out/, Package/, and deploys
                            # to the local BeamNG mods/ folder + hot-reload trigger
bash scripts/test_mod.sh    # protocol unit tests (luajit required)
```

Hot-reload: `build_mod.sh` writes the zip then creates
`Beam-RemotePlus-reload.trigger` in the mods folder. If the game is running
with the mod active, the extension detects the trigger within ~3 s, picks up
the zip and reloads — without going through the mod manager.

| Path | Role |
|---|---|
| `src/lua/ge/extensions/beamRemotePlus/main.lua` | GE extension: sockets, handshake, control, telemetry, discovery. |
| `src/lua/ge/extensions/beamRemotePlus/protocol.lua` | Pure protocol logic (testable without BeamNG). |
| `src/scripts/modScript.lua` | Run on activation / startup: reloads the extension. |
| `src/settings/inputmaps/bngremoteplusv1.json` | Default bindings of the virtual device. |
| `test/protocol_test.lua` | Unit tests (binary format, messages, discovery). |

The binary format (control 12 bytes, telemetry 36 bytes, little-endian) is an
**exact mirror** of the Dart classes on the app side.

---

## Reporting an issue

[Open an issue](https://github.com/LucienLassalle/Beam-RemotePlus-Mod/issues)
on this repo, in **French or English**.
