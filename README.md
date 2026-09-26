<br/>
 <div align="center">
 <p align="center">
   <img width="234" src="https://raw.githubusercontent.com/netbirdio/netbird/main/docs/media/logo-full.png"/>
 </p>
   <p>
      <a href="https://github.com/netbirdio/netbird/blob/main/LICENSE">
        <img height="20" src="https://www.gnu.org/graphics/gplv3-88x31.png" alt="License: GPL-3.0" />
      </a>
     <a href="https://join.slack.com/t/netbirdio/shared_invite/zt-vrahf41g-ik1v7fV8du6t0RwxSrJ96A">
         <img src="https://img.shields.io/badge/slack-@netbird-red.svg?logo=slack" alt="Slack"/>
      </a>
      <a href="https://github.com/netbirdio/ios-client/actions/workflows/build.yml">
         <img src="https://github.com/netbirdio/ios-client/actions/workflows/build.yml/badge.svg" alt="Build Status"/>
      </a>
      <a href="https://github.com/netbirdio/ios-client/actions/workflows/test.yml">
         <img src="https://github.com/netbirdio/ios-client/actions/workflows/test.yml/badge.svg" alt="Test Status"/>
      </a>
   </p>
 </div>


 <p align="center">
 <strong>
   Start using NetBird at <a href="https://netbird.io/pricing">netbird.io</a>
   <br/>
   See <a href="https://netbird.io/docs/">Documentation</a>
   <br/>
    Join our <a href="https://join.slack.com/t/netbirdio/shared_invite/zt-vrahf41g-ik1v7fV8du6t0RwxSrJ96A">Slack channel</a>
   <br/>

 </strong>
 </p>

 <br>

# NetBird iOS & tvOS Client

The NetBird iOS/tvOS client allows connections from mobile devices running iOS 14.0+ and Apple TV running tvOS 17.0+ to private resources in the NetBird network.

## Install
You can download and install the app from the App Store:

[<img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" height="80">](https://apps.apple.com/app/netbird-p2p-vpn/id6469329339)

## Screenshots

<p align="center">
  <img src="https://github.com/netbirdio/ios-client/assets/32096965/f3eff73a-44e9-46e2-b63d-cce004246875" alt="mainscreen" width="250" style="margin-right: 10px;"/>
  <img src="https://github.com/netbirdio/ios-client/assets/32096965/0e73f79a-0d95-41eb-8e8e-6ed489c85b14" alt="peer-overview" width="250" style="margin-right: 10px;"/>
  <img src="https://github.com/netbirdio/ios-client/assets/32096965/a633c80e-86d0-41fe-88d0-8a7bb6cbaf66" alt="menu" width="250"/>
</p>

## Code structure
The code is divided into 4 parts:
- The main netbird Go code, included as a git submodule at `/netbird-core` from the [NetBird](https://github.com/netbirdio/netbird) repo, compiled into an xcframework. This contains most of the client logic.
- The network extension `/NetbirdNetworkExtension` that is running in the background where the compiled Go code is executed.
- The UI and app code under `/NetBird`
- The `/NetbirdKit/NetworkExtensionAdapter` that controls the extension and builds the link between UI and extension

## Requirements

- iOS 14.0+ / tvOS 17.0+
- Xcode 16.1+
- Go (version determined by the netbird submodule's `go.mod`)
- gomobile (for iOS builds)
- gomobile-netbird (for tvOS builds — NetBird's fork with tvOS support)

### gomobile

For iOS-only builds, install the standard gomobile:

```bash
go install golang.org/x/mobile/cmd/gomobile@latest
```

### gomobile-netbird

For tvOS builds, install `gomobile-netbird`, NetBird's fork of gomobile that adds tvOS support. See: https://github.com/netbirdio/gomobile-tvos-fork

```bash
go install github.com/netbirdio/gomobile-tvos-fork/cmd/gomobile-netbird@latest
```

## Run locally

The main netbird Go code is included as a git submodule at `netbird-core/`.

```bash
git clone --recursive https://github.com/netbirdio/ios-client.git
cd ios-client
```

If you already cloned without `--recursive`:
```bash
git submodule update --init --recursive
```

Build the XCFramework for iOS:
```bash
./build-go-lib.sh
```

Or for tvOS (includes iOS, iOS Simulator, tvOS, and tvOS Simulator targets):
```bash
./build-go-lib.sh --tvos
```

You can also pass an explicit version:
```bash
./build-go-lib.sh 0.2.0
./build-go-lib.sh --tvos 0.2.0
```

Open the Xcode project, and we are ready to go.

### Updating the netbird submodule

To update to a newer netbird version:
```bash
cd netbird-core
git fetch --tags
git checkout v0.x.y   # or any branch/commit
cd ..
git add netbird-core
git commit -m "update netbird submodule to v0.x.y"
```

### Running on iOS Device

> **Note:** The app cannot run in the iOS simulator. To test the app, a physical device needs to be connected to Xcode via cable and set as the run destination.

### Verifying iOS network reconnection

Network changes are sent to the Go SDK's network event manager, which suspends
retries while offline and refreshes stale connections after a handover. The iOS
extension observes physical interfaces, addresses, gateways, IP-family availability
and the active data SIM;
a SIM switch can retain the same cellular interface. Paths marked
`requiresConnection` allow dialing so the connection can activate the network.
After initial connection, confirmed path loss or SDK reconnect callbacks set iOS's
`reasserting` status; SDK connection success clears it. Stopping the tunnel or
failing authentication also clears it. The app displays this state as “Reconnecting…”
and keeps the disconnect control available. Wake events refresh connections even
when the addresses are unchanged, as recommended by [Apple’s wake documentation](https://developer.apple.com/documentation/networkextension/neprovider/wake()).
The sweep includes direct ICE agents as well as management, signal and relay
connections. Repeated changes share a bounded cleanup window so continuous
flapping cannot postpone recovery indefinitely. Policy restarts interrupted by
an outage resume when the physical network returns. Startup delegates authentication to the engine; an unreachable
management server does not by itself mean credentials expired.

“Connected” reflects management/signal connectivity, not proof that every peer
or routed resource is reachable. Verify actual traffic in the checks below.

Run `NetworkReconnectionStateTests` for event deduplication, rapid SIM changes,
offline recovery, wake handling, path capabilities, app reassertion and shutdown behavior. End-to-end handovers require a physical
dual-SIM iPhone:

1. Connect the VPN and continuously access a private peer or routed resource.
2. With Wi-Fi disabled, switch Cellular Data from SIM A to SIM B and back. Repeat
   with Allow Cellular Data Switching enabled and the app in the background.
3. Test Wi-Fi → cellular → Wi-Fi and airplane mode → recovery on the same SIM.
4. Repeat with an exit node selected; verify both private and Internet traffic recover.
5. Switch between two Wi-Fi networks, including networks with the same local
   subnet; test IPv6-only/NAT64 and dual-stack networks.
6. Lock the phone, let it sleep, then wake on the same and on a different network.
7. Start from the widget/On Demand while offline, restore connectivity, and verify
   recovery without a login prompt. Separately verify that genuinely expired
   credentials still trigger login and remove the tunnel routes.
8. Disconnect the VPN during a handover and verify it stays disconnected with
   On Demand disabled.

Check the extension log for `Network path:` and the core's
`network change: connections marked stale` messages. Simulator tests cannot
validate carrier handovers or live VPN traffic.

### Running on Apple TV

> **Note:** The app cannot run in the tvOS simulator. To test the app, a physical device running tvOS 17.0 or later needs to be [paired with Xcode](https://support.apple.com/en-us/101262).

### Firebase Configuration (Optional)

The app supports Firebase for analytics and crash reporting. To enable it, add your `GoogleService-Info.plist` file to the project root. The app will work without Firebase configuration. For a local device build without Firebase, omit this file from the targets’ Copy Bundle Resources phases. The CI test placeholder is not a production Firebase configuration. Startup skips missing or invalid Firebase settings; unit tests also skip Firebase initialization.

## Other project repositories

NetBird project is composed of multiple repositories:
- NetBird: https://github.com/netbirdio/netbird, contains the code for the agents and control plane services.
- Dashboard: https://github.com/netbirdio/dashboard, contains the Administration UI for the management service
- Documentations: https://github.com/netbirdio/docs, contains the documentation from https://netbird.io/docs
- Android Client: https://github.com/netbirdio/android-client
- iOS/tvOS Client: https://github.com/netbirdio/ios-client (this repository)
