# Remote Control Protocol — DreamAiri Music Studio

This document describes the loopback remote-control server embedded in **Bosca Ceoil — DreamAiri**. It allows external processes, such as the DreamAiri Godot editor plugin, to drive the live composition in real time over a local TCP socket.

The authoritative protocol specification is defined in:
`knowledge/decisions/music-studio.md` (section "Control protocol v1") in the DreamAiri repository.

---

## Launching

The remote-control server is **disabled by default**. It starts only when the application is launched with the `--dreamairi-handoff` argument after the engine `--` separator:

```bash
godot -- --dreamairi-handoff /path/to/handoff.json
```

### Command-line flags

All flags go after the engine `--` separator, so the app is plain-CLI launchable and scriptable:

| Flag | Meaning |
|---|---|
| `--dreamairi-handoff <file>` | Start the control server using this handoff file (deleted on read). Without it nothing is started and the app behaves exactly like upstream Bosca Ceoil. |
| `<path>.ceol` | Existing upstream behavior: open this song on startup. |

This build is meant to be opened from the DreamAiri Godot plugin (the dock's **Music Studio** button or the
`music_studio` agent tool), which creates the handoff file and picks the port. It is not distributed or
installed on its own.

### Handoff File

The launcher creates a private JSON handoff file (mode 0600 in a private directory) containing:

```json
{
  "protocol": 1,
  "secret": "<64 lowercase hex characters>",
  "output_dir": "<absolute directory path>",
  "ready_file": "<absolute path to ready file>"
}
```

Upon startup, Bosca:
1. Reads the handoff file.
2. Deletes the handoff file immediately.
3. Validates `protocol == 1`, `secret` (64 hex characters), and ensures `output_dir` exists.
4. Binds an ephemeral port on `127.0.0.1`.
5. Atomically writes the `ready_file` with `{"port": N, "pid": P, "app_version": "1.0"}`.

---

## Protocol Summary

- **Transport**: TCP on `127.0.0.1`, single client at a time. A second concurrent connection is rejected immediately.
- **Framing**: 4-byte big-endian unsigned length + UTF-8 JSON object (max 4 MiB frame size). Oversized or malformed frames cause immediate disconnect.
- **Handshake**: First frame must be `hello` within 5 seconds:
  ```json
  {"op": "hello", "protocol": 1, "secret": "<64 hex>", "client": "dreamairi-plugin"}
  ```
  Reply on success:
  ```json
  {"ok": true, "protocol": 1, "app_version": "1.0", "tools": [...], "export": ["midi"]}
  ```
  Reply on invalid secret:
  ```json
  {"ok": false, "error": "invalid secret"}
  ```
  followed by connection closure.
- **Requests & Responses**:
  - `{"id": N, "op": "ping"}` → `{"id": N, "ok": true, "result": {}}`
  - `{"id": N, "op": "shutdown"}` → `{"id": N, "ok": true, "result": {}}` and triggers graceful quit. With unsaved edits the app asks before quitting instead of closing immediately.
  - `{"id": N, "op": "tool", "name": "<tool>", "args": {...}}` → `{"id": N, "ok": true, "result": {...}}`
- **Events** (unsolicited from Bosca, no `id`):
  - `{"event": "song_saved"}` when the song is saved in the app.
  - `{"event": "closing"}` best-effort when the application is quitting.

### Supported Tools

Reachable via `op: "tool"`:
- `create_song`, `add_instrument`, `remove_instrument`, `create_pattern`
- `add_notes`, `remove_notes` (capped at 512 notes per call)
- `set_arrangement`, `set_effect`, `get_song_state`, `play_song`, `list_instruments`
- `snapshot` `{}` → `{"state": <get_song_state>, "ceol": "<ceol text>", "midi_b64": "<base64 midi>"}`
- `load_song` `{"ceol": "<text>"}` → parses via SongLoader and refreshes editor views
- `save_song` `{"name": "<basename>"}` → writes `<output_dir>/<name>.ceol`, returns `{path, bytes}`
- `export_song` `{"format": "midi", "name": "<basename>"}` → writes MIDI export file to `output_dir` (remote export supports MIDI only; WAV export is done by the user via File > Export)

---

## Known Limitations

- **WAV Rendering / Export**: Remote export supports MIDI only (`export` handshake advertises `["midi"]`). Remote WAV rendering is not implemented. WAV export must be done by the user via **File > Export > WAV** in the app. Calling `export_song` with `format: "wav"` returns `{"error": "WAV export through remote control is not implemented; use File > Export > WAV in the app"}`.

---

## Security Notes

1. **Loopback Only**: The server binds exclusively to `127.0.0.1`. It never listens on external interfaces.
2. **Secret Handling**:
   - The shared secret is generated with high entropy (32 CSPRNG bytes, 64 hex characters).
   - The secret is never passed on argv or stored in environment variables.
   - The handoff file is deleted immediately after reading.
   - Secrets are compared using constant-time comparison to prevent timing side-channel attacks.
   - The secret is **never logged**.
3. **Path Protection**:
   - `save_song` and `export_song` only write files inside `output_dir`.
   - File basenames are strictly validated against `^[A-Za-z0-9._-]{1,64}$` and forbidden from starting with `.`. Directory traversal (`/`, `\`, `..`) is impossible.
   - If `output_dir` is empty, tools return `{"error": "remote control not active"}`.
4. **DoS Protections**:
   - 4 MiB frame limit prevents buffer exhaustion.
   - 5-second hello timeout prevents idle connection holding before authentication.
   - Only 1 concurrent client is permitted; additional connection attempts are disconnected immediately.
