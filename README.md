# MiSTer FTP

[한국어](README.ko.md)

A small macOS app for moving files between your Mac and a [MiSTer FPGA](https://github.com/MiSTer-devel/Wiki_MiSTer/wiki). Open it, and it finds the MiSTer on your network and opens its SD card. There is nothing to set up.

![Looking for the MiSTer](docs/discovery.png)

![Browsing and uploading](docs/browser.png)

## Install

Requires macOS 15 or later, on Apple silicon or Intel.

1. Download `MiSTer-FTP-x.y.z.zip` from [Releases](https://github.com/Simon-nhelix/mister-ftp/releases) and unzip it.
2. Move **MiSTer FTP.app** to your Applications folder.
3. Open it. The app is not notarized by Apple, so macOS blocks it the first time. Click **Done**, then open **System Settings › Privacy & Security**. Scroll down and click **Open Anyway** next to "MiSTer FTP".
4. When macOS asks to let MiSTer FTP find and connect to devices on your local network, click **Allow**.

Instead of step 3, you can run this command in Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/MiSTer FTP.app"
```

## Use

1. Turn on the MiSTer and connect it to the same router as your Mac.
2. Open MiSTer FTP. When it finds the MiSTer, it shows the SD card (`/media/fat`).

| To do this | Do this |
| --- | --- |
| Upload to the MiSTer | Drag files or folders from Finder onto the window, or click **Upload** (⌘U) |
| Download to the Mac | Select items and click **Download** (⌘D), double-click a file, or right-click › Download To… |
| Open a folder | Double-click or press Return. Enclosing folder: ⌘↑. Back and forward: ⌘[ ⌘] |
| New folder · Rename · Delete | ⇧⌘N · ⌘E · ⌘⌫ (also in the right-click menu) |
| Pin or unpin a folder | Open it and click the star in the header, or press ⌘B (also right-click a folder in the list) |
| Search again · Connect to an address | ⇧⌘R · ⌘K |

### Favorites

You can pin the folders you keep going back to. They gather in a **Favorites** group in the sidebar, under **Storage**.

- To pin: open the folder and click the star in the header, or press ⌘B. You can also right-click a folder in the list.
- Right-click a row in the sidebar to rename it, move it up or down, or remove it. An empty name goes back to the folder path.
- Rename a folder inside the app and its pinned row follows. Delete the folder and the row goes away.
- A pinned folder that is also one of the **Shortcuts** is hidden from that group.

- Downloads go to `~/Downloads`. You can change the folder in Settings (⌘,).
- Uploads skip macOS junk files such as `.DS_Store` and `._*`. Names are stored in composed Unicode (NFC), and characters that FAT/exFAT can't store (`\ : * ? " < > |`) become `_`.
- If an item with the same name already exists, the app asks whether to replace it or skip it.
- Delete removes items from the MiSTer right away. You can't undo it.

## Language

The app is in English and Korean, and it follows your Mac's language: Korean shows Korean, and every other language shows English.

To use a different language for this app only, open System Settings › General › Language & Region, add MiSTer FTP under Applications, and choose a language. The change applies the next time you open the app.

## Updates

After version 1.0.0, the app updates itself. Once a day it asks GitHub whether a new release is out. When there is one, a card appears in the sidebar (on the other screens, a badge at the top right). Click it to read what's new, then click **Update**. The app downloads the new version, checks its signature, replaces itself, and opens again.

- To check now, choose **MiSTer FTP › Check for Updates…**.
- To stop the daily check, turn it off in Settings (⌘,).
- The app installs only files signed with this project's release key. It refuses a file that was changed on GitHub or on the way.
- While files are transferring, the update waits until the transfers finish.
- Version 1.0.0 can't update itself. Install the next version by hand once, as described in [Install](#install).
- After an update, macOS may ask again to let the app use the local network. Click **Allow**.

## How it finds the MiSTer

The app tries three ways at the same time and connects to the first one that answers:

1. The address it connected to last time (or a fixed address that you set in Settings)
2. The name `MiSTer.local` (multicast DNS)
3. A scan of port 21 on your Mac's private network (usually a `/24`)

To make sure an FTP server is a MiSTer, the app logs in and looks for the `/media/fat` folder. It logs in only to a device found by name or by the last address, or to a server whose greeting says ProFTPD (the MiSTer default server). It does not log in to other FTP servers, such as a NAS or a router.

The account is the MiSTer default, `root` / `1`. If you changed the password, enter it on the connection screen or in Settings. The app saves a changed password in your keychain.

## Build from source

Requires Xcode 26 (Swift 6.3) or later.

```sh
./scripts/build_app.sh --install   # release build (Apple silicon + Intel), installed to /Applications
./scripts/build_app.sh --zip       # release build, packed as dist/MiSTer-FTP-<version>.zip
swift test                         # unit tests
MISTER_FTP_TEST_HOST=192.168.1.11 swift test --filter LiveMiSTerTests   # tests against a real MiSTer
swift scripts/make_icon.swift      # draw the app icon again (Resources/AppIcon.icns)
./scripts/sync_strings.sh          # collect UI strings into Resources/Localizable.xcstrings
swift scripts/update_signing.swift check   # the release key in the keychain matches Info.plist
```

The live tests write only to `/tmp` on the MiSTer (RAM) and remove their files at the end. They never write to the SD card.

UI strings are written in Korean in the code, and the Korean text is the translation key. After you add or change a string, run `./scripts/sync_strings.sh`. Then add English for each string that it lists as `needs English` (open the catalog in Xcode, or edit the JSON). The build script turns the catalogs into `en.lproj` and `ko.lproj` tables in the app.

Debug builds can tour the main screens and save window snapshots as PNG files. The tour writes test files only to `/tmp` on the MiSTer.

```sh
swift build && MISTERFTP_SNAPSHOT_DIR=/tmp/misterftp-shots MISTERFTP_DEMO=1 .build/debug/MiSTerFTP
```

`MISTERFTP_DEMO=dialogs` presses the real buttons in the Delete, Rename, New Folder and Replace dialogs, then checks the result on the MiSTer. It also works only under `/tmp`. `MISTERFTP_DEMO=updateui` shows the update screens without the network (run it from an app bundle, so the app has a version number).

```sh
swift build && MISTERFTP_DEMO=dialogs .build/debug/MiSTerFTP
```

A debug build has no translation tables, so it shows the Korean text from the code. To see English, put the tables next to the debug build and choose the language:

```sh
for c in Resources/*.xcstrings; do xcrun xcstringstool compile "$c" -o "$(swift build --show-bin-path)"; done
.build/debug/MiSTerFTP -AppleLanguages '(en)'
```

## Release a new version

The updater installs only archives signed with the release key. The private key stays in the login keychain of the Mac that makes releases (item "MiSTer FTP update signing key"). `Resources/Info.plist` carries the matching public key (`MFTPUpdatePublicKey`) and the repository to check (`MFTPUpdateRepository`).

1. Once per Mac, run `swift scripts/update_signing.swift generate`. If the key already exists, the command only writes its public key to Info.plist. Back up the keychain item. Without it, installed copies can't update themselves, and everyone has to download the next version by hand.
2. Set the new version in `Resources/Info.plist`: `CFBundleShortVersionString`, and a higher `CFBundleVersion`.
3. Run `./scripts/build_app.sh --zip`. It makes `dist/MiSTer-FTP-<version>.zip` and its signature, `dist/MiSTer-FTP-<version>.zip.sig`.
4. Publish both files in a release tagged `v<version>`. The app shows the release notes (Markdown) in its update window.

```sh
gh release create v1.0.1 dist/MiSTer-FTP-1.0.1.zip dist/MiSTer-FTP-1.0.1.zip.sig --title "MiSTer FTP 1.0.1" --notes-file NOTES.md
```

The app reads `releases/latest`, so drafts and pre-releases are never offered.

## Project layout

```text
Sources/FTPKit/      FTP client (POSIX sockets, passive mode, MLSD), list parser, LAN discovery
Sources/UpdateKit/   updater: GitHub release feed, Ed25519 signature check, download and app swap
Sources/MiSTerFTP/   SwiftUI app: discovery screen, file browser, transfer queue, settings, updates
Tests/FTPKitTests/   parser tests and live MiSTer tests
Tests/UpdateKitTests/ updater tests with signed test apps
scripts/             app bundle build and install, release signing, app icon, string sync
Resources/           Info.plist, AppIcon.icns, string catalogs (Localizable, InfoPlist)
docs/                README screenshots
```

## License

MIT. See [LICENSE](LICENSE).
