# Ataraxia

Ataraxia is a local, domain-independent AI agent built with PowerShell and KoboldCpp. At the start of every new user query, the core role designs a fresh workflow from the user query, prior results, workspace, and available roles; Ataraxia validates it before saving and execution. Continuing the same user query keeps its workflow, while a later user query gets a new one. The agent can plan, gather evidence, edit files through verified diffs, run explicitly allowlisted commands, review results, and route the next step through a task-specific PDCA cycle. When useful, an impact review before implementation checks compatibility, data, dependency, operational, and user-visible effects and suggests mitigations. Existing tasks keep their saved workflow.

![Ataraxia project cover](assets/splash/ataraxia-project-cover.png)

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- KoboldCpp with a local GGUF model
- Windows desktop PowerShell for the built-in WPF GUI

No PowerShell modules or local web server are required. The GUI and CLI use the same task runner.

## Configure

Copy `configs/config.example.json` to `configs/config.json`. The default project name is `Ataraxia`. Set the language and formatting options as needed. KoboldCpp connection, model, startup arguments, and generation parameters are in `configs/koboldcpp-settings.json`.

The GUI starts the separate initializer in the background when the configured KoboldCpp executable is missing. It downloads only KoboldCpp; it does not download a model or start the server. To acquire it manually instead, run:

```powershell
pwsh -File .\scripts\Initialize-KoboldCpp.ps1
```

The initializer defaults to `-Build auto`: it selects the CUDA build when Windows reports an NVIDIA display adapter, and the `nocuda` build otherwise. Override it with `-Build cuda`, `-Build nocuda`, or `-Build oldpc` when needed. Add `-Launch` to start KoboldCpp after download and model configuration.

Choose a model yourself, place it under `models/`, and set `paths.model_file`. Ataraxia does not download or recommend models.

## Tasks, user queries, and prompts

A **task** is the saved execution definition for a session: its current goal, constraints, working directory, available roles, and the workflow designed by Core. A **user query** is one user submission. Each user query is recorded in the session conversation and copied into the task's `goal` while it runs. A **prompt** is the complete input sent to the model for one role, assembled from that role's system instructions and selected JSON input in Chat API `messages`. The user query is part of those inputs; it is not itself the whole prompt.

Each session has one task definition, a conversation history containing user queries and reports, and a state file containing workflow progress and results. Core runs first for every new user query. Resuming an unfinished workflow continues the same user query; after completion, running again starts a new user query even if its text is unchanged. Editing and resending the latest user query creates a new conversation branch.

## Create and run a task

Create a task template:

```powershell
pwsh -File .\scripts\Invoke-Agent.ps1 -New research-plan
```

This creates `projects/Ataraxia/research-plan.task.json`. For CLI use, set its `goal` to the user query to execute and edit `context`, `working_directory`, and role definitions as needed. Core designs the workflow when the task is run. Then run the complete workflow:

```powershell
pwsh -File .\scripts\Invoke-Agent.ps1 -Run .\projects\Ataraxia\research-plan.task.json -Step -1
```

Use `-Step 1` to execute one workflow stage. The task's `working_directory` is the only location where file changes are applied. `configs/agent-harness.json` defines the permitted executables and argument patterns. Every file change is validated against its base hash and structured diff before application.

Task state, role reports, and user query history live beside the task file. Editing the latest user query in the GUI starts a new workflow branch and preserves the prior state as a branch file.

## GUI

Dialogs, confirmations, text prompts, and file/folder selection use Ataraxia's custom SVG-based interface. Their platform-neutral inputs and results are defined in `configs/gui-dialog-contracts.json`; the current WPF renderer is in `scripts/GuiDialogs.ps1`, so a future GUI framework can replace the renderer while retaining the dialog contracts.

Dialogs, confirmations, text prompts, and file/folder selection use Ataraxia's custom SVG-based interface. Their platform-neutral inputs and results are defined in `configs/gui-dialog-contracts.json`; the current WPF renderer is in `scripts/GuiDialogs.ps1`, so a future GUI framework can replace the renderer while retaining the dialog contracts.

Launch the standard Windows WPF interface with the thin executable wrapper:

```powershell
.\Ataraxia.exe
```

The interface replaces Windows default control chrome with custom vector templates. Action icons live in `assets/ui-icons/`, and role icons live in `assets/role-icons/`; edit these SVG files to adjust their outlines. Text entry and selection remain native WPF controls for reliable keyboard and accessibility behavior.

The wrapper locates PowerShell 7 (`pwsh.exe`) or Windows PowerShell, then forwards its arguments to `scripts/Start-AtaraxiaGui.ps1`. PowerShell scripts use UTF-8 with BOM so Windows PowerShell 5.1 can read Japanese text correctly. Startup displays `assets/splash/ataraxia-project-cover.png`; branding artwork and the executable icon are stored under `assets/branding/`. Startup errors show the selected PowerShell path and its error output. The wrapper includes no PowerShell runtime or third-party library. To skip the startup cover:

```powershell
.\Ataraxia.exe -NoSplash
```

Rebuild the wrapper and its classical serif “A” icon on Windows with the built-in .NET Framework C# compiler:

```powershell
pwsh -File .\tools\Build-Ataraxia.ps1
```

The left project drawer lists folders under `projects/`. Use the new-session icon at the right edge of a project row to open an empty session screen for that project, or use the project controls to switch, create, or rename projects. A session ID and its files are created only after you submit a non-empty first user query. Creating a project also switches to it. Renaming moves its folder and updates the active setting when applicable; a name collision is rejected. A collapsible **Recent sessions** section below the project list shows up to `gui.recent_sessions_max` sessions ordered by their latest user query (default 5). Selecting one switches to its project and opens that session. Each project keeps independent sessions under `projects/<project>/sessions/<session-id>/`, including its task, conversation, workflow state, and workspace. Use the session selector at the upper right to switch contexts, **Rename** to change a session title, and the document-plus icon button to start a new session (hover for its localized tooltip). The first user query automatically gives a new session a concise title; a title you set manually is preserved. Project and session common prompts can be edited independently; both are added to every role system message together with the current user query. Project, session, file, and run controls use compact icons with localized tooltips. The conversation uses a chat layout: user queries appear as right-aligned bubbles and role reports as left-aligned bubbles. Text remains selectable; report headings expand or collapse their bodies. When you scroll up through a long conversation, a centered down-arrow above the user query box jumps to the latest entry. Edit the latest user query and run it again to create a new branch. Choose Light, Dark, or System for the achromatic interface theme. The **Model parameters** section provides bounded slider and numeric controls plus text inputs for generation settings; changes are saved to the referenced `configs/koboldcpp-settings.json`.

The KoboldCpp status indicator shows connected (green), starting (orange), or disconnected (red). Use **Start KoboldCpp** to launch the configured local executable with the selected model and its settings, **Stop KoboldCpp** to stop the instance started by this GUI, or **Restart** to save the visible parameter settings, stop that managed instance, wait for its API port to close, and launch it again. Restart is unavailable for an externally started process. If the configured KoboldCpp executable is missing, the GUI downloads it in the background at startup through the separate initializer. This does not download a model or launch the server; set `paths.model_file` and use Start KoboldCpp when ready. A process started by the GUI is stopped when the GUI closes. An already reachable API is shown as connected and is not stopped by the GUI.

## Architecture and policy

Common execution logic is in `scripts/AgentCore.ps1`; task I/O and guarded workspace changes are in `scripts/AgentHarness.ps1`. Workflow stages, role assignments, transition conditions, and input/output schemas are structured task data, not domain-specific code. Tasks may add, change, or remove their own roles.

The project is test-driven. Run the PowerShell checks with:

```powershell
pwsh -File .\tests\run_tests.ps1
```

JSON inputs are read as bounded UTF-8 files, model replies must contain a JSON document, and declared schemas are enforced locally. Prompt fit is determined only by KoboldCpp token counts for the complete messages and reserved response; it is not estimated or capped by character count. Requests, workspace paths and diffs, API endpoints, and allowlisted command arguments and output are validated at their boundaries.

## Dependencies and licenses

| Component | License / use |
|---|---|
| Ataraxia | MIT; see [LICENSE](LICENSE). |
| PowerShell and Windows WPF | Platform-provided runtimes; no bundled libraries. |
| KoboldCpp | Separate optional executable. Its AGPL-3.0 and bundled-component notices remain applicable. Ataraxia does not redistribute it. |
| GGUF models and user-provided files | Governed by their respective providers and owners. |

Ataraxia does not include model files. Review each model's license and hardware requirements before use. Process separation alone does not settle legal questions about a distribution or integration; assess applicable licenses individually.

