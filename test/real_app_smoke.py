#!/usr/bin/env python3
"""Drive the REAL Bosca Ceoil app (with GDSiON) over protocol v1 in engine mode."""
import json
import os
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

def find_godot():
    env_bin = os.environ.get("GODOT_BIN")
    if env_bin and os.path.isfile(env_bin) and os.access(env_bin, os.X_OK):
        return env_bin
    for p in ["/Users/agamairi/bin/godot4", "/Applications/Godot.app/Contents/MacOS/Godot"]:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    for cmd in ["godot", "godot4"]:
        path = shutil.which(cmd)
        if path:
            return path
    return None

GODOT = find_godot()
if not GODOT:
    print("FAIL: could not locate Godot executable", file=sys.stderr)
    sys.exit(1)

PROJECT = sys.argv[1] if len(sys.argv) > 1 else "."

work = tempfile.mkdtemp(prefix="bosca-smoke-")
os.chmod(work, 0o700)
out_dir = os.path.join(work, "out")
os.makedirs(out_dir, mode=0o700)
ready = os.path.join(work, "ready.json")
handoff = os.path.join(work, "handoff.json")

secret = secrets.token_hex(32)
viewer_secret = secrets.token_hex(32)

with open(handoff, "w") as f:
    json.dump({
        "protocol": 1,
        "secret": secret,
        "viewer_secret": viewer_secret,
        "output_dir": out_dir,
        "ready_file": ready
    }, f)
os.chmod(handoff, 0o600)

cmd = [
    GODOT,
    "--display-driver", "headless",
    "--audio-driver", "Dummy",
    "--path", PROJECT,
    "--",
    "--dreamairi-handoff", handoff
]

log_path = os.path.join(work, "app.log")
log_file = open(log_path, "w")
proc = subprocess.Popen(cmd, stdout=log_file, stderr=subprocess.STDOUT)

checks = 0
passed = 0

def check(description, condition):
    global checks, passed
    checks += 1
    if condition:
        passed += 1
        print(f"  PASS: {description}")
    else:
        print(f"  FAIL: {description}")

s_ctrl = None
s_view = None
s_view2 = None
s_ctrl2 = None

def cleanup():
    for s in [s_ctrl, s_view, s_view2, s_ctrl2]:
        if s:
            try:
                s.close()
            except Exception:
                pass
    try:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except Exception:
                proc.kill()
    except Exception:
        pass
    try:
        shutil.rmtree(work, ignore_errors=True)
    except Exception:
        pass

class Client:
    def __init__(self, port, timeout=10.0):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        self.sock.settimeout(timeout)
        self.buf = bytearray()
        self.events = []

    def send(self, obj):
        b = json.dumps(obj).encode("utf-8")
        self.sock.sendall(struct.pack(">I", len(b)) + b)

    def recv_frame(self, timeout=None):
        if timeout is not None:
            self.sock.settimeout(timeout)
        while True:
            if len(self.buf) >= 4:
                n = struct.unpack(">I", self.buf[:4])[0]
                if len(self.buf) >= 4 + n:
                    payload = self.buf[4:4+n]
                    del self.buf[:4+n]
                    return json.loads(payload.decode("utf-8"))
            chunk = self.sock.recv(4096)
            if not chunk:
                raise EOFError("closed")
            self.buf.extend(chunk)

    def recv_response(self, req_id=None, timeout=6.0):
        t0 = time.time()
        while time.time() - t0 < timeout:
            frame = self.recv_frame(timeout=max(0.1, timeout - (time.time() - t0)))
            if frame.get("event"):
                self.events.append(frame)
                continue
            if req_id is None or frame.get("id") == req_id:
                return frame
        raise TimeoutError(f"Timed out waiting for response to id {req_id}")

    def drain_events(self, timeout=0.1):
        old_timeout = self.sock.gettimeout()
        self.sock.settimeout(timeout)
        try:
            while True:
                frame = self.recv_frame()
                if frame.get("event"):
                    self.events.append(frame)
        except (socket.timeout, TimeoutError, EOFError):
            pass
        finally:
            try:
                self.sock.settimeout(old_timeout)
            except Exception:
                pass
        ev = list(self.events)
        self.events.clear()
        return ev

    def wait_for_event(self, event_name, timeout=6.0):
        t0 = time.time()
        for i, e in enumerate(self.events):
            if e.get("event") == event_name:
                return self.events.pop(i)
        while time.time() - t0 < timeout:
            try:
                frame = self.recv_frame(timeout=max(0.1, timeout - (time.time() - t0)))
                if frame.get("event") == event_name:
                    return frame
                elif frame.get("event"):
                    self.events.append(frame)
            except (socket.timeout, TimeoutError):
                break
        return None

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass

def parse_wav_info(path):
    if not os.path.isfile(path):
        return {}, 0.0, b""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 44 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        return {}, 0.0, b""
    pos = 12
    fmt = {}
    audio_data = b""
    while pos + 8 <= len(data):
        chunk_id = data[pos:pos+4]
        chunk_size = struct.unpack("<I", data[pos+4:pos+8])[0]
        pos += 8
        if chunk_id == b"fmt ":
            fmt["audio_format"] = struct.unpack("<H", data[pos:pos+2])[0]
            fmt["channels"] = struct.unpack("<H", data[pos+2:pos+4])[0]
            fmt["sample_rate"] = struct.unpack("<I", data[pos+4:pos+8])[0]
            fmt["byte_rate"] = struct.unpack("<I", data[pos+8:pos+12])[0]
            fmt["block_align"] = struct.unpack("<H", data[pos+12:pos+14])[0]
            fmt["bits_per_sample"] = struct.unpack("<H", data[pos+14:pos+16])[0]
        elif chunk_id == b"data":
            audio_data = data[pos:pos+chunk_size]
        pos += chunk_size
    sample_rate = fmt.get("sample_rate", 44100)
    channels = fmt.get("channels", 2)
    duration = len(audio_data) / (sample_rate * channels * 2) if (sample_rate and channels) else 0.0
    return fmt, duration, audio_data

try:
    # Wait for ready file
    t0 = time.time()
    while not os.path.exists(ready):
        if proc.poll() is not None or time.time() - t0 > 40:
            print(f"FAIL: app did not become ready (exit={proc.poll()})", file=sys.stderr)
            cleanup()
            sys.exit(1)
        time.sleep(0.2)
    
    with open(ready) as f:
        info = json.load(f)
    port = info["port"]

    # 1. Controller + Viewer connected
    s_ctrl = Client(port)
    s_ctrl.send({"op": "hello", "protocol": 1, "secret": secret, "client": "smoke-ctrl"})
    r_ctrl = s_ctrl.recv_frame()

    s_view = Client(port)
    s_view.send({"op": "hello", "protocol": 1, "secret": viewer_secret, "client": "smoke-view"})
    r_view = s_view.recv_frame()
    
    check("controller + viewer connected", r_ctrl.get("ok") and r_view.get("ok"))

    # App ready -> get_transport is playing:false
    s_ctrl.send({"id": 999, "op": "tool", "name": "get_transport", "args": {}})
    r_tr_ready = s_ctrl.recv_response(999)
    tr_ready = r_tr_ready.get("result", {})
    check("app ready -> get_transport is playing:false",
          r_tr_ready.get("ok") is True and
          tr_ready.get("playing") is False and
          tr_ready.get("step") == 0)

    # 2. Viewer set_tempo -> both see song_changed
    s_view.send({"id": 1, "op": "tool", "name": "set_tempo", "args": {"bpm": 140}})
    res_tempo = s_view.recv_response(1)
    ev_sc_view = s_view.wait_for_event("song_changed", timeout=4.0)
    ev_sc_ctrl = s_ctrl.wait_for_event("song_changed", timeout=4.0)
    check("viewer set_tempo -> both see song_changed", 
          res_tempo.get("ok") is True and 
          res_tempo.get("result", {}).get("bpm") == 140 and 
          ev_sc_view is not None and 
          ev_sc_ctrl is not None)

    # 3. Controller add_notes -> viewer song_changed then viewer get_song_state shows the notes
    s_ctrl.send({"id": 2, "op": "tool", "name": "add_notes", "args": {
        "pattern_index": 0,
        "notes": [{"note": 60, "position": 0, "length": 2}]
    }})
    res_notes = s_ctrl.recv_response(2)
    ev_sc_view2 = s_view.wait_for_event("song_changed", timeout=4.0)
    s_view.send({"id": 3, "op": "tool", "name": "get_song_state", "args": {}})
    st = s_view.recv_response(3)
    pats = st.get("result", {}).get("patterns", [])
    has_note = any(any(n.get("note") == 60 and n.get("position") == 0 for n in p.get("notes", [])) for p in pats)
    check("controller add_notes -> viewer song_changed then viewer get_song_state shows notes",
          res_notes.get("ok") is True and ev_sc_view2 is not None and has_note)

    # 3a. Viewer add_instrument returns next index (1)
    s_view.send({"id": 30, "op": "tool", "name": "add_instrument", "args": {
        "category": "DRUMKIT",
        "name": "Simple Drumkit"
    }})
    res_add_inst = s_view.recv_response(30)
    ev_sc_ctrl_add = s_ctrl.wait_for_event("song_changed", timeout=4.0)
    add_inst_ok = (res_add_inst.get("ok") is True and
                   res_add_inst.get("result", {}).get("success") is True and
                   res_add_inst.get("result", {}).get("instrument_index") == 1)
    check("add_instrument as viewer returns the next index", add_inst_ok and ev_sc_ctrl_add is not None)

    # 3b. Melodic -> drumkit refused
    s_view.send({"id": 31, "op": "tool", "name": "set_instrument", "args": {
        "instrument_index": 0,
        "category": "DRUMKIT",
        "name": "Simple Drumkit"
    }})
    res_m2d = s_view.recv_response(31)
    check("melodic -> drumkit refused",
          res_m2d.get("ok") is True and
          res_m2d.get("result", {}).get("error") == "cannot switch between a drumkit and a melodic instrument; add a new instrument instead")

    # 3c. Drumkit -> melodic refused
    s_view.send({"id": 32, "op": "tool", "name": "set_instrument", "args": {
        "instrument_index": 1,
        "category": "MIDI",
        "name": "Electric Piano 1"
    }})
    res_d2m = s_view.recv_response(32)
    check("drumkit -> melodic refused",
          res_d2m.get("ok") is True and
          res_d2m.get("result", {}).get("error") == "cannot switch between a drumkit and a melodic instrument; add a new instrument instead")

    # 3d. Unknown name refused
    s_view.send({"id": 33, "op": "tool", "name": "set_instrument", "args": {
        "instrument_index": 0,
        "category": "MIDI",
        "name": "NonexistentVoiceXYZ"
    }})
    res_unk = s_view.recv_response(33)
    check("unknown name refused",
          res_unk.get("ok") is True and
          "error" in res_unk.get("result", {}) and
          "MIDI" in res_unk.get("result", {}).get("error", ""))

    # 3e. Viewer set_instrument on instrument 0 to "Electric Piano 1"
    s_view.send({"id": 34, "op": "tool", "name": "set_instrument", "args": {
        "instrument_index": 0,
        "category": "MIDI",
        "name": "Electric Piano 1"
    }})
    res_set_inst = s_view.recv_response(34)
    ev_sc_ctrl_set = s_ctrl.wait_for_event("song_changed", timeout=4.0)
    check("song_changed event reaches the controller", ev_sc_ctrl_set is not None)

    s_view.send({"id": 35, "op": "tool", "name": "get_song_state", "args": {}})
    res_state = s_view.recv_response(35)
    state_insts = res_state.get("result", {}).get("instruments", [])
    state_pats = res_state.get("result", {}).get("patterns", [])
    inst0_name = state_insts[0].get("name") if len(state_insts) > 0 else ""
    inst0_cat = state_insts[0].get("category") if len(state_insts) > 0 else ""
    notes_preserved = any(any(n.get("note") == 60 and n.get("position") == 0 and n.get("length") == 2 for n in p.get("notes", [])) for p in state_pats if p.get("instrument_index") == 0)
    check("viewer set_instrument on instrument 0 to Electric Piano 1 -> new voice and notes unchanged",
          res_set_inst.get("ok") is True and
          res_set_inst.get("result", {}).get("success") is True and
          res_set_inst.get("result", {}).get("name") == "Electric Piano 1" and
          inst0_name == "Electric Piano 1" and
          inst0_cat == "MIDI" and
          notes_preserved)

    # 3f. set_instrument while playing keeps playing
    s_view.send({"id": 36, "op": "tool", "name": "play_song", "args": {"action": "play"}})
    s_view.recv_response(36)
    s_view.wait_for_event("transport", timeout=3.0)

    s_view.send({"id": 37, "op": "tool", "name": "get_transport", "args": {}})
    r_tr_play1 = s_view.recv_response(37)
    was_playing = r_tr_play1.get("result", {}).get("playing") is True

    s_view.send({"id": 38, "op": "tool", "name": "set_instrument", "args": {
        "instrument_index": 0,
        "category": "MIDI",
        "name": "Bright Piano"
    }})
    r_set_play = s_view.recv_response(38)

    s_view.send({"id": 39, "op": "tool", "name": "get_transport", "args": {}})
    r_tr_play2 = s_view.recv_response(39)
    still_playing = r_tr_play2.get("result", {}).get("playing") is True

    s_view.send({"id": 40, "op": "tool", "name": "play_song", "args": {"action": "stop"}})
    s_view.recv_response(40)
    s_view.wait_for_event("transport", timeout=3.0)
    s_ctrl.drain_events(0.1)
    s_view.drain_events(0.1)

    check("set_instrument while playing keeps playing (get_transport.playing stays true)",
          was_playing and
          r_set_play.get("ok") is True and
          r_set_play.get("result", {}).get("success") is True and
          still_playing)

    # 4. Viewer play_song -> transport events with advancing step/bar, then stop -> playing:false
    s_view.send({"id": 4, "op": "tool", "name": "play_song", "args": {"action": "play"}})
    res_play = s_view.recv_response(4)
    t_start = s_view.wait_for_event("transport", timeout=3.0)
    time.sleep(0.3)
    s_view.drain_events(0.1)
    
    s_view.send({"id": 5, "op": "tool", "name": "play_song", "args": {"action": "stop"}})
    res_stop = s_view.recv_response(5)
    t_stop = None
    t0_stop = time.time()
    while time.time() - t0_stop < 3.0:
        ev = s_view.wait_for_event("transport", timeout=1.0)
        if ev and ev.get("playing") is False:
            t_stop = ev
            break
    check("viewer play_song -> transport events with advancing step/bar, then stop -> playing:false",
          res_play.get("ok") is True and
          t_start is not None and t_start.get("playing") is True and
          res_stop.get("ok") is True and
          t_stop is not None and t_stop.get("playing") is False)

    # 5. Viewer get_transport
    s_view.send({"id": 6, "op": "tool", "name": "get_transport", "args": {}})
    res_tr = s_view.recv_response(6)
    tr = res_tr.get("result", {})
    check("viewer get_transport",
          res_tr.get("ok") is True and
          tr.get("playing") is False and
          tr.get("bpm") == 140 and
          "bar" in tr and "step" in tr and "pattern_size" in tr)

    # 6. Viewer refused save_song / create_song / remove_instrument / shutdown
    s_view.send({"id": 7, "op": "tool", "name": "save_song", "args": {"name": "test"}})
    r_save = s_view.recv_response(7)
    save_refused = r_save.get("result", {}).get("error") == "tool not allowed for viewer"

    s_view.send({"id": 8, "op": "tool", "name": "create_song", "args": {"bpm": 120}})
    r_create = s_view.recv_response(8)
    create_refused = r_create.get("result", {}).get("error") == "tool not allowed for viewer"

    s_view.send({"id": 88, "op": "tool", "name": "remove_instrument", "args": {"instrument_index": 1}})
    r_remove = s_view.recv_response(88)
    remove_refused = r_remove.get("result", {}).get("error") == "tool not allowed for viewer"

    s_view.send({"id": 9, "op": "shutdown"})
    r_shut = s_view.recv_response(9)
    shut_refused = (not r_shut.get("ok")) and ("shutdown not allowed" in r_shut.get("error", ""))

    check("viewer refused save_song / create_song / remove_instrument / shutdown", save_refused and create_refused and remove_refused and shut_refused)

    # 7. A second viewer closed
    s_view2 = Client(port)
    s_view2.send({"op": "hello", "protocol": 1, "secret": viewer_secret, "client": "view-2"})
    r_view2 = s_view2.recv_frame()
    view2_rejected = r_view2.get("ok") is False
    try:
        s_view2.recv_frame(timeout=1.0)
        view2_closed = False
    except (EOFError, socket.error):
        view2_closed = True
    check("a second viewer closed", view2_rejected and view2_closed)

    # Snapshot current song state
    s_ctrl.send({"id": 20, "op": "tool", "name": "snapshot", "args": {}})
    r_snap = s_ctrl.recv_response(20)
    snap_ceol = r_snap.get("result", {}).get("ceol", "")

    # create_song leaves playback stopped
    s_ctrl.send({"id": 21, "op": "tool", "name": "create_song", "args": {"bpm": 120}})
    r_create = s_ctrl.recv_response(21)
    s_ctrl.send({"id": 22, "op": "tool", "name": "get_transport", "args": {}})
    r_tr_create = s_ctrl.recv_response(22)
    tr_create = r_tr_create.get("result", {})
    check("create_song leaves playback stopped",
          r_create.get("ok") is True and
          tr_create.get("playing") is False and
          tr_create.get("step") == 0)

    # load_song (using snapshot ceol) leaves playback stopped
    s_ctrl.send({"id": 23, "op": "tool", "name": "load_song", "args": {"ceol": snap_ceol}})
    r_load = s_ctrl.recv_response(23)
    s_ctrl.send({"id": 24, "op": "tool", "name": "get_transport", "args": {}})
    r_tr_load = s_ctrl.recv_response(24)
    tr_load = r_tr_load.get("result", {})
    check("load_song leaves playback stopped",
          r_snap.get("ok") is True and len(snap_ceol) > 0 and
          r_load.get("ok") is True and
          tr_load.get("playing") is False and
          tr_load.get("step") == 0)

    # play_song play then starts it
    s_ctrl.send({"id": 25, "op": "tool", "name": "play_song", "args": {"action": "play"}})
    r_play_start = s_ctrl.recv_response(25)
    s_ctrl.send({"id": 26, "op": "tool", "name": "get_transport", "args": {}})
    r_tr_play_start = s_ctrl.recv_response(26)
    tr_play_start = r_tr_play_start.get("result", {})
    check("play_song play starts playback",
          r_play_start.get("ok") is True and
          tr_play_start.get("playing") is True)

    # create_song with "autoplay": true plays
    s_ctrl.send({"id": 27, "op": "tool", "name": "create_song", "args": {"bpm": 130, "autoplay": True}})
    r_auto = s_ctrl.recv_response(27)
    s_ctrl.send({"id": 28, "op": "tool", "name": "get_transport", "args": {}})
    r_tr_auto = s_ctrl.recv_response(28)
    tr_auto = r_tr_auto.get("result", {})
    check("create_song with autoplay:true plays",
          r_auto.get("ok") is True and
          tr_auto.get("playing") is True)

    # Stop playback and drain before proceeding
    s_ctrl.send({"id": 29, "op": "tool", "name": "play_song", "args": {"action": "stop"}})
    s_ctrl.recv_response(29)
    s_ctrl.drain_events(0.1)
    s_view.drain_events(0.1)

    # 7b. Real app export_song with format: "wav"
    s_ctrl.send({"id": 70, "op": "tool", "name": "export_song", "args": {"format": "wav", "name": "smoke_real_song"}})
    r_exp_wav = s_ctrl.recv_response(70, timeout=15.0)
    res_wav = r_exp_wav.get("result", {})
    wav_path = res_wav.get("path", "")
    wav_exists = os.path.isfile(wav_path)
    wav_size = os.path.getsize(wav_path) if wav_exists else 0
    wav_hdr = b""
    if wav_exists:
        with open(wav_path, "rb") as wf:
            wav_hdr = wf.read(44)
    has_riff = len(wav_hdr) >= 44 and wav_hdr[:4] == b"RIFF" and wav_hdr[8:12] == b"WAVE"
    check("real app export_song wav produces valid file with non-zero size",
          r_exp_wav.get("ok") is True and wav_exists and wav_size > 1000 and has_riff)

    # 7c. Multi-bar WAV export with playback running (Bug A & Bug B)
    # Build a song with at least 4 bars across 2+ channels
    s_ctrl.send({"id": 110, "op": "tool", "name": "create_song", "args": {"bpm": 120, "pattern_size": 16}})
    s_ctrl.recv_response(110)
    s_ctrl.send({"id": 111, "op": "tool", "name": "add_instrument", "args": {"category": "DRUMKIT", "name": "Simple Drumkit"}})
    r_inst = s_ctrl.recv_response(111)
    inst1 = r_inst.get("result", {}).get("instrument_index", 1)

    # Piano pattern 0 (bars 0, 2)
    s_ctrl.send({"id": 112, "op": "tool", "name": "add_notes", "args": {
        "pattern_index": 0,
        "notes": [
            {"note": 60, "position": 0, "length": 2},
            {"note": 64, "position": 4, "length": 2},
            {"note": 67, "position": 8, "length": 2},
            {"note": 72, "position": 12, "length": 2}
        ]
    }})
    s_ctrl.recv_response(112)

    # Drum pattern 1 (bars 0, 1, 2, 3)
    s_ctrl.send({"id": 113, "op": "tool", "name": "create_pattern", "args": {"instrument_index": inst1}})
    r_pat1 = s_ctrl.recv_response(113)
    pat1 = r_pat1.get("result", {}).get("pattern_index", 1)
    s_ctrl.send({"id": 114, "op": "tool", "name": "add_notes", "args": {
        "pattern_index": pat1,
        "notes": [
            {"note": 36, "position": 0, "length": 1},
            {"note": 38, "position": 4, "length": 1},
            {"note": 36, "position": 8, "length": 1},
            {"note": 38, "position": 12, "length": 1}
        ]
    }})
    s_ctrl.recv_response(114)

    # Piano pattern 2 (bars 1, 3)
    s_ctrl.send({"id": 115, "op": "tool", "name": "create_pattern", "args": {"instrument_index": 0}})
    r_pat2 = s_ctrl.recv_response(115)
    pat2 = r_pat2.get("result", {}).get("pattern_index", 2)
    s_ctrl.send({"id": 116, "op": "tool", "name": "add_notes", "args": {
        "pattern_index": pat2,
        "notes": [
            {"note": 65, "position": 0, "length": 2},
            {"note": 69, "position": 4, "length": 2},
            {"note": 72, "position": 8, "length": 2},
            {"note": 77, "position": 12, "length": 2}
        ]
    }})
    s_ctrl.recv_response(116)

    # Set arrangement with 4 bars across channels 0 and 1
    s_ctrl.send({"id": 117, "op": "tool", "name": "set_arrangement", "args": {
        "entries": [
            {"bar": 0, "channel": 0, "pattern_index": 0},
            {"bar": 0, "channel": 1, "pattern_index": pat1},
            {"bar": 1, "channel": 0, "pattern_index": pat2},
            {"bar": 1, "channel": 1, "pattern_index": pat1},
            {"bar": 2, "channel": 0, "pattern_index": 0},
            {"bar": 2, "channel": 1, "pattern_index": pat1},
            {"bar": 3, "channel": 0, "pattern_index": pat2},
            {"bar": 3, "channel": 1, "pattern_index": pat1},
        ]
    }})
    s_ctrl.recv_response(117)

    # Start playback, wait ~1s, then export wav
    s_ctrl.send({"id": 118, "op": "tool", "name": "play_song", "args": {"action": "play"}})
    s_ctrl.recv_response(118)
    time.sleep(1.0)

    s_ctrl.send({"id": 119, "op": "tool", "name": "export_song", "args": {"format": "wav", "name": "smoke_4bar_play"}})
    r_exp_4bar = s_ctrl.recv_response(119, timeout=25.0)
    res_4bar = r_exp_4bar.get("result", {})
    fmt_4bar, dur_4bar, audio_4bar = parse_wav_info(res_4bar.get("path", ""))

    expected_4bar_sec = 4 * 16 * 15.0 / 120.0  # 8.0s
    dur_4bar_ok = abs(dur_4bar - expected_4bar_sec) <= (0.10 * expected_4bar_sec)

    last_q_bytes = audio_4bar[int(len(audio_4bar) * 0.75):]
    non_silent_count = 0
    for i in range(0, len(last_q_bytes) - 1, 2):
        s = struct.unpack("<h", last_q_bytes[i:i+2])[0]
        if abs(s) > 50:
            non_silent_count += 1
    last_q_has_audio = non_silent_count > 100

    check("whole-song WAV export (while playing) renders ~4 bars (within 10%) and is non-silent in last quarter",
          r_exp_4bar.get("ok") is True and dur_4bar_ok and last_q_has_audio)

    # 7d. Sub-range export (loop_start=1, loop_end=3) is ~2 bars long; arrangement loop preserved
    s_ctrl.send({"id": 120, "op": "tool", "name": "get_song_state", "args": {}})
    r_st_before = s_ctrl.recv_response(120)
    st_before = r_st_before.get("result", {})
    loop_start_before = st_before.get("loop_start")
    loop_end_before = st_before.get("loop_end")

    s_ctrl.send({"id": 121, "op": "tool", "name": "export_song", "args": {
        "format": "wav",
        "name": "smoke_subrange",
        "loop_start": 1,
        "loop_end": 3
    }})
    r_exp_sub = s_ctrl.recv_response(121, timeout=20.0)
    res_sub = r_exp_sub.get("result", {})
    fmt_sub, dur_sub, audio_sub = parse_wav_info(res_sub.get("path", ""))

    expected_sub_sec = 2 * 16 * 15.0 / 120.0  # 4.0s
    dur_sub_ok = abs(dur_sub - expected_sub_sec) <= (0.10 * expected_sub_sec)

    s_ctrl.send({"id": 122, "op": "tool", "name": "get_song_state", "args": {}})
    r_st_after = s_ctrl.recv_response(122)
    st_after = r_st_after.get("result", {})
    loop_start_after = st_after.get("loop_start")
    loop_end_after = st_after.get("loop_end")
    loop_restored = (loop_start_before is not None and
                     loop_start_after == loop_start_before and
                     loop_end_after == loop_end_before)

    check("sub-range export (loop_start=1, loop_end=3) renders ~2 bars and restores arrangement loop",
          r_exp_sub.get("ok") is True and dur_sub_ok and loop_restored)

    # 7e. Invalid ranges are rejected with an error
    invalid_cases = [
        {"loop_start": 3, "loop_end": 1},
        {"loop_start": -1, "loop_end": 2},
        {"loop_start": 0, "loop_end": 10},
        {"loop_start": 2, "loop_end": 2},
        {"loop_start": 1.5, "loop_end": 3},
        {"loop_start": 1, "loop_end": 2.5},
    ]
    invalid_rejected = True
    for idx, case in enumerate(invalid_cases):
        req_id = 130 + idx
        c_args = {"format": "wav", "name": f"smoke_inv_{idx}"}
        c_args.update(case)
        s_ctrl.send({"id": req_id, "op": "tool", "name": "export_song", "args": c_args})
        r_inv = s_ctrl.recv_response(req_id, timeout=5.0)
        res_inv = r_inv.get("result", {})
        has_error = (r_inv.get("ok") is False) or ("error" in res_inv)
        if not has_error:
            invalid_rejected = False

    check("invalid export ranges are rejected with an error", invalid_rejected)

    # 7f. Whole-number float ranges accepted (e.g. 1.0, 3.0 on MIDI export)
    s_ctrl.send({"id": 140, "op": "tool", "name": "export_song", "args": {
        "format": "midi",
        "name": "smoke_float_range",
        "loop_start": 1.0,
        "loop_end": 3.0
    }})
    r_midi = s_ctrl.recv_response(140, timeout=5.0)
    res_midi = r_midi.get("result", {})
    midi_path = res_midi.get("path", "")
    midi_ok = r_midi.get("ok") is True and os.path.isfile(midi_path) and os.path.getsize(midi_path) > 0
    check("whole-number float ranges (1.0, 3.0) accepted on export (MIDI)", midi_ok)

    # 8. Relay: controller answers viewer relay with relay_result and checks no-controller error
    s_view.send({"id": 10, "op": "relay", "action": "save", "args": {"prompt": "smoke test song"}})
    ev_relay = s_ctrl.wait_for_event("relay_request", timeout=3.0)
    rid = ev_relay.get("rid") if ev_relay else -1
    
    s_ctrl.send({"op": "relay_result", "rid": rid, "ok": True, "result": {"id": "smoke-log-1", "saved": True}})
    res_relay = s_view.recv_response(10)
    relay_happy = (res_relay.get("ok") is True and res_relay.get("result", {}).get("id") == "smoke-log-1")

    # Disconnect controller and verify no_controller error
    s_ctrl.close()
    s_ctrl = None
    time.sleep(0.2)

    s_view.send({"id": 11, "op": "relay", "action": "save", "args": {"prompt": "after disconnect"}})
    res_relay_no_ctrl = s_view.recv_response(11)
    no_ctrl_ok = (res_relay_no_ctrl.get("ok") is False and res_relay_no_ctrl.get("error") == "no_controller")
    check("relay answered by controller and no-controller error on disconnect", relay_happy and no_ctrl_ok)

    # 9. Controller shutdown quits the app (exit 0) without hanging on popup even with a dirty song
    s_ctrl2 = Client(port)
    s_ctrl2.send({"op": "hello", "protocol": 1, "secret": secret, "client": "smoke-ctrl-2"})
    r_ctrl2 = s_ctrl2.recv_frame()

    s_ctrl2.send({"id": 99, "op": "shutdown"})
    r_shutdown = s_ctrl2.recv_response(99)
    proc.wait(timeout=5.0)
    clean_exit = (proc.returncode == 0)
    check("controller shutdown quits the app (exit 0) without hanging on popup",
          r_shutdown.get("ok") is True and clean_exit)

except Exception as ex:
    print(f"Exception during smoke test: {ex}", file=sys.stderr)
    import traceback
    traceback.print_exc()
    if os.path.exists(log_path):
        with open(log_path) as lf:
            print("=== APP LOG ===")
            print(lf.read())
            print("===============")

finally:
    cleanup()
    print(f"REAL_APP_SMOKE: checks={checks} passed={passed}")
    sys.exit(0 if (checks > 0 and checks == passed) else 1)
