# Motorola SoftMedia AirPlay Receiver — Reverse-Engineering Notes

Findings from reverse-engineering the **Motorola "AirReceiver Lite" / SoftMedia** AirPlay
receiver (`com.softmedia.receiver.lite`) to understand why PiP's encrypted screen mirroring
does not work with it, and exactly how the receiver derives its video-decryption key.

- **Target:** `com.softmedia.receiver.lite` v5.1.7, native engine `lib/arm64-v8a/libAirReceiver.so`
  (11 MB, stripped, statically-bundled BoringSSL). BuildId `80d645cd65962da8cf1c9debb85c4b935a15507b`.
- **Device used:** Motorola Edge 50 Pro, Android 15 (arm64), non-rooted.
- **Method:** static RE (Ghidra) + live dynamic capture (frida-gadget injected into a re-signed APK).
- **All addresses** below are Ghidra addresses at image base `0x100000`. The on-disk / runtime
  `.so` file offset = `Ghidra_addr − 0x100000` (the first `PT_LOAD` is RX at vaddr 0 / file off 0,
  so `file_offset == vaddr`). At runtime, frida's `Module.base` is the vaddr-0 load bias, so
  `runtime_addr = module.base + (Ghidra_addr − 0x100000)`.

> TL;DR: The receiver uses **standard AirPlay-1 (AppleTV3,2) FairPlay + AES-128-CTR**. Every step
> of the key schedule is the well-known UxPlay/RPiPlay scheme **except** the FairPlay `ekey→aes_key`
> unwrap, which is a context-dependent whitebox. That single unwrap is the only thing PiP cannot
> reproduce — it is the sole blocker for encrypted mirroring. `PIP_NOENC` (unencrypted) already
> works with this receiver and remains the shipped path.

---

## 1. The encrypted-mirror key chain (the main result)

Captured **live** from a real macOS→Moto screen-mirror session (macOS Control Center → Screen
Mirroring → the receiver). macOS uses FairPlay, `X-Apple-ET: 32` — **not** the legacy RSA path,
**not** unencrypted.

```
POST /fp-setup RTSP/1.0   (X-Apple-ET: 32)              handler FUN @ base+0x6ab478
      │
   SETUP  (parsed by FUN_0052e2d0 @ 0x42e2d0):
      ├─ et                = 32            (int field, via FUN_00877414 @ 0x777414)
      ├─ eiv               = 16B           (data field, via FUN_00877480 @ 0x777480)
      ├─ ekey              = 72B  DENSE    (data field) — "FPLY" header + dense body
      ├─ type              = 110           (marks the video stream)
      └─ streamConnectionID = uint64       (int field)
      │
   ekey ──► FairPlay unwrap  FUN_005c9ebc @ 0x4c9ebc
      │        copies ekey to fp_ctx+0x135, calls FUN_0064dfdc @ 0x54dfdc which loads a
      │        276-BYTE fp-setup session context and runs the whitebox → 16B aes_key
      ▼
   aes_key (16B)          ← also scheduled *unmixed* as an AES decrypt key (audio/control)
      │
      │   ***** THE VIDEO-KEY KDF (cracked, exact) *****
      │   video_key = SHA512( "AirPlayStreamKey" ++ ascii_decimal(streamConnectionID) ++ aes_key )[:16]
      ▼
   video_key (16B)
      │   AirTunesScreenStream thread FUN_005352f0 @ 0x4352f0 holds it at ctx+0xd2;
      │   decryptor ctor FUN_005171a0 @ 0x4171a0 copies key → AES_set_encrypt_key(…,128,…) @ 0x7b6de8
      ▼
   video frames decrypted with AES-128-CTR  →  CRYPTO_ctr128_encrypt @ 0x865b14
```

### The KDF, precisely

```
video_key = SHA512( b"AirPlayStreamKey" + str(streamConnectionID).encode() + aes_key )[0:16]
```

- `"AirPlayStreamKey"` — the 16-byte ASCII label, **built at runtime** (that's why a static string
  search for it in the `.so` finds nothing).
- `streamConnectionID` — formatted as a **decimal ASCII string** (e.g. `"9215987514089229813"`).
- `aes_key` — the 16-byte FairPlay-unwrapped key.

This is exactly the UxPlay / RPiPlay `mirror_buffer` stream-key derivation. Because PiP chooses
`streamConnectionID` and SHA-512 is trivial, **PiP can compute `video_key` itself the instant it
holds the correct `aes_key`.**

### Byte-for-byte verification

One captured session (keys are ephemeral, per-session — shown only as a worked example):

| field | value |
|---|---|
| `ekey` (72B) | `46504c59010201000000003c00000000 4b8bd61fd0a2f0183fdc2af3bd9f02cc 00000010 18e1dd025c62638ad2dd39e5179a70b3 787ad6f34d7fa1086a052971623d7b49 0f16a0a5` |
| `eiv` (16B) | `595eca16fa4193d21cdb82c800d3fe30` |
| `streamConnectionID` | `9215987514089229813` (`0x7fe5c3d0cfb94df5`) |
| `aes_key` (unwrap out) | `324858bba3d71b72792a4ed31d0fb56d` |
| **`video_key`** (AES key set) | `b95abca171f8fdc59b8e2c27d9fcb708` |

Check: `SHA512("AirPlayStreamKey" + "9215987514089229813" + 324858bb…)[:16] == b95abca1…` ✓

Note on the CTR hook: reading the key from `CRYPTO_ctr128_encrypt`'s `AES_KEY*` argument gives it
with **each 32-bit word byte-swapped** (BoringSSL `rd_key` layout), e.g. `b95abca1…` shows up as
`a1bc5ab9…`. `AES_set_encrypt_key`'s `userKey` argument is the natural key. Use the latter.

### Why the fake-ekey trick fails here

PiP / airfry / doubletake establish the FairPlay key with a **fake sparse ekey** and set
`aes_key = playfair_decrypt(m3, ekey)`, relying on both ends computing the same. Real Apple TVs /
HAP receivers reduce to that reverse-engineered `playfair` when the middle bytes are zero. The
SoftMedia receiver instead runs a **context-dependent whitebox over the DENSE ekey** (fed the
276-byte fp-setup session state), so given PiP's sparse ekey it derives a **different** `aes_key`,
and every downstream key/IV is therefore wrong. See `moto-fairplay-fake-ekey-incompatible` notes.

---

## 2. Key function map

FairPlay / stream (the interop-relevant path):

| Ghidra | .so off | Symbol / role |
|---|---|---|
| `0x52e2d0` | `0x42e2d0` | `FUN_0052e2d0` RTSP SETUP handler (parses et/ekey/eiv/type/timingPort) |
| `0x877480` | `0x777480` | plist **data**-field extractor `(val,&buf,&len)` → eiv, ekey |
| `0x877414` | `0x777414` | plist **integer** extractor `(val,&i64)` → et, type, streamConnectionID |
| `0x5c9ebc` | `0x4c9ebc` | FairPlay unwrap wrapper `FUN_005c9ebc(fp_ctx,ekey,len,&out,&outlen)` |
| `0x64dfdc` | `0x54dfdc` | real decrypt `FUN_0064dfdc` (loads 276B fp-setup ctx, runs whitebox) |
| `0x5352f0` | `0x4352f0` | `AirTunesScreenStream` — video-stream thread; video key at ctx+0xd2 |
| `0x5171a0` | `0x4171a0` | video-decryptor ctor → `AES_set_encrypt_key(userKey,128,…)` |
| `0x8b6de8` | `0x7b6de8` | `AES_set_encrypt_key` (schedules the video key; `userKey`=arg0) |
| `0x965b14` | `0x865b14` | `CRYPTO_ctr128_encrypt` (AES-128-CTR video decrypt; key=arg3, ctr=arg4) |
| `0x98278c` | `0x88278c` | `RSA_private_decrypt` (et==2 legacy path — **not** used by macOS here) |
| `0x991074` | `0x891074` | `SHA512` (BoringSSL) |

Anti-tamper framework (see §3):

| Ghidra | .so off | Role |
|---|---|---|
| `0x57ce38` | `0x47ce38` | integrity-checker singleton getter (`FUN_0057ce38`) |
| `0xa43fa0` | — | checker vtable (its entries 0x08,0x10,0x38..0x60 are the ~8 check methods) |
| `0x57eb70` / `0x57edb8` | | signature `memcmp` checks (build `.castapp`/`.dock`/`.alpine` identity strings) |
| `0x57f738` | `0x47f738` | root check: `return -(getuid()==0)` |
| `0x57fbbc` | `0x47fbbc` | **watchdog** loop (re-runs checks forever, ~60s `usleep`) |
| `0x57cef0` | `0x47cef0` | abort-task ctor: `field+8 = rand()` (poison), vtable `0xa44020` |
| `0x57d020` | `0x47d020` | scheduler: `pthread_create(…, FUN_0057cf48, task)` (spawns Thread-4) |
| **`0x57cf84`** | **`0x47cf84`** | **abort-task run method — the poison deref. PATCH TARGET.** |

---

## 3. Defeating the anti-tamper (required to instrument it)

The receiver cannot simply be re-signed: `libAirReceiver.so` runs a native integrity-check
**framework** on Thread-4 (startup + a periodic watchdog). On any failure it builds a disguised
"abort task" whose run method `FUN_0057cf84` dereferences a `rand()`-poisoned pointer, crashing
with `SIGSEGV, fault addr 0x6b8b4567` (`rand()`'s first output under the default seed). The crash
is deliberately deferred/obfuscated to look like random memory corruption, and it re-fires from the
watchdog. The **original developer signature runs fine; any re-sign (even byte-identical) trips it.**

**Bypass = ONE 4-byte patch.** All check failures funnel through `FUN_0057cf84`, and it is the sole
dereferencer of the poison, so neutralize it:

```
file offset 0x47cf84 :  fd7bbea9…   →   c0035fd6            ( ret )
                                  (or  00008052 c0035fd6    mov w0,#0 ; ret )
```

Every abort task then runs and returns harmlessly. This is self-consistent even against a
`.text`-integrity check: detecting the patch can only *schedule an abort task*, which is now inert.
Defeats the startup checks and the watchdog. Verified: app runs re-signed, stable past 60s, the
`AirReceiverService` comes up normally.

---

## 4. Injecting frida-gadget (to capture live keys)

`extractNativeLibs` is **false** in 5.1.7 (libs mmapped straight from the split APK), which breaks
the gadget's on-disk config discovery. Recipe that works end-to-end:

1. **Unpack** the xapk: base APK + `config.arm64_v8a.apk` (+ `config.xxhdpi`, `config.en`).
2. **Patch `libAirReceiver.so`** (in-place, size-preserving):
   - tamper bypass at file `0x47cf84` (see §3).
   - inject the gadget as a `DT_NEEDED`: repurpose the redundant `DT_HASH` dynamic entry
     (file `0x979c98`; GNU_HASH is present so DT_HASH is unused) → `DT_NEEDED` with
     `val = 0x34f58`, which is the `ffmpeg.so` suffix of the existing `libvplayer_ffmpeg.so`
     string in `.dynstr` (avoids resizing `.dynstr`).
3. **Flip `extractNativeLibs` → true** in the base `AndroidManifest.xml` (binary AXML:
   `extractNativeLibs` is resId `0x010104ea`; set its bool attr `data` (and rawValue) to
   `0xffffffff`). Now libs extract to disk so the gadget + its config are discoverable.
4. **Add** to the arm64 split's `lib/arm64-v8a/`:
   - `ffmpeg.so` = the frida-gadget (arm64), named to match the injected `DT_NEEDED`.
   - `ffmpeg.config.so` = `{"interaction":{"type":"listen","address":"127.0.0.1","port":27042,"on_load":"resume"}}`
     (`on_load: resume` so the gadget never blocks the main thread).
5. **Re-sign** base + arm64 + xxhdpi + en with one key, `adb install-multiple`.
6. `adb forward tcp:27042 tcp:27042`; connect frida (17.x):
   `frida.get_device_manager().add_remote_device('127.0.0.1:27042')`. The gadget logs
   `Frida: Listening on 127.0.0.1 TCP port 27042`.

Gotchas learned the hard way:
- A **duplicate mDNS adb transport** silently breaks `adb forward` (detaching the frida session and
  removing all hooks). Always `adb -s <ip:port> …` and drop the mDNS transport.
- Frida 17 removed `Module.findExportByName`; use `Module.getGlobalExportByName`.
- `Stalker.follow` on all ~49 threads during live video **crashes the app** (it restarts cleanly
  thanks to the tamper bypass). Prefer targeted hooks + backtraces over whole-process Stalker.

Tooling lives in [`tools/`](tools/): `fp_hook.js` (the capture hook), `fp_run.py` (the runner),
`patch_libairreceiver.py` (tamper + DT_NEEDED), `axml_extractnativelibs.py` (manifest flip).

---

## 5. Running the receiver's FairPlay offline (the oracle)

Every step of the receiver's key schedule is standard AirPlay **except** `ekey → aes_key`
(the context-dependent dense-ekey FairPlay whitebox). The whitebox is deliberately un-reversible,
so instead of re-deriving it we **run the receiver's own code** — the same idea PiP already uses in
[`fpemu/`](../fpemu) to run Apple's blob for m3.

[`tools/moto_fairplay.py`](tools/moto_fairplay.py) does this in Unicorn and reproduces the entire
FairPlay exchange **byte-for-byte** against the live device:

```
MotoFairPlay.derive(ctx0, m1, m3, ekey) -> (m2, m4, aes_key)
```

- init fp_ctx (`ctx0`) → `FUN_005c9b08(m1)` → **m2** → `FUN_005c9b08(m3)` → **m4** → the 276-byte
  `context276` is built in the fp_ctx → `FUN_005c9ebc(ekey)` → **aes_key**. All validated equal to
  the receiver's real m2/m4/aes_key, across sessions.

### The harness recipe (what makes it work)

1. **Map** `libAirReceiver.so` at the **snapshot's base** so the snapshot's absolute pointers stay
   valid; apply `R_AARCH64_RELATIVE` relocations for code-referenced data.
2. **Overlay a PRE-handshake `.data/.bss` snapshot.** The whitebox's key-material tables are computed
   at init (not in the file), so a live snapshot is required. It MUST be captured **before** the
   handshake (at the first `FUN_005c9b08` call): the handshake mutates global state m1→m3, so a
   post-m3 snapshot corrupts a re-run. The snapshot is session-independent — capture once, reuse.
3. **Re-point import GOT slots at Python stubs** (`malloc`/`memcpy`/`memset`/`pthread_*`) *after* the
   overlay (the snapshot holds live-libc addresses that would otherwise win).
4. **Neutralize the anti-tamper check woven into the unwrap:** `FUN_0057ce38` (the checker-singleton
   getter) returns a live-heap object we don't have — intercept it and return a fake object whose
   vtable entries all `ret 0` (untampered).
5. Set `TPIDR_EL0` + a stack canary; the same fp_ctx object flows through handshake and unwrap.

Performance: ~10 s/call in Python-Unicorn (range-scope the code hooks to the stub/checker addresses,
not per-instruction — that alone is an 8× speedup). Native execution on Apple-Silicon would be ~ms.

### Turning this into encrypted PiP mirroring

The fix in [`../fairplay_client.c`](../fairplay_client.c) is surgical: for the SoftMedia receiver,
replace `playfair_decrypt(m3, ekey)` with `MotoFairPlay.derive(...)→aes_key` using the *same* m1/m3
PiP sends. Both sides then compute the identical `aes_key`; PiP derives `video_key` via the SHA-512
KDF (§1) and encrypts. Three ways to ship it, not yet wired in (`PIP_NOENC` remains the default):

- **Hardcode** — the handshake is deterministic (no `rand`), so fixed `m1`/`m3`/`ekey` → fixed
  `aes_key`; precompute once and bake in. Trivial runtime; tied to this `.so` version.
- **Native arm64 runtime** — load the `.so` and call its FairPlay natively on Apple-Silicon
  (Unicorn as x86 fallback). Fast + general; needs a mach-o-style loader + the base-map solved.
- **Embedded Unicorn** — bundle Unicorn + port the harness to C. General; ~seconds/connect.

---

## 6. Reproducing / tooling index

| file | purpose |
|---|---|
| [`tools/moto_fairplay.py`](tools/moto_fairplay.py) | **the oracle** — runs the receiver's FairPlay offline in Unicorn; `derive(ctx0,m1,m3,ekey)→(m2,m4,aes_key)` |
| [`tools/fp_snapshot.js`](tools/fp_snapshot.js) | frida hook: capture the PRE-handshake `.data/.bss`, `ctx0`, m1/m2/m3/m4, ekey, aes_key in one session |
| [`tools/fp_snaprun.py`](tools/fp_snaprun.py) | runner for `fp_snapshot.js` — saves the snapshot blobs to `snap_*.bin` |
| [`tools/fp_hook.js`](tools/fp_hook.js) | frida hook: SETUP fields, unwrap (ekey→aes_key + 276B ctx), SHA/AES key set, CTR key, streamConnectionID |
| [`tools/fp_run.py`](tools/fp_run.py) | frida runner: attach to the gadget on 127.0.0.1:27042, load a hook, liveness ping |
| [`tools/patch_libairreceiver.py`](tools/patch_libairreceiver.py) | patch `libAirReceiver.so`: tamper bypass (0x47cf84→ret) + `DT_HASH`→`DT_NEEDED(ffmpeg.so)` |
| [`tools/axml_extractnativelibs.py`](tools/axml_extractnativelibs.py) | flip `extractNativeLibs`→true in the binary `AndroidManifest.xml` |

**Assets (not committed — third-party / large):** the oracle needs `libAirReceiver.so` (from the
APK) and the captured `snap_rw1.bin`/`snap_rw2.bin` pre-handshake snapshot + `snap_ctx0.bin`. These
are `.gitignore`d like PiP's `fpemu/fp_blob.bin`; regenerate them with `fp_snapshot.js` + the recipe
above. No Apple proprietary material is included here.
