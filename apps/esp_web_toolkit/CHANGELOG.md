# Changelog

Each version is published at `https://nebkat.github.io/esp-web-toolkit/vX.Y.Z/`.

## 0.6.2 — 2026-10-10

- One-click flasher: a share menu copies the bundle's link or an `<iframe>` embed code; `&iframe` on a link is a compact flasher for other sites (the frame needs `allow="serial"`).

## 0.6.1 — 2026-10-07

- Remote devices: any `wss://` address is accepted, including named sessions (a device's serial) with a `?grant=`.

## 0.6.0 — 2026-10-05

- Monitor: timestamps as printed, readable (`boot+1m 02.345s`, full dates) or in local time (estimated for time since boot); hover one to see it as printed. Optional time since the previous line, and host arrival time.
- Monitor: right-click a line to copy it, hide or show only its tag, filter by its level, or search for the selection.
- Monitor: level filter chips, and a "show only these tags" mode.
- Monitor: a scrollbar marked with errors, warnings and reboots along its length; a button to stick to the bottom or not.

## 0.5.1 — 2026-10-02

- Flashing a bundle checks its images against the chip and its role files for conflicts first; dumped bundles include the bootloader.
- Flasher stub v1.3.0.

## 0.5.0 — 2026-09-30

- eFuses page: overview, key blocks, fields by category and raw blocks.

## 0.4.0 — 2026-09-29

- Relay: hand out the relay's own share link, and show the signed-in client.

## 0.3.1 — 2026-09-29

- Wider port picker, led by the identified chip and MAC; title menu linking to idftool.

## 0.3.0 — 2026-09-25

- Routes in the URL fragment (`#/flash?remote=…`); unversioned links open the latest version.

## 0.2.0 — 2026-09-25

- Share a device through a relay, and use one shared that way (RFC 2217).

## 0.1.0 — 2026-09-17

- First published version.
