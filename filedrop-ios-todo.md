# File drop — iOS todo

Az Android klienshez (`../android-client`, `app/src/main/java/io/netbird/client/ui/files/`)
képest hiányzó funkciók és az iOS design-nyelvtől való eltérések.

Deployment target: **iOS 15.0** — a javaslatok ehhez igazodnak (nincs
`ContentUnavailableView` (17), nincs `scrollContentBackground` / `presentationDetents` (16)
availability-gate nélkül).

## Funkcionális eltérések

- [ ] **Share Extension** — Androidon a `ShareTargetActivity` `ACTION_SEND` /
      `ACTION_SEND_MULTIPLE` intent-filterrel bármelyik appból elérhető, ez a fő
      küldési útvonal. iOS-en nincs share target (a `project.pbxproj`-ban csak
      Network- és Widget-extension van), így csak az appon belül,
      `fileImporter`-rel lehet küldeni. Új target kell, app group staging
      (`filedrop-outbox`) és NE-kommunikáció az extensionből. *(nagy darab)*
- [x] **Küldés a peer sorából** — Android: `PeerDetailFragment:241` →
      `SendPickerSheet.forPeer(fqdn)`, előre kitöltött peer-kereséssel.
      iOS-en a `PeerTabView`-ban nincs ilyen belépési pont.
- [x] **Tap a kész bejövő átvitelen = megnyitás** — Android: sor tap →
      `ACTION_VIEW` chooser. iOS-en (`iOSFilesView.swift`) a sor `contentShape`-et
      kap, de nincs `onTapGesture`; a "Save or share" csak long-press context
      menüben él. Kell: tap → QuickLook preview.
- [x] **Látható másolás-akció a text-soron** — Androidon a bejövő szöveg sora a
      status oszlopot cseréli vágólap-ikonra; iOS-en a Copy csak context menüben van.
- [x] **Vágólap-küldés** — `SendPickerSheet` felkínálja a vágólap tartalmát
      előnézettel. iOS-en a Text fül üres `TextField`, kézzel kell beilleszteni.
- [x] **Stop akció elérhetősége** — iOS-en a Remove swipe-ból is megy, a Stop csak
      context menüből. Legyen swipe/expliict gomb a futó átvitelre is.
- [x] **Polling helyett push** — `FilesViewModel.swift:131` 2 mp-es `Timer`;
      Androidon `FileDropManager.TransfersListener` push. Minimum: leállítás
      háttérbe lépéskor, és ritkítás, ha nincs futó transfer.

## Design-nyelvi eltérések

- [x] **Dynamic Type** — `.font(.system(size: 15/14/13))` végig az `iOSFilesView`-ban
      és a `FileSendView`-ban; a szövegméret nem skálázódik. (Android `sp`-t használ,
      tehát ott skálázódik — a portolás során veszett el.) Helyette szemantikus
      stílusok: `.body` / `.subheadline` / `.footnote`.
- [x] **Kevert háttér / lista-stílus** — `ZStack { Color("BgMenu") }` alatt
      `InsetGroupedListStyle`, aminek saját háttere van, így a `BgMenu` nem is
      látszik, és a Files fül más hátteret ad, mint a végig custom kártyás
      `iOSPeersView`. Egységesíteni kell (natív lista **vagy** app-stílusú kártyák).
- [x] **"Copied" toast törlése** — `iOSFilesView.swift:163` a Toast közvetlen
      átirata; iOS-en a másolás visszajelzés nélkül (esetleg haptikával) történik.
- [x] **`confirmationDialog` a deprecated `Alert` helyett** — a
      `Alert(title:message:primaryButton:secondaryButton:)` iOS 15 óta deprecated;
      a Stop/Remove destruktív választás natív formája a confirmation dialog.
      Érinti: `iOSFilesView` (stop/remove) és `FileSendView` (stop sending).
- [x] **Natív gomb-stílusok** — az Accept/Decline kézzel rajzolt
      (`Color.accentColor` + `cornerRadius(8)` + `PlainButtonStyle`) a
      `.borderedProminent` / `.bordered` utánzata; List-soron belüli custom
      gomboknál ráadásul ütközik a soros tap-target.
- [x] **Notification action-ök az offerre** — a `PacketTunnelProvider` már küld
      local notificationt bejövő ajánlatról; `UNNotificationAction`-ökkel
      Accept/Decline közvetlenül az értesítésből mehetne. Ez dönti el az
      "ask every time" mód használhatóságát, és Android nem tudja így.
- [x] **Send sheet interakció** — `FileSendView.swift:262`: "tap a peerre =
      azonnali küldés, második tap = stop" rejtett és visszafordíthatatlan.
      iOS-en explicit Send gomb / állapot a sor végén a szokás. A toolbar "Done"
      is rossz szó egy elvethető sheeten — "Cancel" + explicit akció.
- [x] **Többsoros szövegküldés** — most egysoros `TextField`; `TextEditor` +
      paste gomb kellene.
- [x] **Üres állapot és keresés** — a `content` üres ágán nincs lista, ezért a
      `.searchable` mező viselkedése ugrál. Üres állapot legyen a listán belül.
- [x] **Pull-to-refresh + haptika** — `.refreshable` a naplóra, haptikus
      visszajelzés küldésre/elfogadásra.
- [x] **Színek** — hardcode-olt `.red` / `.green` és `.accentColor` keveredik;
      semantikus rendszerszínek + a brand narancs asset legyen egységesen
      (Android: `nb_danger`, `nb_latency_good`, `nb_orange`).
- [x] **Lokalizáció** — Androidon minden string `strings.xml`-ben (`file_drop_*`,
      `file_sharing_*`); iOS-en minden literál a Swift kódban, `.lproj` nincs a
      projektben, tehát jelenleg nem lokalizálható.

## Amiben az iOS előrébb tart (nem todo, csak jegyzet)

A kész letöltések a Documents-be kerülnek és a Files appban látszanak
(`Info.plist` + `FilesViewModel.relocateDelivered`); Androidon csak FileProvider-es
"open" van.

## Nyitva maradt

- [ ] **Share Extension** — új Xcode target, entitlementek és provisioning kell
      hozzá; a `project.pbxproj` kézi szerkesztése helyett Xcode-ban érdemes
      létrehozni. A megosztott staging (`FilesViewModel.stageFiles` +
      `filedrop-outbox`) és a `FileDropSendRequest` már készen áll rá.
- [ ] **`NetBird/en.lproj/Localizable.strings` hozzáadása a targethez** — a fájl
      megvan, de amíg nincs a NetBird target Copy Bundle Resources fázisában, a
      kulcsok a beégetett angol `value:` fallbackre esnek vissza (a felület
      helyesen működik, csak nem lokalizálható). Xcode-ban egy behúzás.
