#!/usr/bin/env python3
"""
Patch com.softmedia.receiver.lite's libAirReceiver.so (v5.1.7, arm64, BuildId 80d645cd) so it:
  (1) survives being re-signed  -- neutralize the anti-tamper (FUN_0057cf84 -> ret), and
  (2) auto-loads the frida-gadget -- repurpose the redundant DT_HASH dynamic entry into a
      DT_NEEDED pointing at "ffmpeg.so" (a suffix of the existing "libvplayer_ffmpeg.so"
      string in .dynstr, so no .dynstr resize is needed).

See moto-softmedia-receiver-re.md sections 3 and 4.

Usage:
  python3 patch_libairreceiver.py in/libAirReceiver.so out/libAirReceiver.so

Then: name the frida-gadget "ffmpeg.so" and place it (+ "ffmpeg.config.so") next to this .so in
the arm64 split, flip extractNativeLibs->true (axml_extractnativelibs.py), re-sign, install.
Offsets are file offsets (== Ghidra addr - 0x100000; first PT_LOAD is RX at vaddr0/off0).
"""
import sys, struct, shutil

TAMPER_OFF   = 0x47cf84                                   # FUN_0057cf84 entry (abort-task run)
RET0         = bytes([0x00,0x00,0x80,0x52, 0xc0,0x03,0x5f,0xd6])  # mov w0,#0 ; ret
DT_HASH_ENTRY= 0x979c98                                   # a redundant DT_HASH (GNU_HASH present)
FFMPEG_SUFFIX= 0x34f58                                    # .dynstr offset of "ffmpeg.so"
DT_NEEDED    = 1

def main(src, dst):
    shutil.copyfile(src, dst)
    d = bytearray(open(dst, "rb").read())
    assert d[:4] == b"\x7fELF", "not an ELF"

    # (1) tamper bypass
    old = bytes(d[TAMPER_OFF:TAMPER_OFF+8])
    assert old[:4] == bytes([0xfd,0x7b,0xbe,0xa9]), \
        "unexpected prologue at 0x%x: %s (wrong build?)" % (TAMPER_OFF, old.hex())
    d[TAMPER_OFF:TAMPER_OFF+8] = RET0
    print("  tamper : .so 0x%x  %s -> %s (ret)" % (TAMPER_OFF, old.hex(), RET0.hex()))

    # (2) DT_HASH -> DT_NEEDED(ffmpeg.so)
    tag, val = struct.unpack_from("<qQ", d, DT_HASH_ENTRY)
    assert tag == 4, "entry at 0x%x is not DT_HASH (tag=%d)" % (DT_HASH_ENTRY, tag)
    struct.pack_into("<qQ", d, DT_HASH_ENTRY, DT_NEEDED, FFMPEG_SUFFIX)
    # sanity: confirm the string it now points at
    strtab = 0x4f9cc
    end = d.index(b"\0", strtab + FFMPEG_SUFFIX)
    name = d[strtab+FFMPEG_SUFFIX:end].decode()
    assert name == "ffmpeg.so", "DT_NEEDED points at %r, not 'ffmpeg.so'" % name
    print("  needed : entry@0x%x  DT_HASH -> DT_NEEDED('%s')" % (DT_HASH_ENTRY, name))

    open(dst, "wb").write(d)
    print("wrote %s" % dst)

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(1)
    main(sys.argv[1], sys.argv[2])
