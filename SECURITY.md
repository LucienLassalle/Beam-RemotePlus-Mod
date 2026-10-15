# Security policy

Please **do not open a public issue** for a vulnerability. Use
[GitHub private vulnerability reporting](https://github.com/LucienLassalle/Beam-RemotePlus-Mod/security/advisories/new)
instead; you will get an answer within a week.

## Threat model

The mod listens on UDP port 4446 on the local network. A phone must know the
5-digit pairing code of the game's native remote control to send inputs.
Automatic discovery returns that code to any device on the same network: only
use the mod on a network you trust (home LAN or your phone's hotspot), or lock
out new phones (in-game panel or "Beam-RemotePlus: lock out new phones"
action) once yours are connected: discovery then gets no answer. Commands only ever run predefined vehicle functions; no text sent by
the phone is executed as code.
