# ezNTFS

[English](README.md) · [简体中文](README.zh-CN.md) · 日本語

ezNTFS は、Mac で Windows の外付け NTFS ドライブを読み書きする無料のオープンソースアプリです。ドライブをつないで「読み書きでマウント」を選ぶと、フォーマットや既存のファイルをそのままに、Finder でファイルをコピーできます。

よく使うドライブは個別に自動マウントできます。大事なファイルには、コピー先を読み戻して SHA-256 を照合する「コピーして検証」が使えます。NTFS の読み書きには NTFS-3G と macFUSE を使っています。

[Apple シリコン版 0.5.3 をダウンロード](https://github.com/ixiehao/ezNTFS/releases/download/v0.5.3/ezNTFS-0.5.3-arm64-Setup.zip) · [Intel 版 0.5.3 をダウンロード](https://github.com/ixiehao/ezNTFS/releases/download/v0.5.3/ezNTFS-0.5.3-x86_64-Monterey-Setup.zip) · [リリースノートとチェックサム](https://github.com/ixiehao/ezNTFS/releases/tag/v0.5.3) · [ezNTFS 公式サイト](https://ixiehao.github.io/ezNTFS/ja/)

<img src="website/assets/ezntfs-ja.png" width="660" alt="3 台のデモ用 NTFS ドライブとマウント状態を表示する ezNTFS">

## インストール

Apple シリコン版は macOS 14 以降、Intel 版は macOS 12.7 以降に対応しています。 [Intel Mac インストールガイド（中国語）](docs/INSTALL-INTEL.zh-CN.md)

ダウンロードしたファイルを解凍して `Install ezNTFS.app` を開き、「依存コンポーネントをインストールまたは修復」を選びます。対応する macFUSE があればそのまま使い、必要な場合は公式パッケージをダウンロードして検証します。認証や機能拡張の許可、再起動は macOS の指示に従ってください。

単体の PKG を使う場合：

1. 外付けドライブ上のファイルを閉じ、ドライブを安全に取り出してからインストールやアップデートを行います。
2. macFUSE 5.5.0 のインストールは初回のみです。すでに入っている場合は、そのまま ezNTFS の PKG を開けます。[macFUSE 5.5.0 を入手](https://github.com/macfuse/macfuse/releases/tag/macfuse-5.5.0)
3. ezNTFS の PKG を開き、macOS の案内に従ってインストールを許可します。

アプリと同梱の実行ファイルには ad-hoc 署名を使用しています。PKG は未署名で、Apple の公証は受けていません。

インストール後は、アプリの環境チェックから修復できます。外付けディスクを使用中の場合は、安全に取り出してから再試行してください。

## 使い方

- **読み書きでマウント**すると、Finder でドライブに書き込めます。別の NTFS ドライバを使用中の場合は、先にアンマウントしてください。
- 自動でマウントするには、設定の「接続時に自動マウント」と、対象ドライブの「自動マウント」をオンにします。安定した識別子のないドライブは手動でマウントできます。
- **コピーして検証**はコピー先を読み戻し、ファイルごとに SHA-256 を照合します。すべて通過すると、新しいフォルダにまとめます。空のファイルやフォルダにも対応します。日付や拡張属性の保持はドライバに依存します。macOS のすべてのアクセス権やハードリンク構造、特殊ファイルは対象外です。
- 作業が終わったらファイルを閉じ、**安全に取り出す**を選びます。すべてのボリュームが取り出されます。ドライブが使用中なら、関連するウインドウやアプリを閉じてやり直してください。

ウインドウを閉じても、ezNTFS はメニューバーに残ります。「ezNTFS を開く」でウインドウを表示できます。

## ヘルプ

- macOS にディスクへのアクセスを拒否された場合は、「ヘルプ → 依存ツールを確認…」を開きます。パネルの案内に従い、マウントサービスを「フルディスクアクセス」に追加してください。[プライバシーとアクセス権](docs/PRIVACY.md)
- 「ヘルプ → アップデートを確認」で最新の安定版を確認できます。表示言語は「言語」メニューから変更できます。[問題を報告](https://github.com/ixiehao/ezNTFS/issues)

## 開発

[ドキュメント](docs/README.md) · [ビルド](docs/DEVELOPMENT.md) · [テスト](docs/QA.md) · [リリース](docs/RELEASING.md) · [貢献](CONTRIBUTING.md) · [セキュリティ](SECURITY.md)

[MIT ライセンス](LICENSE) · [サードパーティ製コンポーネント](docs/THIRD_PARTY.md)
