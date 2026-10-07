#!/usr/bin/env python3
"""Developer tool: talks to the running mod like the phone app does.

Discovers the game, pairs, enables debug acks, sends a few harmless commands
and prints what comes back: which telemetry fields the current vehicle sends
and the result of every command. Neutral controls are sent (wheel centred,
pedals released) to keep the session alive.

Usage: scripts/fake_phone.py [host] [--seconds N] [--command NAME[|ARG] ...]
  host defaults to broadcast discovery on 127.0.0.1 then 255.255.255.255.
"""
import argparse
import json
import socket
import struct
import time

HOST_PORT, CLIENT_PORT = 4446, 4447


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("host", nargs="?")
    parser.add_argument("--seconds", type=float, default=4)
    parser.add_argument("--command", action="append", default=[])
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.bind(("0.0.0.0", CLIENT_PORT))
    sock.settimeout(0.3)

    # 1. discovery
    targets = [args.host] if args.host else ["127.0.0.1", "255.255.255.255"]
    code = host = None
    for _ in range(10):
        for t in targets:
            sock.sendto(b"beamngremoteplus|discover", (t, HOST_PORT))
        try:
            data, addr = sock.recvfrom(2048)
        except socket.timeout:
            continue
        msg = data.decode(errors="replace")
        if msg.startswith("beamngremoteplus|hello|"):
            code, label = (msg.split("|", 3)[2:] + ["?"])[:2]
            host = addr[0]
            print(f"hello from {host}: code={code} label={label!r}")
            break
    if not code:
        raise SystemExit("no answer to discovery (is the game running with the mod enabled?)")

    # 2. pairing
    ping = f"beamngremoteplus|ping|{code}|2|fake_phone.py".encode()
    version = None
    for _ in range(10):
        sock.sendto(ping, (host, HOST_PORT))
        try:
            data, _ = sock.recvfrom(2048)
        except socket.timeout:
            continue
        msg = data.decode(errors="replace")
        if msg.startswith(f"beamngremoteplus|pong|{code}"):
            version = msg.split("|")[3]
            print(f"pong: protocol v{version}")
            break
    if not version:
        raise SystemExit("no pong")

    neutral = struct.pack("<fff", 0.5, 0.0, 0.0)
    commands = ["debug|1"] + (args.command or ["hazard", "hazard", "horn|1", "horn|0", "fly"])
    fields, frames, sent_at = set(), 0, time.time()
    last_frame = None
    while time.time() - sent_at < args.seconds:
        sock.sendto(neutral, (host, HOST_PORT))
        if commands and time.time() - sent_at > 0.5:
            cmd = commands.pop(0)
            sock.sendto(f"cmd|{cmd}".encode(), (host, HOST_PORT))
            time.sleep(0.3)
        try:
            data, _ = sock.recvfrom(4096)
        except socket.timeout:
            continue
        if not data.startswith(b"{"):
            continue
        msg = json.loads(data)
        if msg.get("type") == "telemetry":
            frames += 1
            fields |= set(msg) - {"type"}
            last_frame = msg
        else:
            print(msg)
    print(f"{frames} telemetry frames in {args.seconds}s")
    print("fields:", ", ".join(sorted(fields)) or "-")
    if last_frame:
        print("last frame:", json.dumps(last_frame, sort_keys=True)[:1500])


if __name__ == "__main__":
    main()
