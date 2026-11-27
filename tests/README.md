# テスト

`run_tests.ps1` は外部AIサービスやGUIを起動せず、画面非依存のモデル・ユースケースをFake Adapterと抽象Port経由で検証する単体テストです。環境変数ではGUI統合テストを有効にできません。

```powershell
pwsh -File .\tests\run_tests.ps1
```

WPFのXAML構築や実際のウィンドウ起動を確認するときだけ、明示スイッチを指定します。この統合テストは画面を表示し、Ataraxia.exeも起動します。

```powershell
pwsh -File .\tests\run_tests.ps1 -GuiIntegration
```

ユーザータスクデータを含む `projects/` はテスト対象にしません。
