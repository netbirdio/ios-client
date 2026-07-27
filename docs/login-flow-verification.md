# Login flow: verification scenarios

Reference for manually verifying the login flow, and the basis for automating it later.
Written after the change that removed the redundant `Login` RPCs (see "Background").

## Background

Every "is login required?" check is a **full `Login` gRPC call** against the management
server — `auth.Auth.IsLoginRequired` calls `doMgmLogin` and classifies the error. There is
no cheaper probe. Redundant checks were therefore indistinguishable from real logins in the
server logs, and iOS made ~7 of them per fresh connect against Android's ~3.

Four duplicates were removed:

| Where | What it was | Now |
|---|---|---|
| `client/ios/NetBirdSDK/client.go` `Run()` | `LoginSync()` pre-flight = `IsLoginRequired` + `Login` | removed; the engine's `loginToManagement` is authoritative |
| `client/ios/NetBirdSDK/login.go` `login()` | `IsLoginRequired` before the browser | skipped via `LoginInteractive` when the caller already knows |
| `NetbirdNetworkExtension/PacketTunnelProvider.swift` `startTunnel` | `needsLogin()` on every start | skipped when the main app passes `loginVerified` |
| `ConnectionListener.onDisconnected`, `restartClient` | blocking `needsLogin()` | network-free `needsLoginCached()` |

Expected counts (`Login` RPCs observed server-side before the first `Sync`):

| Flow | Before | After |
|---|---|---|
| Interactive login (browser) | ~7 | 3 |
| Reconnect, already authenticated | 5 | 2 |
| Network change (Wi-Fi ↔ cellular) | 2 per change | 1 per change |

The 2 remaining on a reconnect are the main app's `isLoginRequired()` (the UX decision:
browser or connect) and the engine's `loginToManagement` (mandatory — its response carries
the signal/relay/TURN config and is immediately followed by `Sync`).

### Why removing the pre-flights is safe

An expired or revoked session still tears the tunnel down, just one step later and through a
single path instead of three:

1. `loginToManagement` fails with `PermissionDenied` ([connect.go:308](../netbird-core/client/internal/connect.go#L308))
2. `state.Set(StatusNeedsLogin)` + `wrapErr` → the deferred `MarkManagementDisconnected(err)`
   records the auth error on the shared status recorder
3. `defer c.statusRecorder.ClientStop()` fires `onDisconnected` on the Swift listener
4. `needsLoginCached()` reads that recorder → true → `onLoginRequired()` →
   `signalLoginRequired()` + `cancelTunnelWithError`

The pre-flights were also actively harmful when the server was unreachable: `IsLoginRequired`
retries with backoff for up to 2 minutes (`MaxElapsedTime`) and then returns `true` on
failure, so a plain timeout was reported to the user as "login required". The engine instead
keeps retrying and recovers when the server returns — see scenario 3.

## How to observe

**Server side (the actual assertion).** Count `Login` requests per peer key before the first
`Sync`. On a self-hosted server: `docker logs -f netbird-management | grep -E "Login request|Sync request"`.

**Client side.** Debug bundle, or Console.app with the device attached:

- main app: subsystem `io.netbird-helicon.app`, category `NetworkExtensionAdapter`
- extension: `AppLogger` lines in `logfile.log` inside the app group container

Log lines that mark the decision points after this change:

| Line | Meaning |
|---|---|
| `loginIfRequired: isLoginRequired() returned <bool>` | main app's one check (RPC #1) |
| `startVPNConnection: called (loginVerified: true)` | extension will skip its check |
| `startTunnel: login already verified by the main app, skipping needsLogin check` | RPC saved |
| `performLogin: SDK login succeeded` | interactive login done (RPC #2 + #3) |
| `onDisconnected: login required — signalling teardown` | session expiry caught via cached path |

## Scenarios

Preconditions common to all: a device (or simulator) with the app installed, a reachable
management server, and access to its logs. "Clean state" = app deleted and reinstalled, or
all profiles logged out.

### 1. Fresh interactive login

1. Clean state. Launch the app, add/select the server profile, tap **Connect**.
2. The login browser opens; complete the IdP login.
3. Browser closes, VPN connects.

Expected: **3** `Login` requests before `Sync`. Peer appears under the device's real name
(`UIDevice.current.name`), not a hostname fallback. Status reaches Connected and stays.

### 2. Reconnect while already authenticated

1. From scenario 1's connected state, tap **Disconnect**, then **Connect**.

Expected: **2** `Login` requests, no browser, connects directly. Log shows
`loginVerified: true` and the extension's skip line.

### 3. Server unavailable / timeout

Two sub-cases with different current behaviour — keep them apart.

**3a. Server unreachable before the connect starts.**

1. From an authenticated state, make the server unreachable (stop it, or point the profile at
   an unroutable address / block it on the network).
2. Tap **Connect**.

Current behaviour, **not** fixed by this change: the main app's `isLoginRequired()` still
runs, blocks for up to 2 minutes (`withRetry`, `MaxElapsedTime`) and then returns `true`,
because `Client.IsLoginRequired` treats a failed check as "login required" to be safe
([client.go:379](../netbird-core/client/ios/NetBirdSDK/client.go#L379)). The user sees a
long stall followed by a login prompt for what is really a timeout.

This is a known remaining issue, tracked separately from the RPC-count work. A test should
pin the behaviour that exists rather than the desired one, so the day it is fixed the change
is visible.

**3b. Server becomes unreachable after the login check passed.**

1. Connect normally and let it reach Connected.
2. Take the server down, then disconnect and reconnect (or let a network change trigger a
   restart) while it is still down.

Expected, and improved by this change: no login prompt. The engine retries `loginToManagement`
with backoff and recovers on its own when the server returns. Previously the removed
`LoginSync` pre-flight could fail here independently and abort the start.

### 4. Profile switching

1. Configure two profiles, both logged in (different servers, or the same server).
2. Switch A → B while disconnected, connect. Then switch B → A, connect.
3. Repeat at least once while **connected**, switching directly.

Expected: each connect uses the switched-to profile's config/state path (log line
`startVPNConnection: configPath=...`), **2** `Login` requests, and the peer that appears on
the server belongs to that profile. No cross-profile identity reuse, no browser prompt for an
already-authenticated profile.

### 5. Re-login after connection loss

1. Connect. Then drop the network (Airplane mode on, or leave Wi-Fi range) for ~30 s.
2. Restore the network.

Expected: the tunnel recovers by itself. `restartClient` runs; **1** `Login` per restart
(down from 2). No re-auth prompt while the session is still valid.

Also run the Wi-Fi ↔ cellular variant: connect on Wi-Fi, disable Wi-Fi to fall back to
cellular, then re-enable. Same expectation.

### 6. Re-login after session expiration

Requires a server with a short peer-login expiry (Settings → peer login expiration), or
manually revoking/expiring the peer's session while connected.

1. Connect. Wait for the session to expire (or expire it server-side).
2. Observe the client.

Expected: the tunnel tears down rather than lingering with the default route black-holing
traffic. `onDisconnected: login required — signalling teardown` appears; the login-required
flag is set and the local notification fires. Tapping **Connect** opens the browser and a
successful re-auth reconnects, **reusing the same peer identity** — no duplicate peer is
registered on the server.

Run this variant twice: with the app in the foreground, and with it backgrounded/force-quit
(the extension's best-effort notification path).

### 7. Setup-key authentication

1. Clean state. Add a server profile and log in with a **setup key** instead of SSO.
2. Connect.

Expected: no browser at any point, peer registers under the setup key, connects normally.
This path goes through `LoginWithSetupKeyAndSaveConfig` and was intentionally left unchanged.

### 8. Start paths that bypass the main app

These must still perform their own check (they carry no `loginVerified` flag):

1. **Widget / Control Center**: with the app force-quit, connect from the widget.
2. **On Demand**: enable On Demand, then let iOS bring the tunnel up on a network change.

Expected: both connect normally when authenticated. When the session has expired, both fail
closed with the login-required flag set rather than starting a black-holed tunnel.

## Note for automation

Assertions worth encoding, in rough order of value:

1. **Login count per flow** — parse the management server log, count `Login` between the
   connect action and the first `Sync`. This is the regression guard for this change.
2. **No tunnel without auth** — after expiry, assert the utun interface is gone and the
   default route is restored (scenario 6 is the one that black-holes traffic if it breaks).
3. **Identity stability** — peer public key is unchanged across a re-login (scenario 6) and a
   profile switch round-trip (scenario 4); the server's peer count does not grow.
4. **Timeout is not auth failure** — scenario 3 must never set
   `GlobalConstants.keyLoginRequired`.

Scenarios 1, 6 and 7 need an IdP/setup-key fixture; 2–5 and 8 can run against a pre-seeded
authenticated state. All network operations that matter here run **inside** the extension —
any harness that drives connections from the app process would route management traffic into
the tunnel and invalidate the results.
