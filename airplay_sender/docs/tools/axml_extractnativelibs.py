#!/usr/bin/env python3
"""
Flip application android:extractNativeLibs (resId 0x010104ea) false -> true in a binary
AndroidManifest.xml (compiled AXML). Needed so the injected frida-gadget + its config file
extract to disk and become discoverable (see moto-softmedia-receiver-re.md section 4).

Usage:
  # extract the manifest from the base apk, flip it, put it back, then zipalign + re-sign:
  unzip -p base.apk AndroidManifest.xml > AM.bin
  python3 axml_extractnativelibs.py AM.bin AM_patched.bin
  ( cd manifest_dir && zip base.apk AndroidManifest.xml )   # AM_patched.bin as AndroidManifest.xml

Parses the AXML string pool + resource map to locate the extractNativeLibs attribute robustly
(no fragile byte scanning), asserts exactly one match, and sets its TYPE_INT_BOOLEAN data to true.
"""
import sys, struct

RESID_EXTRACT_NATIVE_LIBS = 0x010104ea
STRING_POOL, RES_MAP, START_ELE = 0x0001, 0x0180, 0x0102

def main(inp, out):
    d = bytearray(open(inp, "rb").read())
    assert struct.unpack_from("<I", d, 0)[0] == 0x00080003, "not compiled AXML"
    total = struct.unpack_from("<I", d, 4)[0]

    resmap = None
    elements = []          # (name_str_idx, attr_count, attrs_off)
    off = 8
    while off + 8 <= total:
        ctype, chdr, chsize = struct.unpack_from("<HHI", d, off)
        if chsize < 8:
            break
        if ctype == RES_MAP:
            cnt = (chsize - 8) // 4
            resmap = [struct.unpack_from("<I", d, off + 8 + i*4)[0] for i in range(cnt)]
        elif ctype == START_ELE:
            # chunk hdr(8) + node[line,comment](8) + attrExt[ns,name,attrStart,attrSize,attrCount,...]
            name = struct.unpack_from("<i", d, off + 20)[0]
            attrStart, attrSize, attrCount = struct.unpack_from("<HHH", d, off + 24)
            elements.append((name, attrCount, off + 16 + attrStart))
        off += chsize

    assert resmap is not None, "no resource-map chunk"
    enl_idx = next((i for i, r in enumerate(resmap) if r == RESID_EXTRACT_NATIVE_LIBS), None)
    assert enl_idx is not None, "extractNativeLibs resId not in resource map"

    found = []
    for (_ename, acount, aoff) in elements:
        for a in range(acount):
            ao = aoff + a*20
            a_name = struct.unpack_from("<i", d, ao + 4)[0]
            size, res0, typ = struct.unpack_from("<HBB", d, ao + 12)
            data = struct.unpack_from("<i", d, ao + 16)[0]
            if a_name == enl_idx:
                found.append((ao, typ, data & 0xffffffff))

    assert len(found) == 1, "expected exactly 1 extractNativeLibs attr, got %d" % len(found)
    ao, typ, data = found[0]
    assert typ == 0x12, "extractNativeLibs is not TYPE_INT_BOOLEAN"
    print("extractNativeLibs @0x%x currently 0x%08x (0=false)" % (ao, data))

    struct.pack_into("<i", d, ao + 16, -1)   # data     = 0xffffffff (true)
    struct.pack_into("<i", d, ao + 8,  -1)   # rawValue = 0xffffffff
    open(out, "wb").write(d)
    print("flipped extractNativeLibs -> true, wrote %s" % out)

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(1)
    main(sys.argv[1], sys.argv[2])
