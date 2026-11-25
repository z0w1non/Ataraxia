# Tests

`run_tests.ps1` は外部AIサービスへ接続せず、プロジェクトの設定・role contracts・PowerShell 実装契約を検証する単体テストです。

```powershell
pwsh -File .\tests\run_tests.ps1
```

ユーザータスクデータを含む `projects/` はテスト対象にしません。
