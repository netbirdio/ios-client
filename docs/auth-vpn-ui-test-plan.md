# Auth & VPN: UI test plan (XCUITest)

Scenarios coverable by XCUITest — driven through the app's UI and asserted on visible UI
state. Everything listed here is actually reachable that way; nothing aspirational.

40 scenarios in 9 suites.

## Constraints that shape the setup

**Physical device for anything that connects.** `start()` calls `configureManager()` before
`loginIfRequired()`, and NetworkExtension provider configurations do not save in the
Simulator; when that throws, `start()` bails in its catch and the login flow never runs — so
in the Simulator the Connect button does nothing. Verify this first, it decides the CI setup.
Suites 1 and 5.5 never reach Connect and run in the Simulator.

**The login browser is drivable.** It is an in-app `WKWebView`
([SafariView.swift:60](../NetBird/Source/App/Views/Components/SafariView.swift#L60)), not
`ASWebAuthenticationSession`, so XCUITest can read and fill the IdP page. This is what makes
suites 2 and 3 possible.

## Prerequisites

- [ ] UI test target (none exists)
- [ ] Accessibility identifiers — currently **zero** in the codebase. Needed on: Connect
      button, status label, IP/FQDN labels, profile rows + switcher, Add/Remove/Logout profile
      controls, Server URL field, Setup Key field, validation error labels, login browser
      container + its Cancel button, alert bodies, On Demand toggles
- [ ] Launch arguments for deterministic state:
      - reset all profiles / config / state
      - clear the profile's `WKWebsiteDataStore` — otherwise the IdP trusted-device cookie
        survives and the second run's "first login" silently redirects instead of showing the
        form ([SafariView.swift:72](../NetBird/Source/App/Views/Components/SafariView.swift#L72))
      - preseed a server URL / an authenticated state
- [ ] Test IdP account without MFA/captcha, or with a TOTP the test can compute
- [ ] VPN permission handled — pre-installed profile on the test device, or an
      `addUIInterruptionMonitor` for the system dialog on first install
- [ ] Generous timeouts where noted: some paths legitimately block for up to 2 minutes

---

## Suite 1 — Server setup & validation

Simulator; 1.4 additionally needs a reachable server. No device, no tunnel — cheapest to build
and fastest to run, so the natural starting point.

| # | Steps | Assertion |
|---|---|---|
| 1.1 | Enter malformed setup key, submit | Setup-key validation error shown, UI re-enabled |
| 1.2 | Enter malformed server URL, submit | URL validation error shown |
| 1.3 | Both fields malformed, submit | Both errors shown simultaneously |
| 1.4 | Valid formats, submit | No validation error; form progresses to the next state |
| 1.5 | Empty fields, submit | Appropriate errors, no crash |

## Suite 2 — Login browser presentation

Device. The highest-value suite: whether the browser appears is the visible manifestation of
the login-state logic.

| # | Precondition | Steps | Assertion |
|---|---|---|---|
| 2.1 | Clean state, server configured | Tap Connect | Login browser appears with the IdP page loaded |
| 2.2 | Authenticated | Tap Connect | Browser does **not** appear; proceeds to connecting |
| 2.3 | Browser open | Tap Cancel | Browser dismisses, VPN does not start, no "login required" alert |
| 2.4 | Cancelled once | Tap Connect again | Browser appears again — the previous flow released its loopback port |
| 2.5 | Server URL points at an unroutable address | Tap Connect | Pins current behaviour: long stall (allow > 2 min), then a login prompt. See verification doc §3a — assert what exists so a future fix is visible |
| 2.6 | Logged out via the UI | Tap Connect | Browser appears |

## Suite 3 — Full SSO login

Device + IdP fixture.

| # | Precondition | Steps | Assertion |
|---|---|---|---|
| 3.1 | Clean state, web store cleared | Connect → fill IdP form → submit | Browser auto-closes; status reaches Connected; IP/FQDN populated |
| 3.2 | Logged out, web store kept | Connect | Silent SSO redirect, no credential entry; reaches Connected |
| 3.3 | After 3.1 | Force-quit, relaunch, Connect | Still authenticated; no browser |
| 3.4 | Two profiles, A logged in | Switch to B, Connect | B shows the IdP form — A's cookies are not visible to B |

## Suite 4 — Setup-key login

Device + a valid setup key.

| # | Precondition | Steps | Assertion |
|---|---|---|---|
| 4.1 | Clean state, valid key | Enter key + URL, submit, Connect | No browser at any point; reaches Connected |
| 4.2 | Key the server rejects | Submit | Server error surfaced in the UI; no connection |
| 4.3 | Server without SSO support | Setup-key login | Succeeds |

## Suite 5 — Profiles

Device; 5.5 runs in the Simulator.

| # | Precondition | Steps | Assertion |
|---|---|---|---|
| 5.1 | Two profiles authenticated, disconnected | Switch A→B, Connect | Connects as B, no browser, UI shows B active |
| 5.2 | Connected on A | Switch to B, Connect | No crash; connects as B; status consistent |
| 5.3 | A authenticated, B not | Switch to B, Connect | Browser appears for B |
| 5.4 | Both authenticated | Log out A, switch to B, Connect | B connects without a browser |
| 5.5 | Default / active profile | Attempt removal | Rejected — control disabled or error shown |
| 5.6 | Both authenticated | A→B→A, connect each time | Each connect uses its own profile; no browser |

## Suite 6 — Connection lifecycle

Device.

| # | Precondition | Steps | Assertion |
|---|---|---|---|
| 6.1 | Authenticated | Connect | Status Connected; IP and FQDN populated |
| 6.2 | Connected | Disconnect | Status Disconnected; IP/FQDN cleared |
| 6.3 | Authenticated | Connect/disconnect ×3 | Stable each cycle, no stuck intermediate state |
| 6.4 | Disconnected | Double-tap Connect quickly | Single connection, no stuck state |
| 6.5 | Connected | Observe ~1 min | Stays Connected, no spurious Connecting/Disconnecting flicker |
| 6.6 | Connected | Force-quit app, relaunch | UI reflects the still-connected tunnel, not a stale Disconnected |
| 6.7 | Connected, peers on the account | Open peer list | Peers listed with their details |

## Suite 7 — Logged-out guards

Device.

| # | Precondition | Steps | Assertion |
|---|---|---|---|
| 7.1 | Logged out | Try to enable On Demand | Refused — the toggle does not stay on |
| 7.2 | Authenticated | Enable On Demand | Accepted and persists across relaunch |
| 7.3 | Logged out | Open connection screen | Login-required state presented, not a connectable one |

## Suite 8 — Network interruption

Device. Driven by automating the Settings app
(`XCUIApplication(bundleIdentifier: "com.apple.Preferences")`). Works, but is slow and
sensitive to iOS version changes — keep in a separate, non-blocking job.

| # | Precondition | Steps | Assertion |
|---|---|---|---|
| 8.1 | Connected | Airplane mode on, wait ~30 s | Stays in connecting/reconnecting; no login prompt |
| 8.2 | After 8.1 | Airplane mode off | Recovers to Connected without user action |
| 8.3 | Connected on Wi-Fi | Disable Wi-Fi, fall back to cellular | Reconnects; no login prompt while the session is valid |

## Suite 9 — App lifecycle

Device. Uses `XCUIDevice.shared.press(.home)` / `app.activate()`.

| # | Precondition | Steps | Assertion |
|---|---|---|---|
| 9.1 | Login browser open | Background the app, return | Browser still present and usable; no duplicate browser |
| 9.2 | Login in flight | Background, return after it completes | State consistent; connection proceeds |
| 9.3 | Connected | Background ~2 min, return | Still Connected; status accurate |
