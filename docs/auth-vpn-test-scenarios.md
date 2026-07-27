# Auth & VPN connection: test scenario catalog

Inventory of everything in the login and connection logic that is worth covering by tests.
Derived from the actual code paths, not from a feature list. No tests exist yet — this is the
planning input for writing them.

Companion document: [login-flow-verification.md](login-flow-verification.md) (manual
verification of the RPC-count optimisation).

## Layer legend

| Tag | Layer | What it needs |
|---|---|---|
| **U** | Unit | The SDK behind a protocol seam so `NetBirdSDKClient` / `NetBirdSDKAuth` can be faked. Fast, no device, no server. |
| **I** | Integration | A real or mock management server. Physical device for anything that establishes a tunnel — packet tunnel providers do not work in the Simulator. |
| **UI** | XCUITest | Accessibility identifiers + launch-argument state reset (neither exists yet). |
| **M** | Manual | Not automatable at reasonable cost; keep as a release checklist item. |

Most of the valuable coverage below is **U**, and it is blocked on one refactor: the adapter
constructs `NetBirdSDKNewClient` / `NetBirdSDKNewAuth` directly, so nothing can be substituted
today. That seam is the single highest-leverage prerequisite.

---

## A. Login state resolution

Covers `NetworkExtensionAdapter.isLoginRequired()` and `Client.IsLoginRequired`.

| # | Precondition | Action | Expected | Layer |
|---|---|---|---|---|
| A1 | No config file for the active profile | `isLoginRequired()` | `true`, without any network call | U |
| A2 | Config present, session valid | `isLoginRequired()` | `false` | I |
| A3 | Config present, session expired server-side | `isLoginRequired()` | `true` | I |
| A4 | App group container unavailable | `isLoginRequired()` | `true` (fail-safe), logged | U |
| A5 | Config file present but empty / unparseable | `isLoginRequired()` | `true`, no crash | U |
| A6 | Server unreachable | `isLoginRequired()` | Returns `true` after backoff — **pins current behaviour**, see verification doc §3a | I |
| A7 | State file missing, config present | `isLoginRequired()` | Resolves without crashing | U |

## B. Interactive SSO login

Covers `performLogin()`, `SafariView`, and `Auth.login` in the Go layer. This area has the
most non-obvious edge cases and the most value per test.

| # | Precondition | Action | Expected | Layer |
|---|---|---|---|---|
| B1 | Clean profile, no config | Full browser login | Peer registers under `UIDevice.current.name`, not a hostname fallback | I |
| B2 | Existing config, expired session | Re-login | Same WireGuard identity reused; **no** second peer on the server | I |
| B3 | Browser open | Tap **Cancel** | VPN does not start, no "login required" alert, loopback port freed for the next attempt | U + UI |
| B4 | Browser auto-closed before the SDK reported success | SDK success arrives | Adapter starts the VPN itself (`showBrowser == false` branch) | U |
| B5 | Browser still open when success arrives | Browser finish handler runs | Browser's handler starts the VPN; not started twice | U |
| B6 | Browser completed, token exchange or management login then fails | — | Error surfaced in logs/UI, no silent hang, `pendingAuth` cleared | U |
| B7 | Profile key belongs to a peer owned by another user | Login | Identity reset once, login retried automatically, new peer registered, conflicting peer untouched | U + I |
| B8 | Same conflict occurs again on the retry | — | No retry loop — `identityResetAttempted` stops at one | U |
| B9 | Main-app auth cannot initialise (no config path) | Login | Falls back to extension IPC path | U |
| B10 | A previous abandoned login left a flow bound | New login starts | Old `pendingAuth` stopped first; new flow binds successfully | U |
| B11 | `onOpen` fires from a background goroutine | — | `showBrowser` committed before the continuation resumes — no spurious parallel VPN start | U |
| B12 | Two profiles, both logged in via the same IdP | Login to each | Cookie stores isolated per profile; no session bleed | UI + M |
| B13 | iOS < 17 | Login | Falls back to non-persistent store, login still completes | M |

## C. Setup-key login

Covers `ServerViewModel.loginWithSetupKey` and `LoginWithSetupKeyAndSaveConfig`. Left
unchanged by the RPC work, so these are regression guards.

| # | Precondition | Action | Expected | Layer |
|---|---|---|---|---|
| C1 | Valid key + valid URL | Log in | Peer registers, connects, browser never appears | I |
| C2 | Malformed setup key | Submit | Validation error shown, no network call | U |
| C3 | Malformed URL | Submit | Validation error shown, no network call | U |
| C4 | Well-formed key the server rejects | Submit | Server error surfaced to the user | I |
| C5 | Server without SSO support | Setup-key login | Succeeds (this is the intended path there) | I |
| C6 | Both fields invalid | Submit | Both errors shown, UI re-enabled | U |

## D. Config & management URL persistence

Covers `restoreConfigIfMissing()`, `ProfileManager.managementURL(for:)`, and the Go nested
`url.URL` serialisation. Historically a source of "silently connected to the wrong server"
bugs, so worth dense coverage — and almost all of it is pure unit-testable.

| # | Precondition | Action | Expected | Layer |
|---|---|---|---|---|
| D1 | Profile logged out | Inspect files | `netbird.cfg` and `state.json` gone; server URL file kept | U |
| D2 | Config missing, server URL saved | Connect | Minimal config written in nested `{Scheme,Host,Path}` form, correct server used | U |
| D3 | Config present with nested URL object | Resolve URL | Parsed correctly and mirrored to the URL file + cache | U |
| D4 | Config present with plain-string URL | Resolve URL | Also parsed (legacy format) | U |
| D5 | No URL anywhere | Resolve URL | Returns nil, caller logs the fallback-to-cloud warning | U |
| D6 | URL with explicit port (`https://host:8443`) | Round-trip | Port preserved in `Host` | U |
| D7 | URL with a path component | Round-trip | Path preserved | U |
| D8 | URL containing characters needing JSON escaping | Round-trip | Escaped, file stays valid JSON | U |
| D9 | Own-server profile, config recreated | Connect | Never falls back to `api.netbird.io` | U + I |
| D10 | Successful login | Restart app | Config persisted and reused | U |

## E. Profiles

Covers `ProfileManager` and the adapter-recreation logic in the extension.

| # | Precondition | Action | Expected | Layer |
|---|---|---|---|---|
| E1 | Two profiles, disconnected | Switch A→B, connect | New profile's config/state paths used | U + I |
| E2 | Connected on A | Switch to B and connect | Adapter recreated, old Go callbacks detached, no crash | I + M |
| E3 | A logged in, B not | Switch to B, connect | Login required for B; A's session untouched | I |
| E4 | Both logged in | Log out A | B still authenticated | U |
| E5 | Non-active, non-default profile | Remove | Tombstoned and hidden from the list even if the Go SDK recreates the directory | U |
| E6 | Default or active profile | Remove | Rejected with the specific error | U |
| E7 | Two profiles on the same server | Log into both | Distinct peer identities, no key reuse | I |
| E8 | Profile switched while extension process alive | Connect | Extension detects the path change and reinitialises | U + I |

## F. VPN connection lifecycle

| # | Precondition | Action | Expected | Layer |
|---|---|---|---|---|
| F1 | Authenticated | Connect | Reaches Sync, status Connected, stays stable | I |
| F2 | Connected | Disconnect | Clean teardown, status Disconnected | I |
| F3 | Authenticated | Connect → disconnect → connect | Works repeatedly without residue | I |
| F4 | Tunnel fd unavailable | Start | Fails with the dedicated error, does not hang | U |
| F5 | Engine login fails permanently (PermissionDenied) | Start | Tunnel fails, login-required flag set, no black-holed interface | I |
| F6 | Connected | Poll status | Reported state matches the real tunnel state | U |
| F7 | Connect tapped twice quickly | — | Single tunnel start, no duplicate session | U + UI |
| F8 | Status fetch already in flight | Fetch again | Re-entrancy guard holds; completion still fires exactly once | U |
| F9 | Status fetch never answered | Wait | 10 s timeout releases the guard | U |

## G. Session expiry & re-authentication

The highest-severity area: a mistake here leaves the tunnel up with the default route and
black-holes all traffic.

| # | Precondition | Action | Expected | Layer |
|---|---|---|---|---|
| G1 | Connected, session expires mid-tunnel | — | `onLoginRequired` fires, tunnel cancelled, default route restored | I + M |
| G2 | Expiry while the app is in the foreground | — | Exactly one notification (app path wins, extension's delayed one cancelled) | M |
| G3 | Expiry while the app is force-quit | — | Extension's best-effort notification fires | M |
| G4 | Expiry detected | Re-auth | Same peer identity reused, no duplicate peer | I |
| G5 | Login required flag set | Enable On Demand | Refused — prevents a reconnect loop | U |
| G6 | Ordinary disconnect (not expiry) | — | No login-required signal, no notification | U |
| G7 | Disconnect while network is unavailable | — | Stays in connecting for auto-reconnect rather than reporting disconnected | U |

## H. Network changes & recovery

Covers `handleNetworkChange` / `restartClient`.

| # | Precondition | Action | Expected | Layer |
|---|---|---|---|---|
| H1 | Connected | Network lost | Stays connecting, tunnel kept alive, flag set | U + M |
| H2 | Network lost then restored | — | Single debounced restart, reconnects | U + M |
| H3 | Connected on Wi-Fi | Switch to cellular | Restart triggered once | U + M |
| H4 | Rapid consecutive network changes | — | Debounce collapses them into one restart | U |
| H5 | Session expired during the outage | Network returns | Restart skipped, login-required signalled | U |
| H6 | Restart hangs | Wait 30 s | Timeout resets the in-progress flags | U |
| H7 | Restart in progress | Another change arrives | Second restart suppressed | U |

## I. Start paths that bypass the main app

These must keep their own login check — they carry no `loginVerified` flag.

| # | Precondition | Action | Expected | Layer |
|---|---|---|---|---|
| I1 | Authenticated, app force-quit | Connect from widget | Connects; extension performs its own check | M |
| I2 | Login required | Widget connect | Blocked by the shared flag, login prompt surfaced | U |
| I3 | On Demand enabled, authenticated | Network change brings the tunnel up | Connects, extension verifies independently | U + I |
| I4 | Logged out | Attempt to enable On Demand | Refused | U |
| I5 | Widget start | — | Active profile paths passed so the correct config is used | U |

## J. Login RPC economy

The regression guard for the optimisation. Assertions come from management server logs, so
these are integration-level.

| # | Flow | Expected `Login` RPCs before first `Sync` | Layer |
|---|---|---|---|
| J1 | Fresh interactive login | 3 | I |
| J2 | Reconnect, already authenticated | 2 | I |
| J3 | Restart after a network change | 1 | I |
| J4 | Ordinary disconnect | 0 additional | I |
| J5 | `loginVerified` passed | Extension's check skipped (assert on the log line) | U |
| J6 | `loginVerified` absent (widget / On Demand) | Extension's check still performed | U |

## K. Concurrency & lifecycle races

Cheap to unit-test once the seam exists, and these are exactly the bugs that produce crashes
rather than wrong answers.

| # | Precondition | Action | Expected | Layer |
|---|---|---|---|---|
| K1 | Login in flight | Stop / cancel | Context cancelled, port released, no callback into a torn-down object | U |
| K2 | Adapter replaced (profile switch) | Late Go callback from the old client | No-op, no crash — listeners invalidated | U |
| K3 | `stop()` called twice | — | Pending completion handlers all fire exactly once | U |
| K4 | `onDisconnected` fires without a prior stop request | — | Handled without deadlock | U |
| K5 | Success and error callbacks both arrive | — | Only the first is honoured | U |
| K6 | App backgrounded mid-login | Return to foreground | Login state consistent, no duplicate browser | M |

---

## Suggested order of implementation

1. **The SDK seam** — a protocol in front of the client/auth objects. Without it, groups A, B,
   D, F, H and K stay untestable, and those are ~60 % of the catalog.
2. **Groups D and A** — pure logic, no server, immediate value, and D historically regresses.
3. **Groups B, H, K** — the callback and race logic, still unit-level once the seam exists.
4. **Group J** — needs a server-log fixture; this is what guards the RPC optimisation.
5. **Groups C, E, F, G, I** — integration on a physical device, slowest to build and run.
6. **UI layer last** — needs identifiers and launch-argument state reset first; keep it thin,
   covering only browser-shown / not-shown, Cancel, and form validation.
