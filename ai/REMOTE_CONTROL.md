# Remote Control Protocol — DreamAiri Music Studio

This document describes the loopback remote-control server embedded in **Bosca Ceoil — DreamAiri**. It allows external processes, such as the DreamAiri Godot editor plugin and the in-terminal studio panel, to drive the live composition in real time over a local TCP socket.

The authoritative protocol specification is defined in:
`knowledge/decisions/music-studio.md` (sections "Control protocol v1" and "Terminal studio") in the DreamAiri repository.

---

## Launching and Engine Mode

The remote-control server is **disabled by default**. It starts only when the application is launched with the `--dreamairi-handoff` argument after the engine `--` separator.

### Engine Mode (Terminal Studio)
In engine mode, Bosca runs headless without creating an OS window:
```bash
godot --display-driver headless --audio-driver CoreAudio --path /path/to/bosca -- --dreamairi-handoff /path/to/handoff.json
```
(Tests and CI use `--audio-driver Dummy`).

In headless engine mode (`DisplayServer.get_name() == "headless"`):
- A remote `shutdown` op emits the `closing` event and quits immediately (exit 0), without blocking on an unsaved changes popup (the music log is the persistence layer).
- In GUI / desktop mode, unsaved edits continue to prompt the save confirmation dialog before exiting.

### Command-line flags

All flags go after the engine `--` separator:

| Flag | Meaning |
|---|---|
| `--dreamairi-handoff <file>` | Start the control server using this handoff file (deleted immediately on read). Without it nothing is started and the app behaves like standard Bosca Ceoil. |
| `<path>.ceol` | Open this song file on startup. |

### Handoff File

The launcher creates a private JSON handoff file (mode 0600 in a 0700 private directory):

```json
{
  "protocol": 1,
  "secret": "<64 lowercase hex characters>",
  "viewer_secret": "<64 lowercase hex characters, optional>",
  "output_dir": "<absolute directory path>",
  "ready_file": "<absolute path to ready file>"
}
```

Upon startup, Bosca:
1. Reads the handoff file.
2. Deletes the handoff file immediately.
3. Validates `protocol == 1`, `secret` (64 hex characters), and ensures `output_dir` exists.
4. Reads `viewer_secret` if present (64 hex characters, distinct from `secret`). If missing or invalid, the viewer role is disabled.
5. Binds an ephemeral port on `127.0.0.1`.
6. Atomically writes the `ready_file` with `{"port": N, "pid": P, "app_version": "1.0"}`.

---

## Roles and Connection Slots

The server supports up to two authenticated client slots:
- **`controller`**: Authenticated using `secret` in `hello`. Has full control including all tools and `shutdown`.
- **`viewer`**: Authenticated using `viewer_secret` in `hello`. Restricted to the viewer tool allowlist; cannot invoke destructive tools or `shutdown`.

Roles are determined strictly by secret matching, never by client claim. A missing or invalid `viewer_secret` in the handoff disables the viewer role. At most one client per role is permitted; a second client attempting to authenticate for an already occupied role is rejected with an error and closed after its `hello`.

---

## Protocol Summary

- **Transport**: TCP loopback only (`127.0.0.1`).
- **Framing**: 4-byte big-endian unsigned length prefix + UTF-8 JSON object (max 4 MiB frame size in either direction). Oversized or malformed frames cause immediate disconnect.
- **Handshake**: First frame must be `hello` within 5 seconds:
  ```json
  {"op": "hello", "protocol": 1, "secret": "<64 hex>", "client": "dreamairi-plugin"}
  ```
  Reply on success:
  ```json
  {
    "ok": true,
    "protocol": 1,
    "app_version": "1.0",
    "tools": [...],
    "export": ["midi", "wav"],
    "features": ["viewer", "relay", "transport"]
  }
  ```
  Reply on invalid secret:
  ```json
  {"ok": false, "error": "invalid secret"}
  ```
  followed by connection closure. Secrets are compared using constant-time comparison.
- **Requests & Responses**:
  - `{"id": N, "op": "ping"}` → `{"id": N, "ok": true, "result": {}}`
  - `{"id": N, "op": "shutdown"}` → `{"id": N, "ok": true, "result": {}}` (Controller only). If sent by a viewer, returns `{"id": N, "ok": false, "error": "shutdown not allowed for viewer"}`.
  - `{"id": N, "op": "tool", "name": "<tool>", "args": {...}}` → `{"id": N, "ok": true, "result": {...}}`
- **Relay (viewer → controller)**:
  - Viewer sends: `{"id": N, "op": "relay", "action": "save" | "rate", "args": {...}}`
  - Engine forwards to controller: `{"event": "relay_request", "rid": R, "action": action, "args": args}`
  - Controller responds: `{"op": "relay_result", "rid": R, "ok": bool, "result": {...}}`
  - Engine replies to viewer: `{"id": N, "ok": bool, "result": {...}}`
  - Errors:
    - Unsupported action: `{"ok": false, "error": "unknown action: ..."}`
    - No controller connected: `{"ok": false, "error": "no_controller"}`
    - 15-second timeout: `{"ok": false, "error": "timeout"}`
    - Non-controller sending `relay_result`: ignored.
- **Events** (unsolicited, broadcast to all connected authenticated clients):
  - `{"event": "song_changed", "version": N}`: Emitted whenever the song changes by any client tool call, GUI edit, or load. Coalesced to <= 10/s with trailing edge, strictly increasing `version`.
  - `{"event": "transport", "playing": bool, "bar": int, "step": int}`: Immediate on play/stop state change, throttled to <= ~15/s while playing.
  - `{"event": "song_saved"}`: When the song is saved in the app.
  - `{"event": "closing"}`: When the application is shutting down.

---

## Tools

Reachable via `op: "tool"` (in engine mode, playback remains stopped after startup, `create_song`, and `load_song` unless `"autoplay": true` is passed):

| Tool | Parameters | Viewer Allowed | Description |
|---|---|:---:|---|
| `get_song_state` | `{}` | Yes | Full song state: instruments, patterns, arrangement, effects |
| `get_transport` | `{}` | Yes | Transport status: `{"playing": bool, "bar": int, "step": int, "pattern_size": int, "timeline_length": int, "bpm": int}` |
| `play_song` | `{"action": "play" \| "stop"}` | Yes | Start or stop playback |
| `set_tempo` | `{"bpm": 10..450}` | Yes | Set tempo and update synthesizer driver: `{"success": true, "bpm": N}` |
| `add_notes` | `{"pattern_index": int, "notes": [...]}` | Yes | Add notes (≤ 512 per call) |
| `remove_notes` | `{"pattern_index": int, "notes": [...]}` | Yes | Remove notes (≤ 512 per call) |
| `create_pattern` | `{"instrument_index": int, "key": int, "scale": int}` | Yes | Create empty pattern |
| `set_arrangement` | `{"entries": [{"bar": int, "channel": int, "pattern_index": int}]}` | Yes | Place patterns on arrangement grid |
| `list_instruments` | `{"category": str?}` | Yes | List instruments by category |
| `create_song` | `{"bpm": int, "pattern_size": int, "key": int, "scale": int}` | No | Reset and create a new song |
| `load_song` | `{"ceol": str}` | No | Parse and load song from ceol text |
| `snapshot` | `{}` | No | Snapshot song state, ceol text, and MIDI base64 |
| `save_song` | `{"name": str}` | No | Save song to `<output_dir>/<name>.ceol` |
| `export_song` | `{"format": "midi" \| "wav", "name": str, "loop_start": int?, "loop_end": int?}` | No | Export song to `<output_dir>/<name>.<ext>` (`format: "wav"` renders offline PCM WAV audio; `"midi"` writes MIDI sequence; by default exports the whole song: bars `0 .. timeline_length`; optional `loop_start` and `loop_end` specify a sub-range) |
| `remove_instrument`| `{"instrument_index": int}` | No | Remove instrument by index |
| `add_instrument` | `{"category": str, "name": str}` | Yes | Add instrument by name (capped at song max of 16) |
| `set_instrument` | `{"instrument_index": int, "category": str, "name": str}` | Yes | Replace voice of instrument at index: `{"success": true, "instrument_index": N, "category": str, "name": str}` |
| `set_effect` | `{"effect": int, "power": int}` | No | Configure global effect |

### Instrument Changes

- `add_instrument` adds a new instrument voice by fuzzy name lookup and assigns the next index. Allowed for viewers, but capped at the song's instrument limit (16).
- `set_instrument` replaces the voice of the existing instrument at `instrument_index` with the voice found by fuzzy lookup (`_find_voice`), keeping every pattern and note that references that instrument. It reuses the GUI's instrument-change path (`Controller.instance_instrument_by_voice`, `pattern.change_instrument`, and `Controller.song_instrument_changed`), so the synth driver is updated immediately and playback uses the new voice without interruption (even while playing).
  - Refuses switching between a drumkit and a melodic instrument: `{"error": "cannot switch between a drumkit and a melodic instrument; add a new instrument instead"}`.
  - Invalid index: `{"error": "Invalid instrument index: N"}`.
  - Unknown voice: `{"error": "Instrument not found in category '<category>': <name>. Use list_instruments to see available names."}`.
  - On success, marks the song dirty and emits `song_instrument_changed` (broadcasting a `song_changed` event).

### Song Export

- `export_song` supports `wav` and `midi` formats.
- By default, it renders the entire song arrangement: bars `0 .. timeline_length`.
- Optional integer arguments `loop_start` and `loop_end` (bars) export a sub-range (`0 <= loop_start < loop_end <= timeline_length`). Whole-number floats (such as `3.0`) are accepted; fractional numbers or invalid ranges are rejected with an error.
- For `wav` export, playback is stopped first (resetting playback position and arrangement) so rendering starts from the beginning of the export range.
- The arrangement's original loop range is restored after export completes.

A refused call from a viewer for unauthorized tools returns:
```json
{"id": N, "ok": true, "result": {"error": "tool not allowed for viewer"}}
```

---

## Security Notes

1. **Loopback Only**: The server binds exclusively to `127.0.0.1`.
2. **Secret Handling**:
   - `secret` and `viewer_secret` are 64 lowercase hex characters (32 CSPRNG bytes).
   - Never passed on command-line arguments or environment variables.
   - Handoff file is deleted immediately after reading.
   - Compared in constant time without timing side channels.
   - Never written to logs.
3. **Path Protection**:
   - `save_song` and `export_song` only write files inside `output_dir`.
   - File basenames are strictly validated against `^[A-Za-z0-9._-]{1,64}$` and forbidden from starting with `.`.
4. **DoS Protections**:
   - 4 MiB frame limit prevents buffer exhaustion.
   - 5-second hello timeout prevents idle unauthenticated connections.
   - Maximum of two authenticated roles (`controller`, `viewer`). Duplicate connections of an occupied role are closed.
