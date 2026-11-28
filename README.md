<!-- 日本語版を表示しています。English: [README/en/README.md](README/en/README.md) -->

# Ataraxia

Ataraxiaは、PowerShellとKoboldCppで動作するローカルの汎用AIエージェントです。新しいユーザークエリを受け取ると、Coreロールがクエリ、過去の結果、作業対象、利用可能なロールからワークフローを設計し、検証してから保存・実行します。同じクエリの継続では既存ワークフローを使い、次のクエリでは新しいワークフローを設計します。計画、情報収集、検証済み差分による編集、許可リストに基づくコマンド実行、レビューを行い、タスク固有のPDCAサイクルに沿って次の段階へ進みます。必要に応じて実装前に互換性、データ、依存関係、運用、利用者への影響を確認し、対策を提案します。既存タスクに保存されたワークフローは維持されます。

![Ataraxiaプロジェクトカバー](assets/splash/ataraxia-project-cover.png)

## 必要な環境

- Windows PowerShell 5.1 または PowerShell 7 以降
- ローカルのGGUFモデルを使うKoboldCpp
- 内蔵WPF GUIを使う場合はWindowsデスクトップ版PowerShell

PowerShellモジュールやローカルWebサーバーは不要です。GUIとCLIは同じタスクランナーを使います。

## 初期設定

`configs/config.example.json` を `configs/config.json` にコピーします。既定のプロジェクト名は `Ataraxia` です。必要に応じて言語と書式設定を変更します。KoboldCppへの接続、モデル、起動引数、生成パラメータは `configs/koboldcpp-settings.json` で設定します。

設定したKoboldCpp実行ファイルが見つからない場合、GUIは別の初期化スクリプトをバックグラウンドで起動します。ダウンロードするのはKoboldCppだけで、モデルのダウンロードやサーバー起動は行いません。手動で取得するには次を実行します。

```powershell
pwsh -File .\scripts\Initialize-KoboldCpp.ps1
```

初期化スクリプトの既定値 `-Build auto` は、WindowsがNVIDIAディスプレイアダプターを報告した場合はCUDA版、それ以外では `nocuda` 版を選びます。必要なら `-Build cuda`、`-Build nocuda`、`-Build oldpc` を指定します。ダウンロード後にKoboldCppを起動するには `-Launch` を追加します。

モデルは利用者が選び、`models/` 以下へ配置して `paths.model_file` に設定します。Ataraxiaはモデルをダウンロード・推奨しません。主要モデル群向けの生成プリセットはGitで管理されます。利用者による変更、選択、追加プリセットは `%LOCALAPPDATA%\Ataraxia\model-parameter-presets.json` に保存され、すべてのプロジェクトとモデルで共有されます。モデルファイルと同名のJSONは読み込みません。

## タスク、クエリ、プロンプト

**タスク**はセッションの実行定義で、現在の目標、制約、作業対象、利用可能なロール、Coreが設計したワークフローを保存します。**ユーザークエリ**は利用者が送信した1件の要求です。各クエリはセッション会話に記録され、実行中はタスクの `goal` に設定されます。**プロンプト**は、Chat APIの `messages` でロールのシステム指示と選択されたJSON入力を組み立てた、そのロールへの完全な入力です。ユーザークエリはその入力の一部であり、プロンプト全体ではありません。

各セッションには1つのタスク定義、ユーザークエリとレポートを含む会話履歴、ワークフローの進行状況と結果を保存する状態ファイルがあります。新しいユーザークエリでは毎回Coreが最初に実行されます。未完了ワークフローの再開は同じクエリを続け、完了後の再実行は文面が同じでも新しいクエリとして扱います。GUIで直近のクエリを編集して再送すると、以前の状態を分岐ファイルとして保持した新しい会話分岐を作成します。

## タスクの作成と実行

タスクテンプレートを作成します。

```powershell
pwsh -File .\scripts\Invoke-Agent.ps1 -New research-plan
```

`projects/Ataraxia/research-plan.task.json` が作成されます。CLIでは実行するユーザークエリを `goal` に設定し、必要に応じて `context`、`working_directory`、ロール定義を編集します。実行時にCoreがワークフローを設計します。全段階を実行するには次を使います。

```powershell
pwsh -File .\scripts\Invoke-Agent.ps1 -Run .\projects\Ataraxia\research-plan.task.json -Step -1
```

`-Step 1` はワークフローの1段階だけを実行します。ファイル変更が適用されるのはタスクの `working_directory` 内だけです。`configs/agent-harness.json` は実行を許可するプログラムと引数パターンを定義します。適用前にすべてのファイル変更を基準ハッシュと構造化差分で検証します。

タスク状態、ロールレポート、ユーザークエリ履歴はタスクファイルの隣に保存されます。GUIで直近のユーザークエリを編集すると新しいワークフロー分岐を作り、以前の状態を分岐ファイルに保持します。

## GUI

ダイアログ、確認、テキスト入力、ファイル・フォルダー選択にはAtaraxia独自のSVGベース画面を使います。基盤に依存しない入力・結果の契約は `configs/gui-dialog-contracts.json` にあり、`scripts/GuiDialogs.ps1` がローカライズ済みUIを構成します。エラー詳細はログへ記録し、モーダルなエラーダイアログは表示しません。ログの場所はGUIのステータス欄に表示され、起動失敗時は `%LOCALAPPDATA%\Ataraxia\logs`（使用できない場合は `%TEMP%\Ataraxia\logs`）へ保存します。

```powershell
pwsh -File .\scripts\Start-AtaraxiaGui.ps1
```

ビルド済みの薄い実行ファイルから起動する場合は `Ataraxia.exe` を使います。GUIではプロジェクト、セッション、共通プロンプト、会話分岐、テーマ、モデル、生成パラメータを管理できます。テーマはライト、ダーク、システム設定に対応し、パレットは無彩色です。接続状態の表示色もグレー系です。定義値は `configs/gui-themes.json` にあります。

## アーキテクチャと開発

`scripts/AgentCore.ps1` はタスクのワークフロー準備と段階入力を調整します。ワークフロー遷移、ロールとプロンプトの実行、状態処理、入力検証は `AgentWorkflow.ps1`、`AgentRoleExecution.ps1`、`AgentState.ps1`、`AgentValidation.ps1` に分かれています。`AgentHarness.ps1` は作業対象の安全性と許可コマンドを扱います。GUI表示とイベント結線は `Start-AtaraxiaGui.ps1`、WPFに依存しないアプリケーション処理と表示モデルは `GuiApplication.ps1` と `GuiConversationModel.ps1` にあります。段階、ロール割当、遷移条件、入出力スキーマはタスクデータとして宣言し、共通ランナーに分野固有の処理を組み込みません。タスクごとにロールを追加・変更・削除できます。

プロジェクトはテスト駆動で開発します。PowerShellテスト一式は次で実行できます。

```powershell
pwsh -File .\tests\run_tests.ps1
```

WPFコントロール、テーマ資源、会話テンプレートをウィンドウ表示なしで検証するには次を実行します。

```powershell
pwsh -STA -File .\tests\run_wpf_control_tests.ps1
```

GUI起動を含むWindows統合スモークテストは明示的に `-GuiIntegration` を指定した場合のみ実行されます。

詳細は[技術仕様書](docs/SPECIFICATION.md)、[開発要件](docs/REQUIREMENTS.md)、[アーキテクチャ再設計資料](docs/ARCHITECTURE_REDESIGN.md)を参照してください。

## 依存関係とライセンス

| コンポーネント | ライセンス・用途 |
|---|---|
| KoboldCpp | GPL-3.0。ローカル推論サーバーとして利用。モデルは別途入手。 |
| Newtonsoft.Json | MIT。配布バイナリをJSON処理に使用。 |
| Ataraxia | MIT。 |
