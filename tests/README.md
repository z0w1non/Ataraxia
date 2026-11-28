# テスト

テストは対象に応じて3段階で実行します。通常の単体テストは外部AIサービス、WPF、GUI実行ファイルを起動せず、WPFアセンブリもロードしません。画面非依存のモデル・ユースケースをFake Adapterと抽象Port経由で検証します。プロジェクト操作の補償処理、プリセット値の検証失敗、2種類の設定保存の順序と失敗時の停止も確認します。通常テストの最後にWPFアセンブリがロードされていないことも検査します。

```powershell
pwsh -File .\tests\run_tests.ps1
```

WPFコントロールの構築・操作は、STAスレッドで実際のXAMLとAdapterを使って検証できます。現在はパラメータ入力とスピナー、テーマ色の切替、テーマ・モデル・プリセット選択、会話項目とスクロール位置に応じたジャンプボタン表示を確認します。ウィンドウは生成しますが表示せず、GUI実行ファイルや外部プロセスも起動しません。

```powershell
pwsh -STA -File .\tests\run_wpf_control_tests.ps1
```

WPFの実画面表示やAtaraxia.exeからの起動を確認するときだけ、明示スイッチを指定します。この統合テストは画面を表示し、Ataraxia.exeも起動します。環境変数では有効にできません。

```powershell
pwsh -File .\tests\run_tests.ps1 -GuiIntegration
```

ユーザータスクデータを含む `projects/` はテスト対象にしません。
