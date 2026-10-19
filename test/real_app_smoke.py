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
    t_stop = s_view.wait_for_event("transport", timeout=3.0)
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

finally:
    cleanup()
    print(f"REAL_APP_SMOKE: checks={checks} passed={passed}")
    sys.exit(0 if (checks > 0 and checks == passed) else 1)
