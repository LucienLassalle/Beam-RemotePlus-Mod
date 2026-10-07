# Contributing

Thanks for helping! Issues and pull requests are welcome in **English or French**.

## Ground rules

- **Sign off every commit** (Developer Certificate of Origin): `git commit -s`.
  By signing off you certify you wrote the change or have the right to submit it
  under the project license ([DCO 1.1](https://developercertificate.org)). The
  `DCO` check blocks pull requests with unsigned commits; fix them with
  `git rebase --signoff master`.
- **Conventional Commits**: `feat(commands): add wipers`, `fix(telemetry): ...`,
  `docs: ...`. One logical change per commit.
- **Code, comments and logs in English.** User-facing texts go through the
  translation files (see below).
- **Tests**: every Lua module under `src/lua/ge/extensions/beamRemotePlus/` has a
  `test/<module>_test.lua`. Run them with `scripts/test_mod.sh` (needs `luajit`).
- The project is licensed under **CC BY-NC-SA 4.0**: contributions are accepted
  under the same license.

## Project layout

| Path | Role |
|---|---|
| `src/lua/ge/extensions/beamRemotePlus/main.lua` | Entry point: binds BeamNG globals to the modules below. |
| `.../server.lua` | Packet routing, pairing, enable switch, timeouts. |
| `.../protocol.lua`, `json.lua` | Wire format (see [docs/PROTOCOL.md](docs/PROTOCOL.md)). |
| `.../clients.lua` | Connected phones and their virtual input devices. |
| `.../commands.lua` | Command table (horn, lights, cruise control...). |
| `.../telemetry.lua` | Requests vehicle snapshots and sends them to phones. |
| `src/lua/vehicle/extensions/beamRemotePlus/telemetry.lua` | Runs inside the vehicle, collects the data. |
| `.../config.lua`, `i18n.lua`, `logger.lua` | Settings file, translations, logs. |
| `src/lua/ge/extensions/core/input/actions/beamRemotePlus.json` | "Enable Beam-RemotePlus" action in Options > Controls. |
| `src/ui/modules/apps/BeamRemotePlus/` | Optional in-game UI app. |
| `src/locales/translations/<lang>/` | In-game translations. |

## Adding a command

1. Add an entry to `PRESS_ACTIONS` or `HOLD_ACTIONS` in `commands.lua` (the
   vehicle Lua is usually the `onDown`/`onUp` of the matching action in the
   game's `lua/ge/extensions/core/input/actions/vehicle.json`).
2. Add a test in `test/commands_test.lua`.
3. Document it in `docs/PROTOCOL.md`.

## Adding a language

Copy `src/locales/translations/en-US/beamRemotePlus.translation.json` to the
game's folder name for your language (e.g. `de_DE`) and translate the values,
never the keys. `test/assets_test.lua` checks that all languages define the
same keys.

## Testing in game

```bash
scripts/deploy_local.sh   # builds, copies into the user mods folder, hot-reloads
```

Then watch `beamng.log` in the BeamNG user folder (lines tagged `beamRemotePlus`).
Enable verbose logs with the "Beam-RemotePlus debug mode" action or the UI app.
