#!/usr/bin/env python3
# Runner for fp_snapshot.js: saves the binary snapshot blobs to emu/snap_*.bin
import frida, time, os
EMU = os.path.dirname(os.path.abspath(__file__))
HOOK = "/Volumes/awsm/tmp/fp_snapshot.js"

dev = frida.get_device_manager().add_remote_device("127.0.0.1:27042")
gpid = [p.pid for p in dev.enumerate_processes() if p.name in ("Gadget","com.softmedia.receiver.lite")][0]
print("[snaprun] attaching pid", gpid, flush=True)
s = dev.attach(gpid)
meta = {}
def on_message(m, data):
    if m.get("type") == "send":
        p = m["payload"]; t = p.get("t")
        if t == "base":
            meta["base"] = p["base"]; open(EMU+"/snap_base.txt","w").write(p["base"])
            print("[snaprun] base", p["base"], flush=True)
        elif t and t!="base" and data is not None:
            open(EMU+"/snap_%s.bin"%t,"wb").write(data)
            print("[snaprun] saved snap_%s.bin (%d bytes) %s"%(t,len(data),
                  {k:v for k,v in p.items() if k!='t'}), flush=True)
    elif m.get("type") == "error":
        print("[error]", m.get("stack") or m.get("description"), flush=True)
    else:
        print(m.get("payload"), flush=True)
sc = s.create_script(open(HOOK).read()); sc.on("message", on_message); sc.load()
print("[snaprun] loaded -- mirror now", flush=True)
while True: time.sleep(2)
