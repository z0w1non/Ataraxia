<!-- English version. 日本語: [README.md](../../README.md) -->

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

Choose a model yourself, place it under `models/`, and set `paths.model_file`. Ataraxia does not download or recommend models. The repository includes Git-managed generation presets for major model families; user changes, selections, and additional presets are kept in `%LOCALAPPDATA%\Ataraxia\model-parameter-presets.json`, shared across projects and models. Same-stem JSON files beside model files are not loaded.

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

Dialogs, confirmations, text prompts, and file/folder selection use Ataraxia's custom SVG-based interface. Their platform-neutral inputs and results are defined in `configs/gui-dialog-contracts.json`; `scripts/GuiDialogs.ps1` builds localized contracts and routes results through injected contract, text, result, renderer, and path-picker dependencies. `scripts/adapters/WpfDialogAdapter.ps1` only renders contracts and handles WPF interaction, while `scripts/adapters/PowerShellDialogPathAdapter.ps1` supplies filesystem entries. This keeps dialog behavior behind application abstractions while WPF remains the current GUI framework.

The main window and startup splash markup live in `scripts/presentation/` as standalone XAML assets. Project and session actions are coordinated by WPF independent functions in `scripts/GuiApplication.ps1`. `GuiPresentationPort.ps1` defines framework-neutral view updates, actions, deferred callbacks, periodic timers, and responsive delays, while `adapters/WpfGuiViewAdapter.ps1` maps them to WPF controls, events, and dispatcher scheduling and `adapters/WpfSmoothExpanderAdapter.ps1` owns smooth expander animations, `adapters/WpfThemeAdapter.ps1` applies neutral theme palettes to view resources, and `adapters/WpfIconAssetAdapter.ps1` owns SVG file access and WPF geometry conversion; the shell retains composition and remaining event wiring. This boundary currently covers conversation, session, and model lists, status messages, theme/model/session selection, named window and toolbar actions, dynamically registered project/session rows and model parameter events, goal input and conversation scrolling events, Enter submission with Shift+Enter preserved by the WPF adapter, deferred layout updates, process polling, and splash timing. Context menu actions, expansion state, and dynamic view targets are registered through the same port. WPF animation hooks are isolated in the smooth expander adapter. The GUI architecture and remaining migration work are tracked in [`docs/ARCHITECTURE_REDESIGN.md`](docs/ARCHITECTURE_REDESIGN.md).

User query submission is coordinated by WPF-independent `scripts/GuiRequestApplication.ps1`. It persists the task goal, session update time, and conversation branch through injected JSON, existence, removal, and clock ports. A per-session write-ahead journal lets the next load restore the previous values after an interrupted process; ordinary write failures are also compensated immediately, with any failed rollback paths reported. The pure conversation branch transformation remains in `scripts/ConversationStore.ps1`.

Launch the standard Windows WPF interface with the thin executable wrapper:

```powershell
.\Ataraxia.exe
```

The interface replaces Windows default control chrome with custom vector templates. The WPF window and taskbar use `assets/branding/ataraxia-app-icon.png`; the executable embeds an ICO generated from the same image. Action icons live in `assets/ui-icons/`, and role icons live in `assets/role-icons/`; edit these SVG files to adjust their outlines. Every actionable icon control exposes an accessibility name matching its localized tooltip; dynamic controls use the shared Automation Name adapter. Text entry and selection remain native WPF controls for reliable keyboard and accessibility behavior.

The wrapper locates PowerShell 7 (`pwsh.exe`) or Windows PowerShell, then forwards its arguments to `scripts/Start-AtaraxiaGui.ps1`. PowerShell scripts use UTF-8 with BOM so Windows PowerShell 5.1 can read Japanese text correctly. Startup displays `assets/splash/ataraxia-project-cover.png`; branding artwork and the executable icon are stored under `assets/branding/`. Errors do not open dialogs. While the GUI is running, its status area shows the saved log path. Startup failures are written as UTF-8 logs containing PowerShell standard output, standard error, exit code, and exception details under `%LOCALAPPDATA%\Ataraxia\logs` (falling back to `%TEMP%\Ataraxia\logs`). The wrapper includes no PowerShell runtime or third-party library. To skip the startup cover:

```powershell
.\Ataraxia.exe -NoSplash
```

Only one GUI is opened for a given configuration file in the current Windows session. Launching it again requests activation of the existing window; a minimized window is restored. A different `-ConfigPath` identifies a separate GUI instance. The second launch does not replace the active window's configuration or other startup options.

Rebuild the wrapper and its classical serif “A” icon on Windows with the built-in .NET Framework C# compiler:

```powershell
pwsh -File .\tools\Build-Ataraxia.ps1
```

The left project drawer lists folders under `projects/`. Use the new-session icon at the right edge of a project row to open an empty session screen for that project, or use the project controls to switch, create, or rename projects. A session ID and its files are created only after you submit a non-empty first user query. Creating a project also switches to it. Renaming moves its folder and updates the active setting when applicable; a name collision is rejected. A collapsible **Recent sessions** section below the project list shows up to `gui.recent_sessions_max` sessions ordered by their latest user query (default 5). Selecting one switches to its project and opens that session. Each project keeps independent sessions under `projects/<project>/sessions/<session-id>/`, including its task, conversation, workflow state, and workspace. Use the session selector at the upper right to switch contexts, **Rename** to change a session title, and the document-plus icon button to start a new session (hover for its localized tooltip). The first user query automatically gives a new session a concise title; a title you set manually is preserved. Project and session common prompts can be edited independently; both are added to every role system message together with the current user query. Project, session, file, and run controls use compact icons with localized tooltips. The conversation uses a chat layout: user queries appear as right-aligned bubbles and role reports as left-aligned bubbles. Text remains selectable; report headings expand or collapse their bodies. When you scroll up through a long conversation, a centered down-arrow above the user query box jumps to the latest entry. Edit the latest user query and run it again to create a new branch. Choose Light, Dark, or System for the monochrome interface theme. The tracked palette values are defined separately in `configs/gui-themes.json`. The **Model parameters** section provides coarse sliders, precise numeric inputs with increment/decrement buttons, and text inputs for generation settings. Parameter names match the API keys exactly; hover over a name to show its description at the mouse pointer. The context-size slider moves in 256-token steps; other sliders use parameter-specific coarse steps. Seed has no slider, and its input is wide enough to show every digit. Direct numeric entry and increment/decrement controls retain finer precision. Changes are saved to the referenced `configs/koboldcpp-settings.json`. Presets are shared across all projects and models. Built-in presets cannot be overwritten or deleted; those buttons are disabled while one is selected. Use Save as to keep parameter changes in a user preset. User presets can be created, saved, renamed, deleted, and switched. Model files with same-stem JSON files do not override presets.

The KoboldCpp status indicator shows connected, starting, or disconnected. Use **Start KoboldCpp** to launch the configured local executable with the selected model and its settings, **Stop KoboldCpp** to stop the instance started by this GUI, or **Restart** to save visible parameters when a user preset is selected (built-in edits are not saved; use Save as to keep them), stop that managed instance, wait for its API port to close, and launch it again. Restart is unavailable for an externally started process. If the configured KoboldCpp executable is missing, the GUI downloads it in the background at startup through the separate initializer. This does not download a model or launch the server; set `paths.model_file` and use Start KoboldCpp when ready. A process started by the GUI is stopped when the GUI closes. An already reachable API is shown as connected and is not stopped by the GUI.

## Architecture and policy

`scripts/AgentCore.ps1` coordinates task workflow setup and phase inputs. Workflow transitions, role/prompt execution, state handling, and input validation are separated into `AgentWorkflow.ps1`, `AgentRoleExecution.ps1`, `AgentState.ps1`, and `AgentValidation.ps1`. `AgentHarness.ps1` handles workspace safety and allowlisted commands. GUI display and event wiring live in `Start-AtaraxiaGui.ps1`, while WPF independent application logic and view models live in `GuiApplication.ps1` and `GuiConversationModel.ps1`. Workflow stages, role assignments, transition conditions, and input/output schemas are structured task data, not domain-specific code. Tasks may add, change, or remove their own roles. Role calls, conversation persistence, session creation, and allowlisted process execution accept per-call dependency adapters. Unit tests use these seams to cover prompt sizing, response validation and retries, conversation branching, deterministic session metadata, command allowlisting, process output sanitization, and GUI application behavior without displaying a window or starting a live KoboldCpp server. A per-task exclusive lock prevents overlapping Ataraxia runs, resumes, and rollbacks for the same task.

Context compression stops with a specific error when its summary does not reduce token count. Workspace file snapshots and supported media share one directory inventory per prompt build.

The architecture target uses cohesive domain and application modules, explicit ports for external effects, adapters for infrastructure, and CLI/GUI composition roots. Domain rules remain independent of WPF, filesystems, HTTP, and processes. The process runner is the first explicit port/adapter slice: `AgentHarness.ps1` validates and delegates, `PowerShellProcessRunner.ps1` owns OS process creation, and `Invoke-Agent.ps1` wires them. GUI redirected-output temp paths, incremental line selection, and cleanup are isolated in `PowerShellGuiProcessOutputAdapter.ps1`; KoboldCpp endpoint interpretation and reachability checks use the application model and `TcpConnectionAdapter.ps1`, while its GUI launch plan is assembled in the application model; Windows system theme detection is isolated in `WindowsSystemThemeAdapter.ps1`; project/session drawer controls and model parameter controls are rendered by `WpfProjectDrawerAdapter.ps1` and `WpfModelParameterAdapter.ps1`; dialog result interpretation is framework-neutral, WPF rendering and path enumeration are in separate adapters. The current large scripts are scheduled for incremental vertical-slice decomposition; the target layers, dependency rules, current module assessment, and migration gates are in [`docs/ARCHITECTURE_REDESIGN.md`](docs/ARCHITECTURE_REDESIGN.md).

User-owned, declarative product outcomes and constraints are recorded separately in [`docs/REQUIREMENTS.md`](docs/REQUIREMENTS.md). The user can edit that file directly or explicitly ask the agent to update it. When asked to implement requirements, the agent derives and executes an ordered development plan while preserving the user's requirement statements and acceptance criteria.

The project is test-driven. Run the PowerShell checks with:

```powershell
pwsh -File .\tests\run_tests.ps1
```

Tests are derived from observable behavior and invariants. Important paths cover normal input, boundaries, rejection, and dependency failures, including checks that rejected operations have no side effects. Review coverage against requirements and risks rather than line coverage alone. The default unit suite never opens the GUI or loads WPF assemblies. It tests the WPF-independent GUI application models and injected ports with fakes, including project-operation recovery and the ordered persistence of user presets and shared model settings. To exercise real WPF controls, settings selectors, theme resources, and conversation templates without displaying a window or launching Ataraxia, run `pwsh -STA -File .\tests\run_wpf_control_tests.ps1`. To explicitly run the Windows GUI launch integration smoke tests, pass `-GuiIntegration` to `tests/run_tests.ps1`. Inherited environment variables cannot enable them. See `docs/SPECIFICATION.md` for the full method, `AGENTS.md` for repository contributor rules, and `docs/AGENTS.md` for documentation-specific rules.

JSON inputs are read as bounded UTF-8 files, model replies must contain a JSON document, and declared schemas are enforced locally. Prompt fit is determined only by KoboldCpp token counts for the complete messages and reserved response; it is not estimated or capped by character count. Requests, workspace paths and diffs, API endpoints, and allowlisted command arguments and output are validated at their boundaries.

## Dependencies and licenses

| Component | License / use |
|---|---|
| Ataraxia | MIT; see [LICENSE](LICENSE). |
| PowerShell and Windows WPF | Platform-provided runtimes; no bundled libraries. |
| KoboldCpp | Separate optional executable. Its AGPL-3.0 and bundled-component notices remain applicable. Ataraxia does not redistribute it. |
| GGUF models and user-provided files | Governed by their respective providers and owners. |

Ataraxia does not include model files. Review each model's license and hardware requirements before use. Process separation alone does not settle legal questions about a distribution or integration; assess applicable licenses individually.
