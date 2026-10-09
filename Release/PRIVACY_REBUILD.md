# 配布候補は計測を無効にして作り直す

配布バイナリに、テストの実行量を記録する計測情報が残っていました。この情報にはビルド元のファイル名が含まれます。通常の文字列検索や `strip -S -x` では、圧縮された部分を取り除けません。

公開 v0.1.0 のアプリZIP（SHA-256: `52f7b94e755f9c52b86022dbc6ae614f5aa21c9b9ab0621e09ff12470a4edd75`）をダウンロードし、GitHubのハッシュと一致することを確認しました。展開した実行ファイルの `__llvm_covmap` から本人ホームを含むパス1,084件、重複除外544種類を再現しました。`__llvm_prf_names` でも10,058件を確認しました。生バイト検索では0件でした。ここには実際のパスや氏名を掲載していません。

旧ビルドログにはSwiftの `-profile-generate` と `-profile-coverage-mapping` がありました。既定schemeのテストプランはcoverageを有効にしていますが、この設定だけがすべての原因だと断定する比較試験はしていません。配布スクリプトに明示的な無効化設定がなく、最終バイナリに計測領域が残ったことは確認できました。従来の監査は生バイトの候補検出を終了コードに反映しておらず、今回の混入を止められませんでした。

## 配布だけに適用する変更

`Scripts/build-release-candidate.sh` は、新しいソース・ビルドディレクトリで `clean archive` を実行します。`ENABLE_CODE_COVERAGE=NO`、`CLANG_ENABLE_CODE_COVERAGE=NO`、GCCのcoverage設定で配布計測を無効にします。SwiftとClangには匿名パスへの変換も指定します。Xcodeの `-enableCodeCoverage` はtesting専用なので、Archiveには使用しません。テストプランのcoverageは変更していません。

最終処理は計測領域を見つけた時点で停止します。監査は同梱Mach-Oの全アーキテクチャ、圧縮coverageファイル名、圧縮profile名、ZIP/JARの入れ子を検査します。候補が未解決、必須解析が失敗、上限超過、入力欠落の場合は失敗します。ディレクトリ監査では梱包する相対名とsymlinkのリンク先も検査します。ZIP作成処理は一時ファイルへ梱包し、完成ZIPを再監査します。両方の検査が成功するまで正式なZIP名とチェックサムを作りません。梱包前の監査後に内容が変わった場合も、完成ZIPの検査で停止します。

上流のライセンス、帰属、公開サンプルは保持します。公開依存物に由来する候補は `audit-reviewed-upstream.json` にファイルのSHA-256、対象種別、理由を記録します。内容が変われば再審査が必要です。本人ホームの一致は、この審査記録で許可できません。

新しいファイルに氏名を自動挿入するXcodeテンプレートを変更しました。既存の著作権表示は維持しています。追跡文書の古いローカルsnapshotと、公開履歴にない性能比較用commitへの参照も整理しました。

## 候補を作成・確認する

Macと固定済みのSwift依存物、変更前JDT、Node、JDKが必要です。既存ディレクトリを指定すると停止します。変更後の配布JDTを入力にするとハッシュ検査に失敗するため、承認済みの変更前入力を使います。

```sh
Scripts/build-release-candidate.sh /tmp/compeditor/source /tmp/compeditor/build /tmp/compeditor/packages /tmp/compeditor/servers /path/to/node /path/to/jdk
python3 Scripts/test-release-artifact-audit.py
```

成功時のアプリは `build/Candidate.xcarchive/Products/Applications/CompEditor.app` です。ローカル署名を付ける場合は、来歴とライセンスを追加してから署名し、署名後のアプリを監査・ZIP化します。ビルドログでは、実際のSwift/Clang引数に計測フラグがないことも確認します。匿名fixtureの回帰試験は圧縮・非圧縮情報、入れ子ZIP内ライブラリ、破損・未知形式、公開帰属の保持、ハッシュによる限定許可を扱います。

## 差し替えは本人が行う

1. draft PRをレビューし、本人の判断でマージします。マージ後のcommitから再ビルドする場合は、候補と来歴を再作成して監査し直します。
2. アプリZIP、実際の修正commitのソースZIP、対応する依存ソースZIP、ライセンス資料、`SHA256SUMS` を一組として保管します。来歴には修正commit、元の `aeb18ac79281506dfeffb09bc470527c24db2b60`、依存物の固定revisionとハッシュを記録します。
3. v0.1.0のタグは旧ソースを指しています。同じReleaseの添付だけを替える場合は、Release本文に「配布物を修正した日付・実際の修正commit・対応ソースの添付名」を明記してください。GitHubが自動生成するタグのソースZIPは修正版と一致しません。新しい版・タグで配布する方法も本人が判断できます。
4. 本人がGitHubの添付を差し替えた後、再ダウンロードして `SHA256SUMS`、ZIP内の来歴、監査、署名を照合してください。タグの付け替えはこの手順に含めません。

この作業は公開Releaseの削除・非公開化・差し替えを実施しません。過去に取得された旧ZIPやミラー、キャッシュは、添付の差し替えだけでは回収できません。

監査は上限付きのパターン検査です。ZIP/JARと指定したLLVM圧縮形式以外（tar.gz、JDK modulesの内部形式など）は展開しません。すべての秘密情報がないことや、同一バイトになる再ビルドを保証するものではありません。別Mac、macOS 26、Intel、全GUI機能、Developer ID署名とApple公証は今回の検証範囲外です。
