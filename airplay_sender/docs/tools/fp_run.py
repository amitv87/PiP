#!/usr/bin/env python3
"""
Attach to the frida-gadget injected into com.softmedia.receiver.lite and load fp_hook.js.

Prereqs:
  - the receiver was re-packaged with the gadget (see moto-softmedia-receiver-re.md §4)
  - adb -s <device> forward tcp:27042 tcp:27042
  - frida 17.x  (pip install frida)

Usage:
  python3 fp_run.py [path/to/fp_hook.js]

The gadget runs in on_load:resume mode, so the app is already running; we just attach and
load the script. A liveness ping proves the session stays connected during the mirror.
"""
import frida, time, sys, os

HOOK = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "fp_hook.js")

dev = frida.get_device_manager().add_remote_device("127.0.0.1:27042")
ps = dev.enumerate_processes()
cand = [p for p in ps if p.name in ("Gadget", "com.softmedia.receiver.lite")] or ps
gpid = cand[0].pid
print("[runner] attaching to pid %d (%s)" % (gpid, cand[0].name), flush=True)

session = dev.attach(gpid)
session.on("detached", lambda reason, *a: print("[runner] *** SESSION DETACHED: %s ***" % reason, flush=True))

def on_message(m, data):
    t = m.get("type")
    if t == "log":
        print(m["payload"], flush=True)
    elif t == "send":
        print("[send]", m["payload"], flush=True)
    elif t == "error":
        print("[error]", m.get("stack") or m.get("description"), flush=True)

script = session.create_script(open(HOOK).read())
script.on("message", on_message)
script.load()
print("[runner] HOOK LOADED -- start the macOS mirror now", flush=True)

n = 0
while True:
    time.sleep(4); n += 1
    try:
        print("[runner] ping#%d ok: %s" % (n, script.exports_sync.ping()), flush=True)
    except Exception as e:
        print("[runner] ping#%d FAILED: %r" % (n, e), flush=True)
