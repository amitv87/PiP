# Remote Access via Tailscale Funnel — Plan & Architecture

> Status: **planning / architecture only** (no implementation yet).
> Goal: let users watch PiP's live HLS stream from **outside the local network**, **without opening router ports**, using **Tailscale Funnel** — with the app able to turn remote access on/off and manage authorized users.

This document was drafted with a second design pass from Codex (edge cases / failure modes).

---

## 1. Context & the one constraint that shapes everything

PiP captures a screen/window and serves it as live HLS from a tiny built-in HTTP server.

Verified facts about the current server (`pip/stream_server.m` / `stream_server.h`):

- Custom GCD-based HTTP server, plain **HTTP/1.1**, **`Connection: close`** — i.e. **one request per TCP connection** (HTTP/1.0-style; see `process_http_request()` and `send_response()`).
- Binds to **0.0.0.0**, default port **8080** (configurable via the `stream_port` preference).
- Routes: `GET /` (viewer HTML), `/stream.m3u8` (live playlist), `/segment_N.ts` (MPEG-TS segments), `/hls.min.js`, `/status` (JSON). **No authentication anywhere.** Sends `Access-Control-Allow-Origin: *`.
- Only `GET` / `HEAD` are accepted (everything else → 405). **There is no request-body parsing today.**
- Connection counters exist (`stream_server_get_connection_count()`, `stream_server_is_running()`) but count ephemeral TCP connections, not viewers.
- Preferences use an `OPTION(...)` macro stored in `NSUserDefaults` (flat key/value). Keychain is available.

**The shaping constraint:** an HLS viewer is **not "a connection."** The player *polls* — it re-fetches `/stream.m3u8` every segment-duration (~2–4 s, given PiP's low-latency tuning) and pulls `/segment_N.ts` files, each on a separate short-lived connection. Therefore:

- "One connection per user" must mean **one active *viewing session* per user**, enforced by a **session layer above HTTP**, never by counting TCP connections. `stream_server_get_connection_count()` is useless for this.

**Second shaping fact:** with Funnel, **the node's own `tailscaled` terminates TLS** (Tailscale's relay cannot decrypt the traffic) and then proxies plain HTTP to PiP's local server. So the browser-facing leg is HTTPS while PiP sees HTTP from local `tailscaled`. This affects cookies and redirects (see §7).

> **Scope note:** Tailscale Funnel is intended for **low-volume personal use** (fair-use bandwidth), not high-volume video to many viewers. This design assumes a **small number of concurrent authorized viewers** — which the one-session-per-user limit (§5) reinforces, and which also keeps Funnel bandwidth reasonable.

---

## 2. Decisions confirmed (product owner)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Authentication | **Per-user username + password.** PiP serves a login page that sets a session cookie. |
| 2 | Concurrency | **One concurrent session per user.** Second device → **take over** (see #6). |
| 3 | Tailscale install | **Standalone `tailscaled`** → control Funnel by shelling out to the `tailscale` CLI. |
| 4 | Scheduling | **Duration-from-enable, always required.** Enabling a user sets `expiresAt = now + duration`. **No indefinite users.** |
| 5 | Second device | **Take over** — the new device wins; the previous session is invalidated and shown "signed in elsewhere." Avoids lockout from a crashed/closed tab. |
| 6 | On quit | **Turn Funnel off on quit** by default (a pref can opt into keeping it on). |
| 7 | Management UI access | **Rely on the macOS local user** — no separate app-level admin PIN. |

### Defaults adopted from the design pass (flagged for review — see §10)

- **Re-enable vs extend:** "Enable for [duration]" sets `expiresAt = now + duration` (fresh window); a separate **"Extend +[duration]"** action adds to the current expiry. Does not silently stack.
- **Session persistence:** sessions are **ephemeral / in-memory** — all sessions are invalidated when PiP restarts. (Public exposure makes this a feature.) Expected consequence: a remote viewer is dropped to "session expired" on every app restart/update and must log in again — surface this as normal behavior, not a bug.
- **Public Funnel port:** default **443** (clean URL, no `:port`), falling back to **8443 / 10000** if 443 is already mapped on the node.

---

## 3. Funnel control lifecycle

### 3.1 Capability detection (gate the toggle on these)

Run in order; each gate has a specific user-facing remedy:

1. **Binary present** — resolve the `tailscale` path explicitly. A GUI-launched app inherits a **minimal PATH**, so never rely on bare `tailscale`. Probe, in order:
   - `osascript -e 'POSIX path of (path to application "Tailscale")'` → `…/Contents/MacOS/Tailscale`
   - `/Applications/Tailscale.app/Contents/MacOS/Tailscale`
   - standalone `/usr/local/bin/tailscale`
   - Homebrew `/opt/homebrew/bin/tailscale`
   - Fallback for custom installs: `/bin/zsh -lc 'which tailscale'` (a login shell picks up the user's real PATH).
   - Missing → remedy "Tailscale not found."
2. **Daemon running & logged in** — `tailscale status --json` → `BackendState == "Running"` and `Self.Online == true`. Remedies: "Tailscale is not running" / "Log in to Tailscale."
3. **Funnel-capable** — the node needs the **`funnel` nodeAttr** in the tailnet policy, **plus MagicDNS and HTTPS certificates enabled** for the tailnet (there is no `https` nodeAttr — that was a misnomer). The CLI may also drive an **admin consent flow** the first time. There is no clean pre-flight query; the pragmatic path is to **attempt enable and parse the CLI error** (it returns a descriptive message + a setup URL). Surface that text and an "Open Tailscale admin" link.

### 3.2 Enable / disable

- **Run Funnel as an HTTP reverse proxy to a local HTTP target** (`http://127.0.0.1:<stream_port>`), **not** as a raw TCP funnel. This is a deliberate design choice: in HTTP-proxy mode tailscaled injects **`X-Forwarded-For`** (real client IP) and **`X-Forwarded-Proto: https`**, which we rely on for rate-limiting (§7) and for correct `Secure` cookies / redirects (§7). A raw TCP funnel provides neither.
- **Port mapping:** Funnel only accepts public ingress on **443 / 8443 / 10000**. PiP's server is on `stream_port` (default 8080), so Funnel proxies a public port to the local one.
- **CLI surface is version-fragile — code to the *contract*, not a fixed command.** The exact `tailscale serve` / `tailscale funnel` invocation has changed across releases. Define the contract as: *"register an HTTPS funnel on one of 443/8443/10000 forwarding to `http://127.0.0.1:<stream_port>`; tear down by turning that port off."* The implementation should detect the CLI version (`tailscale version`) and branch, or drive the `serve`/`funnel` JSON config. Treat the precise command as an implementation detail, and **flag CLI-version drift as a maintenance risk** (§9). Indicative forms (verify per version — `funnel … on` is *not* current syntax): enable `tailscale funnel --bg --https=443 http://127.0.0.1:<stream_port>`; teardown `tailscale funnel --https=443 off` (repeat the original target/flags if the version requires it). Source: tailscale.com/docs/reference/tailscale-cli/funnel.
- **Public URL:** `https://<MagicDNS-name>` from `Self.DNSName` in `tailscale status --json` (the FQDN has a trailing dot — strip it). The funnel hostname **is** the node's MagicDNS name — there is no separate funnel host. Append `:8443`/`:10000` if a non-443 port was used. The name is publicly resolvable only while the funnel is active; a freshly-enabled funnel may need a few seconds for **DNS propagation**, so the "Test from outside" button (§8) can briefly 404/NXDOMAIN right after enabling. This is the string the UI copies.
- **Serialize all `tailscale` invocations** through a single queue — overlapping enable/disable calls race inside tailscaled.

### 3.3 State reconciliation (source of truth = tailscaled, not PiP)

Funnel config lives in **tailscaled**, so PiP's notion and reality drift. Rules:

- **Authoritative state = `tailscale funnel status` / `tailscale serve status --json`**, never a remembered bool. Reconcile on app launch, prefs open, every toggle, on wake, and a periodic 30–60 s poll while on. **Caveat:** the `serve`/`funnel` status JSON shape is **not a stable contract** across client versions (JSON vs plain output even differ in what they report) — parse defensively and branch per detected CLI version (§3.2).
- **Persisted intent:** store `funnel_intended_on`. On launch, if intent = on, re-assert (idempotent) — the prior funnel may have died. **A normal quit with the default "off on quit" must clear `funnel_intended_on` *before* teardown**, so a crash mid-quit doesn't leave stale "intended on" that re-asserts a funnel the user wanted closed. Only the explicit "keep on when closed" pref preserves intended-on across quit.
- **Foreign config:** if `serve status` shows a funnel pointing at a *different* target/path, **do not clobber it** — warn ("Tailscale Funnel is already serving X").

### 3.4 Lifecycle edge cases

| Event | Behavior |
|-------|----------|
| Normal quit | **Funnel off** (decision #6). Pref "Keep remote access on when PiP is closed" (default off). |
| Crash / power loss | `--bg` Funnel **persists in tailscaled across the crash and even a reboot** until explicitly disabled. **On every launch, detect a PiP-owned active funnel (matching our local target/port) and tear it down** unless the "keep on when closed" pref is set. Never silently leave a public funnel up after an unclean exit. |
| `stream_port` changed | Tear down + re-create the funnel mapping to the new local port; update the displayed URL. |
| Streaming stopped but Funnel on | Serve an **authenticated "stream offline" page**, not a raw 503. Keep the funnel up so authorized users can wait. |
| Network loss / sleep | tailscaled auto-resumes; PiP should **re-poll status on wake** rather than assume. Debounce transient drops. |
| Wake after long sleep | **Ordering matters:** on wake, *first* reconcile Funnel state **and** run the expiry reaper, *then* resume accepting requests — otherwise a user whose window lapsed during sleep could be served before the lazy check catches up. (e.g. asleep 3 h, user enabled for 2 h → must be expired on wake.) |
| tailscaled dies | Funnel down hard → flip UI to "Remote access interrupted (Tailscale stopped)." |

---

## 4. User & session model

### 4.1 User record

```
User {
  id          : UUID            // stable; survives username edits
  username    : string          // unique, case-insensitive compare
  pwRef       : Keychain ref     // points to the salted hash (see 4.3)
  enabled     : bool             // admin master switch
  expiresAt   : epoch            // = now + duration when enabled (always set; decision #4)
  createdAt   : epoch
  lastLoginAt : epoch
}
```

### 4.2 Storage (split by sensitivity)

- **Metadata** (everything except the hash): a JSON file in Application Support
  (`~/Library/Application Support/PiP/remote_users.json`). Preferred over `NSUserDefaults` — the defaults plist is readable in the app container, and the record set grows.
- **Password hashes:** the **Keychain** — one generic-password item per user (account = UUID, service = `PiP.RemoteUser`). JSON holds the reference; the secret stays in Keychain.

### 4.3 Password hashing

- **PBKDF2-HMAC-SHA256 via CommonCrypto** (`CCKeyDerivationPBKDF`) — zero added dependencies. Target **≥600k iterations** (current OWASP guidance for PBKDF2-HMAC-SHA256; the 210k figure is the older SHA-512 number and is too low here), 16-byte random salt, 32-byte output; calibrate to acceptable login latency on target hardware. Store algorithm + iterations + salt + hash, tagged, e.g. `pbkdf2$sha256$<iters>$<salt_b64>$<dk_b64>`. (Argon2id/scrypt are stronger but not in system libs.)
- **Never** store plaintext or unsalted hashes. Use constant-time comparison.
- **Upgrade path:** the iteration count is stored per-hash, so on a successful login, if the stored count is below the current target, transparently **re-hash and persist** at the new cost.

### 4.4 Session model

```
Session {
  token      : 256-bit CSPRNG, base64url   // the cookie value (SecRandomCopyBytes)
  userId     : UUID
  createdAt  : epoch
  lastSeenAt : epoch                        // updated on every authorized request
  clientIP   : string                       // forwarded client IP (audit / rate-limit)
  userAgent  : string                       // display / audit only
}
```

- Sessions live **in memory only**, keyed by token, guarded by a serial queue/lock. Cleared on restart (§2). The cookie carries only the opaque token.
- **Cookie:** `Set-Cookie: pip_sess=<token>; Path=/; HttpOnly; SameSite=Lax; Secure` (the `Secure`-behind-Funnel note is in §7).

### 4.5 Integrating auth into the one-shot HTTP server

Add a single **gate at the top of `process_http_request()`**, before routing:

1. Parse `Cookie:` → token → look up session → validate: exists, user still `enabled`, `expiresAt` not passed, passes the single-session check (§5).
2. **Unauthenticated allowlist:** `GET /login`, `POST /login`, login static assets, optional `GET /healthz`. **Everything else — `/`, `/stream.m3u8`, `/segment_*.ts`, `/hls.min.js`, `/status` — requires a valid session.**
   - **Segments and the playlist MUST be gated.** Segment URLs are guessable (`/segment_5.ts`); an ungated segment is a full public leak of the stream.
3. On failure: `/` → redirect to `/login`; playlist/segment → **401/403** (not a redirect — players don't follow login redirects; a 401 lets the viewer JS detect "session lost" and bounce to login).

**New work flagged:** `POST /login` requires **reading a request body** and parsing `application/x-www-form-urlencoded`. The server is GET/HEAD-only today, so body handling is net-new: read `Content-Length`, buffer the body, **cap size** (a few KB) and reject missing/oversized lengths. It touches the core request path — keep the existing GET path byte-identical to avoid streaming regressions.

---

## 5. Single-concurrent-session enforcement (take over)

**Definition:** one **active viewing session per user**, where "active" is inferred from polling cadence (TCP connections are ephemeral and meaningless here).

### 5.1 Model

- Bind **at most one session token per user**: `activeSessionByUser[userId] = token`.
- **Liveness via lastSeen:** every authorized request updates `session.lastSeenAt`. A session is **live** while `now - lastSeenAt < IDLE_TIMEOUT`.
- **IDLE_TIMEOUT — a *measured* value, not a fixed estimate.** Tie it to the player's real playlist-reload cadence with generous slack: a tight ~12–16 s will falsely evict on mobile browsers, network jitter, wake, or a stalled segment fetch. Start from the actual `hls_writer` target-duration / playlist window and add margin (likely tens of seconds); tune against real clients (§10). The cost of too-long is only a slightly delayed slot free; the cost of too-short is wrongly kicking the legitimate viewer.
- A slot is **free** for a user if they have no active session, or their active session is stale.
- **Single source of truth for "who's watching now":** the `activeSessionByUser` map + each session's `lastSeenAt` is the *same* data backing the admin "live viewers" indicator and menu-bar count (§8) — one model, not two.

### 5.2 Take-over policy (decision #5)

- On a successful login, **atomically** (under the serial queue/lock) replace any existing token for that `userId`. The previous token is invalidated **immediately**.
- The evicted player discovers it on its **next poll**: a playlist/segment request with the now-invalid token returns **401/403** → the viewer shows a "Signed in on another device" overlay and stops playback. (In hls.js, surface via the loader/error callback.)
- **Precise guarantee:** take-over invalidates the old token; the **next** request bearing it gets 401, and **at most one already-authorized in-flight request completes** (a request that passed the gate microseconds before take-over). Do **not** attempt to kill in-flight responses — the server's fire-and-forget write model can't, and one stale segment is harmless.
- A crashed or closed tab therefore never locks the user out — the new login always wins.

### 5.3 Concurrency / races

- All session mutations (create, take-over, lastSeen, reap) go through **one serial queue / lock**. The check-and-claim must be **atomic**; two simultaneous logins for one user resolve as last-writer-wins, leaving exactly one valid token.
- **Reaper timer** (every ~IDLE_TIMEOUT/2) sweeps stale sessions → frees slots, applies expiry, and avoids ghost "active" users in the admin UI even with no traffic.

### 5.4 Viewer UX

The embedded viewer JS must treat **401/403 on playlist or segment** as a session event: stop playback and show an overlay — "Signed in elsewhere" / "Session expired" / "Access ended" / "Stream offline" — with a re-login button. Otherwise hls.js shows opaque network errors.

---

## 6. Duration-based enablement

### 6.1 Semantics

"Enable for 2h" → `enabled = true`, `expiresAt = now + duration` (absolute epoch). A duration is **always** required (decision #4) — there is no indefinite grant.

### 6.2 Enforcement — belt and suspenders

1. **Lazy (authoritative):** the auth gate checks `expiresAt` on **every** request → no access past expiry, regardless of timers. Mid-stream, the next poll (within seconds) returns 403 → overlay "Access window ended." This naturally handles expiry mid-watch.
2. **Proactive (housekeeping):** the reaper clears `enabled`/the active session at `expiresAt` so the UI countdown and slot-freeing stay accurate without traffic.

### 6.3 Clock / sleep / wake

- Compare absolute epoch to **wall-clock** time (`gettimeofday` / `NSDate`), **not** a monotonic clock (a "2h" grant is wall-clock by intent; the Mac may sleep). After wake, the lazy check enforces a passed expiry immediately.
- A manual backward clock change could un-expire a grant — acceptable for this threat model (admin controls the machine); noted, not engineered around.

### 6.4 Persistence & re-enable

- `expiresAt` is metadata → persists in the user JSON across restart. Expired users are inert until re-enabled.
- **Re-enable** sets a fresh absolute window; **"Extend +N"** adds to the current expiry. **Disable** sets `enabled = false` and kills the live session.

---

## 7. Security (this becomes public on the internet)

- **Gate every content route** (restated — non-negotiable). Only login routes are public; segment URLs are guessable so an ungated segment leaks the stream.
- **Trust forwarded headers ONLY from local `tailscaled`.** PiP still binds `0.0.0.0`, so a LAN client can connect directly and **spoof `X-Forwarded-For` / `X-Forwarded-Proto`**. Rule: honor the `X-Forwarded-*` headers **only when the TCP peer is loopback / the local tailscaled address**; for any other peer, ignore them and fall back to the real socket peer address and scheme. (Best: also bind the server to `127.0.0.1` once Funnel is the access path, so only tailscaled can reach it — revisit alongside the existing LAN-streaming use case.)
- **Brute-force protection:** make **per-source-IP throttling the primary control** — an escalating delay / temporary throttle after N failures (e.g. 5 → 1 min, escalating), **not a permanent block**. For per-username, use **exponential backoff (a growing delay), NOT a hard lockout** — a hard username lockout is a trivial DoS (anyone who knows a username can lock the legitimate user out). Read the client IP from the trusted **`X-Forwarded-For`** (per the rule above); the raw socket peer is the local tailscaled proxy and is useless for per-client limiting.
- **User-enumeration / timing safety:** run the KDF even for unknown usernames (compare against a dummy hash) so response time doesn't reveal valid users; return identical error text + timing for "no such user" vs "wrong password."
- **Session tokens:** ≥256-bit CSPRNG (`SecRandomCopyBytes`), base64url; never derived from username/time.
- **TLS-terminated-by-Funnel subtleties** — drive scheme decisions off **`X-Forwarded-Proto: https`** (injected in HTTP-proxy mode, §3.2), never off PiP's local socket:
  - PiP sees plain HTTP locally, but the browser-facing scheme is HTTPS → **always set the `Secure` cookie flag.** Gating it on the local socket scheme would mean the cookie never sets. The browser receives the response over HTTPS (Funnel re-encrypts), so `Secure` cookies are stored correctly.
  - **Redirects:** prefer **relative** (`Location: /`) to avoid leaking `127.0.0.1:8080`; if absolute is needed, build from the `Host:` (MagicDNS) name + `https://` (per `X-Forwarded-Proto`), never the local target.
- **Cookie flags:** `HttpOnly`, `SameSite=Lax` (or `Strict`), `Secure`, `Path=/`.
- **CSRF on `POST /login`:** `SameSite` covers the common case; optionally add a per-form nonce.
- **CORS:** the viewer is served **same-origin**, and browsers ignore `Access-Control-Allow-Origin: *` for credentialed (cookie-bearing) requests anyway — so the wildcard is pointless here. **Drop the CORS header on authenticated routes** (keep only if a real cross-origin consumer is ever added).
- **Audit log:** login success/failure (user, IP, time), session start/end, take-overs, funnel enable/disable. Surface recent events in the UI; bounded ring buffer.
- **Kill switches — the in-process one is authoritative.** "Disable all users / revoke all sessions" runs entirely in PiP and **does not depend on the CLI succeeding**, so it is the TRUE kill switch. Turning Funnel off is best-effort: if `tailscale funnel off` fails (daemon down/unresponsive), the public route may linger — so the auth layer must remain the guarantee. Both are exposed; the UI should make clear that revoking sessions cuts access even if Funnel teardown fails.
- **Default-closed:** Funnel off, no users, on first run. Each step toward exposure is deliberate.
- **Honest in-UI exposure warning:** when Funnel is on, state clearly that the stream is reachable on the public internet at `<URL>`.

---

## 8. UI / UX (macOS prefs / menu app)

**New "Remote Access" prefs pane:**

- **Tailscale Funnel section**
  - Status pill driven by §3.1: Off / Starting / **Public at `<url>`** / Error: `<reason>` (Not installed / Not running / Not logged in / Funnel not permitted [admin link] / HTTPS not enabled / port in use / offline).
  - **Enable Remote Access** toggle — disabled until capability checks pass, with inline remedy text + "Open Tailscale admin" link.
  - Public URL (read-only) + **Copy** + **Open** buttons (shown when on).
  - **Test from outside** button — opens the public URL in the default browser so the admin can verify the funnel end-to-end (suggest an incognito/private window, since the admin's own tailnet session differs from a true external visitor).
  - "Keep on when PiP is closed" checkbox (default off).
  - Prominent **warning banner** when on: "Your screen is reachable on the public internet."
- **Users section** — table: Username · Status (Disabled / Active until HH:MM / Expired) · Live now? (• / –) · actions.
  - **Add user:** username + password (confirm + strength hint).
  - Per-row: Edit (rename / reset password) · **Enable for…** (duration picker: 15m / 1h / 4h / 8h / Custom — **no "no limit" option**) · **Extend +…** · Disable · **Force sign-out** (revoke active session) · Delete.
  - Live **countdown** for each enabled user.
  - "Disable all / revoke all sessions" kill-switch affordance.
- **Menu-bar quick controls:** toggle Remote Access + "Copy public URL" + count of active remote viewers; indicator when public exposure is live.
- **Served pages:** a branded **login page** (error + lockout messaging) and **session-event overlays** in the viewer (signed-in-elsewhere / expired / stream offline).

---

## 9. Phased roadmap

| Phase | Scope | Key risks |
|-------|-------|-----------|
| **0. Prereqs** | POST-body parsing + a request-context/cookie layer in the GET/HEAD-only server; CLI exec + serial-queue wrapper; capability detection + `status --json` parsing. | Parser changes touch the core request path — regression risk to existing streaming. Keep the GET path byte-identical; **regression guard: a test asserting an authorized segment/playlist fetch returns identical bytes + headers with the auth layer compiled in vs. the pre-auth baseline.** |
| **1. Tunnel toggle** | The enable/disable + reconciliation + URL + quit-policy + kill-switch machinery. **Develop and test against `tailscale serve` (tailnet-private, NOT public) — `serve` exposes only to your own devices.** Do **not** flip to `funnel` (public) until Phase 2 auth exists. | Tailscale env variance (paths, ACL/HTTPS prereqs); **CLI-version drift in the `serve`/`funnel` syntax** (code to the contract + detect version, §3.2); state desync; clobbering a foreign serve config. |
| **2. Single-user auth** | Login page, session cookie, **gate ALL content routes**, PBKDF2 + Keychain, rate limiting, cookie/redirect-behind-Funnel correctness. | Security correctness; segments truly gated; cookie `Secure`/redirect subtleties. |
| **3. Multi-user + duration** | User CRUD, enable-for-duration + extend, lazy + reaper expiry, user JSON store, UI table + countdowns, audit log. | Storage handling; clock/sleep edge cases; UI state freshness. |
| **4. Single-session take-over** | Per-user active-session binding, lastSeen liveness, **take-over + eviction**, reaper, viewer overlays. | Concurrency races (atomic claim); tuning IDLE_TIMEOUT to HLS cadence; viewer eviction UX. |

> **Sequencing note (non-negotiable):** **`serve` = tailnet-private; `funnel` = public internet.** Phase 1 uses `serve` only, so the stream is never publicly exposed before auth exists. The switch to `funnel` (public) ships **together with** Phase 2 authentication — never expose an unauthenticated public stream. Add an integration test asserting that any content route without a valid session returns 401.

---

## 10. Items still open / to confirm during implementation

1. **IDLE_TIMEOUT value** — depends on PiP's actual HLS target-duration / playlist window (check the `hls_writer` config). Tentative: 3–4× segment duration.
2. **Forwarded client-IP header** — HTTP-proxy mode (§3.2) injects `X-Forwarded-For` / `X-Forwarded-Proto`, but this is **resolved only subject to** (a) verifying the headers/casing on the actual client version at implementation time, and (b) the **loopback-only trust rule** in §7 (the server binds `0.0.0.0`, so forwarded headers must be ignored from non-local peers).
3. **Admin "force sign-out"** — should it just end the session (user may immediately log back in), or also briefly block re-login?
4. **Keep-Funnel-on-quit pref** — default off; confirm it's even desirable given the exposure posture.
5. **Re-enable vs extend** behavior (fresh window + explicit "extend") — adopted default, confirm.
6. **Ephemeral sessions** across PiP restart (currently cleared) — add a persisted "stay logged in" only if requested.
7. **Public port default** (443 with 8443/10000 fallback) — revisit if the node already funnels 443 elsewhere.
8. **Audit log** retention / size cap — set a concrete bounded cap before implementation (§7 already commits to a ring buffer); affects privacy and disk growth.
