# MiSTer FTP

[English](README.md) | [한국어](README.ko.md)

[MiSTer FPGA](https://github.com/MiSTer-devel/Wiki_MiSTer/wiki)とMacの間でファイルをやり取りする小さなmacOSアプリです。開くだけで、ネットワーク上のMiSTerを見つけてSDカードを開きます。設定は何も必要ありません。

![MiSTerを探しているところ](docs/discovery.png)

![ファイルの閲覧とアップロード](docs/browser.png)

## インストール

macOS 15以降、AppleシリコンとIntelのどちらでも動作します。

1. [Releases](https://github.com/Simon-nhelix/mister-ftp/releases)から `MiSTer-FTP-x.y.z.zip` をダウンロードして解凍します。
2. **MiSTer FTP.app** をアプリケーションフォルダに移動します。
3. アプリを開きます。Appleの公証を受けていないため、初回はmacOSがブロックします。**完了**をクリックし、**システム設定 › プライバシーとセキュリティ**を開いて、下までスクロールし、「MiSTer FTP」の横の**このまま開く**をクリックしてください。
4. 「MiSTer FTPがローカルネットワークのデバイスを検索して接続すること」の許可をmacOSが求めてきたら、**許可**をクリックしてください。

手順3の代わりに、ターミナルでこのコマンドを実行しても構いません。

```sh
xattr -dr com.apple.quarantine "/Applications/MiSTer FTP.app"
```

## 使い方

1. MiSTerの電源を入れ、Macと同じルーターに接続します。
2. MiSTer FTPを開くと、MiSTerを見つけてSDカード（`/media/fat`）を表示します。

| やりたいこと | 操作 |
| --- | --- |
| MiSTerへアップロード | Finderからファイルやフォルダをウィンドウにドラッグ＆ドロップ、または**アップロード**（⌘U） |
| Macへダウンロード | 項目を選んで**ダウンロード**（⌘D）、ファイルをダブルクリック、または右クリック › ダウンロード先… |
| フォルダを開く | ダブルクリックまたはReturn。上のフォルダは⌘↑、戻る・進むは⌘[ ⌘] |
| 新規フォルダ · 名前変更 · 削除 | ⇧⌘N · ⌘E · ⌘⌫（右クリックメニューにもあります） |
| フォルダをお気に入りに登録・解除 | フォルダを開いてヘッダーの星マーク、または⌘B（一覧のフォルダを右クリックでも可） |
| 再検索 · アドレスに接続 | ⇧⌘R · ⌘K |

### お気に入り

よく使うフォルダをピンで留めておけます。**ストレージ**の下にある**お気に入り**グループに集まります。

- 登録：フォルダを開いてヘッダーの星をクリック、または⌘B。一覧のフォルダを右クリックしても構いません。
- サイドバーの行を右クリックすると、名前の変更、上下への移動、削除ができます。名前を空にするとフォルダのパスに戻ります。
- アプリ内でフォルダの名前を変更すると、ピン留めされた行も追従します。フォルダを削除すると行も消えます。
- お気に入りに登録したフォルダが**ショートカット**にも含まれる場合、そのグループでは非表示になります。

- ダウンロードはデフォルトで`~/Downloads`に保存されます。設定（⌘,）で変更できます。
- アップロード時、`.DS_Store`や`._*`などのmacOSの余分なファイルはスキップします。名前は合成Unicode（NFC）で保存され、FAT/exFATで保存できない文字（`\ : * ? " < > |`）は`_`に置き換えられます。
- 同じ名前の項目が既に存在する場合、置き換えるかスキップするかを確認します。
- 削除はMiSTerから即座に実行され、取り消すことはできません。

## 言語

アプリの表示言語は現在、英語と韓国語で、Macの言語設定に従います（韓国語環境では韓国語、それ以外は英語）。日本語対応は準備中です。

このアプリだけ別の言語で使いたい場合は、システム設定 › 一般 › 言語と地域の「アプリケーション」にMiSTer FTPを追加して言語を選んでください。次回アプリを開いたときに適用されます。

## アップデート

バージョン1.0.0以降、アプリは自分自身を更新します。1日に1回、GitHubに新しいリリースがあるかを確認します。新しいバージョンがあると、サイドバーにカードが表示されます（他の画面では右上にバッジ）。クリックして変更点を読み、**アップデート**をクリックしてください。アプリが新しいバージョンをダウンロードし、署名を確認して、自分自身を置き換え、再び開きます。

- 今すぐ確認するには、**MiSTer FTP › アップデートを確認…**を選びます。
- 毎日の確認を止めるには、設定（⌘,）でオフにします。
- このプロジェクトのリリースキーで署名されたファイルだけをインストールします。GitHub上や転送中に改変されたファイルは拒否します。
- ファイル転送中は、転送が終わるまでアップデートは待機します。
- 1.0.0は自己更新できません。次のバージョンは一度だけ[インストール](#インストール)の手順で手動で入れてください。
- アップデート後、macOSがローカルネットワークの使用許可を再度求めることがあります。**許可**をクリックしてください。

## MiSTerの見つけ方

アプリは3つの方法を同時に試し、最初に応答したものに接続します。

1. 前回接続したアドレス（または設定で指定した固定アドレス）
2. `MiSTer.local`という名前（マルチキャストDNS）
3. Macが属するプライベートネットワーク（通常`/24`）のポート21のスキャン

FTPサーバーがMiSTerかどうかを確認するため、ログインして`/media/fat`フォルダがあるかを調べます。ログインを試みるのは、名前または前回のアドレスで見つかったデバイス、および挨拶メッセージがProFTPD（MiSTerのデフォルトサーバー）のサーバーだけです。NASやルーターなどの他のFTPサーバーにはログインしません。

アカウントはMiSTerのデフォルトである`root` / `1`です。パスワードを変更している場合は、接続画面または設定で入力してください。変更したパスワードはキーチェーンに保存されます。

## ソースからビルド

Xcode 26（Swift 6.3）以降が必要です。

```sh
./scripts/build_app.sh --install   # リリースビルド（Appleシリコン + Intel）、/Applicationsにインストール
./scripts/build_app.sh --zip       # リリースビルドを dist/MiSTer-FTP-<version>.zip としてパック
swift test                         # 単体テスト
MISTER_FTP_TEST_HOST=192.168.1.11 swift test --filter LiveMiSTerTests   # 実機MiSTerに対するテスト
swift scripts/make_icon.swift      # アプリアイコンを再生成（Resources/AppIcon.icns）
./scripts/sync_strings.sh          # UIの文字列を Resources/Localizable.xcstrings に同期
swift scripts/update_signing.swift check   # キーチェーンのリリースキーがInfo.plistと一致するか確認
```

実機MiSTerテストはMiSTerの`/tmp`（RAM）にだけ書き込み、終了時にファイルを削除します。SDカードには書き込みません。

UIの文字列はコード内で韓国語で書かれており、その韓国語テキストが翻訳キーになります。文字列を追加・変更したら`./scripts/sync_strings.sh`を実行してください。`needs English`と表示された各文字列に英語を追加します（Xcodeでカタログを開くか、JSONを直接編集）。ビルドスクリプトがカタログを`en.lproj`と`ko.lproj`のテーブルに変換してアプリに組み込みます。

デバッグビルドはメイン画面を巡回してウィンドウのスナップショットをPNGとして保存できます。巡回のテストファイルはMiSTerの`/tmp`にだけ書き込まれます。

```sh
swift build && MISTERFTP_SNAPSHOT_DIR=/tmp/misterftp-shots MISTERFTP_DEMO=1 .build/debug/MiSTerFTP
```

`MISTERFTP_DEMO=dialogs`は削除・名前変更・新規フォルダ・置き換えダイアログの実際のボタンを押し、MiSTer上で結果を確認します。これも`/tmp`でだけ動作します。`MISTERFTP_DEMO=updateui`はネットワークなしでアップデート画面を表示します（バージョン番号を持つアプリバンドル内から実行してください）。

```sh
swift build && MISTERFTP_DEMO=dialogs .build/debug/MiSTerFTP
```

デバッグビルドには翻訳テーブルがないため、コードの韓国語がそのまま表示されます。英語を表示するには、テーブルをデバッグビルドの横に置いて言語を指定します。

```sh
for c in Resources/*.xcstrings; do xcrun xcstringstool compile "$c" -o "$(swift build --show-bin-path)"; done
.build/debug/MiSTerFTP -AppleLanguages '(en)'
```

## 新しいバージョンのリリース

アップデータはリリースキーで署名されたアーカイブだけをインストールします。秘密鍵はリリースを作るMacのログインキーチェーンにだけ存在します（項目名「MiSTer FTP update signing key」）。`Resources/Info.plist`には対応する公開鍵（`MFTPUpdatePublicKey`）と確認するリポジトリ（`MFTPUpdateRepository`）が入っています。

1. Macごとに一度、`swift scripts/update_signing.swift generate`を実行します。キーが既に存在する場合、このコマンドは公開鍵だけをInfo.plistに書き込みます。キーチェーン項目は必ずバックアップしてください。失うと、インストール済みのアプリは自己更新できなくなり、全員が次のバージョンを手動でダウンロードすることになります。
2. `Resources/Info.plist`で新しいバージョンを設定します: `CFBundleShortVersionString`と、より大きい`CFBundleVersion`。
3. `./scripts/build_app.sh --zip`を実行します。`dist/MiSTer-FTP-<version>.zip`とその署名`dist/MiSTer-FTP-<version>.zip.sig`が生成されます。
4. 両方のファイルを`v<version>`タグのリリースで公開します。リリースノート（Markdown）はアプリのアップデートウィンドウにそのまま表示されます。

```sh
gh release create v1.0.1 dist/MiSTer-FTP-1.0.1.zip dist/MiSTer-FTP-1.0.1.zip.sig --title "MiSTer FTP 1.0.1" --notes-file NOTES.md
```

アプリは`releases/latest`を読むため、ドラフトとプレリリースは表示されません。

## プロジェクト構成

```text
Sources/FTPKit/      FTPクライアント（POSIXソケット、パッシブモード、MLSD）、リストパーサー、LAN探索
Sources/UpdateKit/   アップデータ: GitHubリリースフィード、Ed25519署名確認、ダウンロードとアプリ置き換え
Sources/MiSTerFTP/   SwiftUIアプリ: 探索画面、ファイルブラウザ、転送キュー、設定、アップデート
Tests/FTPKitTests/   パーサーテストと実機MiSTerテスト
Tests/UpdateKitTests/ 署名済みテストアプリによるアップデートテスト
scripts/             アプリバンドルのビルドとインストール、リリース署名、アプリアイコン、文字列同期
Resources/           Info.plist、AppIcon.icns、文字列カタログ（Localizable、InfoPlist）
docs/                READMEのスクリーンショット
```

## ライセンス

MIT。[LICENSE](LICENSE)を参照してください。
