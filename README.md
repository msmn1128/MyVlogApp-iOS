# MyVlog.（iOS）

撮った動画を並べて、ひとことと撮影時刻を焼き込み、1本のVLOGとして書き出すiOSアプリ。

- バンドルID: `com.msmn1128.myvlogapp`
- iOS 17 以降、SwiftUI・AVFoundation（プレビューも書き出しも OS の機能だけで行い、外部ライブラリは使わない）
- Xcode 27 でビルド・テストしている

> 実機での確認はまだ済んでいない（シミュレータの単体テスト・UIテストは通している）。
> 書き出し・HDR の素材・取り込み・ひとこと欄のタップは、実機で確かめてから配布する予定。

## できること

- 写真ライブラリやファイルから動画を追加し、撮影日時の順に並べる
- クリップごとに使う範囲を波形の上で切り出す（2秒・4秒のワンタップもある）
- 「ひとこと」を入れ、再生位置で区切って区間ごとに文言を変える（動画自体は切らない）
- タイトルカード（撮影日または自由入力）を付けて、1920x1080 の1本の動画として写真に書き出す
- 編集内容は自動で保存され、名前を付けて最大20件まで残せる（動画の実体はコピーせず、参照だけを保存する）

## ビルドとテスト

`MyVlogApp.xcodeproj` を Xcode で開き、スキーム `MyVlogApp` を実行する。コマンドラインからは:

```bash
xcodebuild test -project MyVlogApp.xcodeproj -scheme MyVlogApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO
```

- `MyVlogAppTests`：単体テスト（Swift Testing）。書き出した動画のコマを読んで、文字の位置・色・尺・音声まで確かめるテストを含む
- `MyVlogAppUITests`：画面操作のテスト（XCTest）。テスト用の動画をアプリ自身が作ってタイムラインへ入れるので、写真ライブラリは要らない。
  保存先は使い捨ての領域に切り替わるので、シミュレータに残っている編集内容は壊れない
- 並列（シミュレータの複製）で流すと、重いときに時間切れで落ちるテストがあるため `-parallel-testing-enabled NO` で流している

実機で動かすときは、Signing & Capabilities の Team を自分のものに変えること。

## プライバシー

動画の実体・撮影内容・個人情報を外部サーバーへ送信することはない。処理はすべて端末内で完結する（広告・アナリティクスSDKなし）。

## ライセンス

- **このリポジトリのソースコード**：MIT ライセンス（[LICENSE](./LICENSE)）。
  FFmpeg などの GPL のライブラリを使っていないので、アプリも MIT のまま配布できる。
- 同梱の素材（`MyVlogApp/Resources/fonts/`・`sfx/`）はそれぞれの配布元のライセンスに従う。
  アプリ内の「ライセンス」（「編集内容の保存」ダイアログから開く）にも、フォントの著作権表示を載せている。
  - M PLUS U（`MPLUSU-Regular.ttf`）：Copyright 2025 The M+ FONTS Project Authors。[SIL Open Font License 1.1](https://openfontlicense.org)
  - 07ロゴたいぷゴシック7（`LogoTypeGothic.otf`）：Copyright (c) 2013 M+ FONTS PROJECT／[フォントな](http://www.fontna.com)
  - タイトルの効果音（`sfx/title.mp3`）：表記の要らない素材
