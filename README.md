<br/>
 <div align="center">
 <p align="center">
   <img width="234" src="https://raw.githubusercontent.com/netbirdio/netbird/main/docs/media/logo-full.png"/>
 </p>
   <p>
      <a href="https://github.com/netbirdio/netbird/blob/main/LICENSE">
        <img height="20" src="https://www.gnu.org/graphics/gplv3-88x31.png" />
      </a>
     <a href="https://join.slack.com/t/netbirdio/shared_invite/zt-vrahf41g-ik1v7fV8du6t0RwxSrJ96A">
         <img src="https://img.shields.io/badge/slack-@netbird-red.svg?logo=slack"/>
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
- The main netbird Go code from the [NetBird](https://github.com/netbirdio/netbird) repo which is compiled into an xcframework. This contains most of the client logic.
- The network extension /NetbirdNetworkExtension that is running in the background where the compiled Go code is executed.
- The UI and app code under `/NetBird`
- The `/NetbirdKit/NetworkExtensionAdapter` that controls the extension and builds the link between UI and extension

## Requirements

- iOS 14.0+ / tvOS 17.0+
- Xcode 15.0+
- gomobile (with tvOS support - see build instructions)

## Run locally

To build the app, this repository and the main netbird repository are needed.

```
git clone https://github.com/netbirdio/netbird.git
git clone https://github.com/netbirdio/ios-client.git
```

Building the xcframework from the main netbird repo. This needs to be stored in the root directory of the app.

**For iOS only:**
```bash
cd netbird
gomobile bind -target=ios -bundleid=io.netbird.framework -o ../ios-client/NetBirdSDK.xcframework ./client/ios/NetBirdSDK
```

**For iOS + tvOS (requires gomobile fork with tvOS support):**
```bash
cd netbird
gomobile bind -target=ios,tvos -bundleid=io.netbird.framework -o ../ios-client/NetBirdSDK.xcframework ./client/ios/NetBirdSDK
```

Open the Xcode project, and we are ready to go.

### Running on iOS Device

> **Note:** The app cannot run in the iOS simulator. To test the app, a physical device needs to be connected to Xcode via cable and set as the run destination.

### Running on Apple TV

> **Note:** The app cannot run in the tvOS simulator. To test on Apple TV:
>
> 1. **Pair Apple TV with Xcode:**
>    - Ensure your Mac and Apple TV are on the same Wi-Fi network
>    - On Apple TV: Settings → Remotes and Devices → Remote App and Devices
>    - In Xcode: Window → Devices and Simulators (⇧⌘2)
>    - Select your Apple TV from "Discovered" and click "Pair"
>    - Enter the 6-digit code shown on your Apple TV
>
> 2. **Enable Developer Mode on Apple TV (tvOS 16+):**
>    - Settings → Privacy & Security → Developer Mode → ON
>    - Apple TV will restart
>
> 3. **Build and Run:**
>    - Select the "NetBird TV" scheme in Xcode
>    - Choose your paired Apple TV as the run destination
>    - Press ⌘R to build and run
>
> **Minimum Requirement:** Apple TV must be running tvOS 17.0 or later for VPN support.

## Other project repositories

NetBird project is composed of multiple repositories:
- NetBird: https://github.com/netbirdio/netbird, contains the code for the agents and control plane services.
- Dashboard: https://github.com/netbirdio/dashboard, contains the Administration UI for the management service
- Documentations: https://github.com/netbirdio/docs, contains the documentation from https://netbird.io/docs
- Android Client: https://github.com/netbirdio/android-client
- iOS/tvOS Client: https://github.com/netbirdio/ios-client (this repository)
