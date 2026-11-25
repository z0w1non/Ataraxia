[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$passed = 0
$failed = 0

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Output "PASS: $Name" }
    catch { $script:failed++; Write-Output "FAIL: $Name - $($_.Exception.Message)" }
}
function Read-Json([string]$Path) {
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "Missing file: $Path"
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

Test-Case 'Ataraxia is domain independent and project named' {
    $config=Read-Json (Join-Path $projectRoot 'configs/config.example.json')
    $modelConfig=Read-Json (Join-Path $projectRoot 'configs/koboldcpp-settings.json')
    Assert-True ($config.project_name -eq 'Ataraxia') 'Default project name is not Ataraxia.'
    $spec=Get-Content -LiteralPath (Join-Path $projectRoot 'docs/SPECIFICATION.md') -Raw -Encoding UTF8
    Assert-True ($spec -match '特定のドメインに限定しない' -and $spec -match 'Ataraxia') 'Domain independence is not a stated requirement.'
}

Test-Case 'Novel specific entry points and roles are removed' {
    $scripts=Join-Path $projectRoot 'scripts'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $scripts 'Invoke-NovelWriter.ps1'))) 'NovelWriter CLI remains.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $scripts 'Start-NovelWriterGui.ps1'))) 'NovelWriter GUI remains.'
    Assert-True (@(Get-ChildItem -LiteralPath $scripts -Filter 'NovelWriter*.ps1' -File).Count -eq 0) 'NovelWriter-specific modules remain.'
    Assert-True (Test-Path -LiteralPath (Join-Path $scripts 'Invoke-Agent.ps1') -PathType Leaf) 'Generic CLI is missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $scripts 'Start-AtaraxiaGui.ps1') -PathType Leaf) 'Generic GUI is missing.'
    Assert-True ((Test-Path -LiteralPath (Join-Path $projectRoot 'Ataraxia.exe') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $projectRoot 'assets/branding/ataraxia-app-icon.ico') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $projectRoot 'assets/splash/ataraxia-project-cover.png') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $projectRoot 'launcher/AtaraxiaLauncher.cs') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $projectRoot 'tools/Build-Ataraxia.ps1') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $projectRoot 'assets/branding/ataraxia-app-icon.png') -PathType Leaf)) 'Standalone GUI launcher, splash cover, icon, source, or build script is missing.'
    $launcherSource=Get-Content -LiteralPath (Join-Path $projectRoot 'launcher/AtaraxiaLauncher.cs') -Raw -Encoding UTF8
    Assert-True ($launcherSource -match 'Start-AtaraxiaGui\.ps1' -and $launcherSource -match 'FindPowerShell\(' -and $launcherSource -match 'foreach \(string arg in args\)' -and $launcherSource -match 'QuoteArgument\(arg\)') 'GUI launcher does not locate PowerShell and forward command-line options safely.'
    $buildCommand=Get-Content -LiteralPath (Join-Path $projectRoot 'tools/Build-Ataraxia.ps1') -Raw -Encoding UTF8
    Assert-True ($buildCommand -match 'ataraxia-app-icon\.ico' -and $buildCommand -match '/win32icon:') 'Launcher build command does not embed the project lettermark icon.'
}

Test-Case 'PowerShell scripts parse' {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $projectRoot 'scripts') -Filter '*.ps1' -File) {
        $bytes=[IO.File]::ReadAllBytes($file.FullName)
        Assert-True ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) "$($file.Name) must use UTF-8 with BOM for Windows PowerShell compatibility."
        $tokens=$null; $errors=$null
        [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors) | Out-Null
        Assert-True ($errors.Count -eq 0) "PowerShell parse error in $($file.Name): $($errors -join '; ')"
    }
}

Test-Case 'Generic role contracts and new task template' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'RoleContracts.ps1')
    . (Join-Path (Join-Path $projectRoot 'scripts') 'AgentCore.ps1')
    $contracts=Import-RoleContracts ([pscustomobject]@{})
    $template=Agent-NewTaskTemplate 'test' $contracts | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    Assert-True ($template.workflow.initial_stage -eq 'Core' -and $template.workflow.stages.Count -eq 2 -and $template.roles.id -contains 'reporter') 'New tasks do not begin with workflow design by the core role.'
    Assert-True ($template.roles.id -contains 'core' -and $template.roles.id -contains 'planner' -and $template.roles.id -contains 'executor' -and $template.roles.id -contains 'reviewer' -and $template.roles.id -contains 'router') 'Default workflow is domain-specific or incomplete.'
    Assert-True ($template.roles.id -contains 'impact_reviewer' -and @($template.workflow.stages|Where-Object{$_.id -eq 'Core' -and $_.role_id -eq 'core'}).Count -eq 1) 'Core workflow design or the impact review role is missing.'
    $corePrompt=Read-Json (Join-Path $projectRoot 'data/default-user/sysprompt/agent_core.json');$plannerPrompt=Read-Json (Join-Path $projectRoot 'data/default-user/sysprompt/agent_planner.json')
    Assert-True ($corePrompt.content -match 'You do not create the task.s action plan' -and $corePrompt.content -match 'planner role owns' -and $plannerPrompt.content -match 'You do not choose or reorder workflow roles' -and $plannerPrompt.content -match 'ordered set of practical actions') 'Core and planner responsibilities are not clearly separated.'
    $legacy=Agent-NewTaskTemplate 'legacy' $contracts;$legacy.goal='Legacy workflow migration.';$legacy.working_directory='.';$legacy.roles=@($legacy.roles|Where-Object{$_.id -ne 'core'});$legacy.workflow.initial_stage='Plan';$oldRoute=@($legacy.workflow.stages|Where-Object{$_.id -eq 'Route'})[0];$legacy.workflow.stages=@([pscustomobject]@{id='Plan';role_id='planner';result_key='plan';allowed_next_stages=@('Complete');default_next='Route';transitions=@(@{next='Route'})},$oldRoute)
    $migrated=Agent-EnsureCoreWorkflow $legacy $contracts;Agent-ValidateTask $legacy
    Assert-True ($migrated -and $legacy.workflow.initial_stage -eq 'Core' -and $legacy.roles.id -contains 'core') 'An existing task was not updated to invoke core before its next request.'
}

Test-Case 'Role-specific inputs select only their contracted fields' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'AgentCore.ps1')
    $contracts=Import-RoleContracts ([pscustomobject]@{})
    $task=Agent-NewTaskTemplate 'contract-test' $contracts
    $task.goal='Test a workflow design.';$task.working_directory='.'
    $config=[pscustomobject]@{user_output_language='Japanese'}
    $phaseInput=[pscustomobject][ordered]@{goal='goal';context='context';constraints=@('constraint');cycle=1;phase='Do';phase_data=[pscustomobject]@{result='prior'};latest_stage='Plan';results=[pscustomobject]@{plan='prior'};workspace_root='.';workspace_files=@();workspace_media=@();available_roles=@([pscustomobject]@{id='planner';purpose='Plan'});available_next_stages=@();allowed_commands=@();context_summary=$null}
    foreach($role in @($task.roles|Where-Object{$_.id -notin @('context_compressor','session_namer','reporter')})){
        $selected=Agent-SelectRoleInput $phaseInput $role $config
        $actual=(@($selected.PSObject.Properties.Name|Sort-Object)-join ',')
        $expected=(@($role.input_schema.properties.PSObject.Properties.Name|Sort-Object)-join ',')
        Assert-True ($actual -ceq $expected) "Role $($role.id) did not receive exactly its declared input fields."
    }
    $reporter=@($task.roles|Where-Object{$_.id -eq 'reporter'})[0]
    $report=[pscustomobject]@{goal='goal';phase='Report';latest_stage='Do';results=[pscustomobject]@{role_result='done';files_changed=@();commands_run=@()}}
    $selectedReport=Agent-SelectRoleInput $report $reporter $config
    Assert-True ($selectedReport.results.role_result -eq 'done' -and $selectedReport.PSObject.Properties.Name -notcontains 'workspace_files') 'Reporter receives an oversized or malformed input.'
    $designed=Agent-InstallDesignedWorkflow $task ([pscustomobject]@{workflow=[pscustomobject]@{initial_stage='Plan';stages=@([pscustomobject]@{id='Plan';role_id='planner';result_key='plan';next_stages=@('Do')},[pscustomobject]@{id='Do';role_id='executor';result_key='execution';next_stages=@('Complete')})}})
    Assert-True ($designed.workflow.core_configured -and $designed.workflow.initial_stage -eq 'Core' -and $designed.workflow.stages.Count -eq 4 -and $designed.workflow.stages[2].changes_field -eq 'file_changes' -and $designed.workflow.stages[1].id -eq 'Q1_Plan') 'Core workflow design was not normalized into a validated executable graph.'
    $routingState=[pscustomobject]@{history=@([pscustomobject]@{phase='Q1_Plan';result=[pscustomobject]@{}})};$options=Agent-GetRoutingOptions $designed $routingState
    Assert-True (@($options|Where-Object{$_.id -eq 'AwaitUser'}).Count -eq 1) 'Router does not offer a user-query wait checkpoint.'
    Assert-True (@($options|Where-Object{$_.id -eq 'ReplanCore'}).Count -eq 1) 'Router does not offer autonomous workflow replanning.'
    $limitedRoutingState=[pscustomobject]@{history=$routingState.history;core_replans_this_query=2};$limitedOptions=Agent-GetRoutingOptions $designed $limitedRoutingState
    Assert-True (@($limitedOptions|Where-Object{$_.id -eq 'ReplanCore'}).Count -eq 0) 'Router continued offering Core replans after the configured per-query limit.'
    $waitState=Agent-ValidateState ([pscustomobject]@{cycle=0;phase='AwaitUser';history=@();results=[pscustomobject]@{}}) $designed
    Assert-True ($waitState.phase -eq 'AwaitUser') 'Agent state validation rejects the resumable user-query wait state.'
    $replanState=Agent-ValidateState ([pscustomobject]@{cycle=0;phase='ReplanCore';history=@();results=[pscustomobject]@{};core_replans_this_query=1}) $designed
    Assert-True ($replanState.phase -eq 'ReplanCore') 'Agent state validation rejects an autonomous Core replan.'
    $historyState=[pscustomobject]@{history=@([pscustomobject]@{phase='Core'},[pscustomobject]@{phase='Q1_Do'});results=[pscustomobject]@{workflow_design=[pscustomobject]@{};q1_execution=[pscustomobject]@{result='prior'}};core_request_id='request-two'}
    $secondDesigned=Agent-InstallDesignedWorkflow $task ([pscustomobject]@{workflow=[pscustomobject]@{initial_stage='Plan';stages=@([pscustomobject]@{id='Plan';role_id='planner';result_key='plan';next_stages=@('Complete')})}}) $historyState
    Assert-True ($secondDesigned.workflow.request_count -eq 2 -and @($secondDesigned.workflow.stages|Where-Object{$_.id -eq 'Q1_Do'}).Count -eq 1 -and @($secondDesigned.workflow.stages|Where-Object{$_.id -eq 'Q2_Plan'}).Count -eq 1 -and $secondDesigned.workflow.core_request_id -eq 'request-two') 'A later request did not install a fresh workflow while preserving prior request history.'
    $rejected=$false;try{$null=Agent-InstallDesignedWorkflow $task ([pscustomobject]@{workflow=[pscustomobject]@{initial_stage='Plan';stages=@([pscustomobject]@{id='Plan';role_id='arbitrary';result_key='plan';next_stages=@('Complete')})}})}catch{$rejected=$true};Assert-True $rejected 'Core workflow accepted a role outside the task role catalog.'
}

Test-Case 'Agent inputs outputs and workspace paths reject unsafe content' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'AgentCore.ps1')
    . (Join-Path (Join-Path $projectRoot 'scripts') 'AgentHarness.ps1')
    $rejected=$false;try{Agent-ConvertModelJson 'preface {"ok":true}'}catch{$rejected=$true};Assert-True $rejected 'Model JSON parser accepted text outside the JSON document.'
    $schema=[pscustomobject]@{type='string';maxLength=8};$rejected=$false;try{Assert-JsonSchema 'long string' $schema}catch{$rejected=$true};Assert-True $rejected 'Schema maxLength was ignored.'
    $rejected=$false;try{Resolve-AgentWorkspacePath (Join-Path ([IO.Path]::GetTempPath()) 'workspace') 'CON.txt'}catch{$rejected=$true};Assert-True $rejected 'Reserved device path was accepted.'
    $rejected=$false;try{Resolve-AgentWorkspacePath (Join-Path ([IO.Path]::GetTempPath()) 'workspace') "folder`0file.txt"}catch{$rejected=$true};Assert-True $rejected 'Control characters in workspace paths were accepted.'
    $rejected=$false;try{New-AgentHttpUri 'file:///tmp/api' '/chat'}catch{$rejected=$true};Assert-True $rejected 'Non-HTTP API schemes were accepted.'
    $rejected=$false;try{ConvertFrom-AgentJsonText (' ' * 32) 'bounded test JSON' 8}catch{$rejected=$true};Assert-True $rejected 'Oversized JSON input was accepted.'
    $rejected=$false;try{Assert-JsonSchema "bad`0text" ([pscustomobject]@{type='string'})}catch{$rejected=$true};Assert-True $rejected 'Control characters in model strings were accepted.'
}

Test-Case 'Prompt boundaries use token counts instead of character thresholds' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'AgentCore.ps1')
    function Get-KoboldCppTokenCount([object]$Config,[object]$Value) { $text=if($Value -is [string]){$Value}else{(@($Value|ForEach-Object{[string]$_.content}) -join ' ')};return [regex]::Matches($text,'\S+').Count }
    $text='one supercalifragilisticexpialidocious three four';$split=Get-AgentTokenBalancedSplit ([pscustomobject]@{override=[pscustomobject]@{context_size=8192}}) $text
    Assert-True ($split.left -eq 'one supercalifragilisticexpialidocious' -and $split.right -eq ' three four' -and $split.left_tokens -eq 2) 'Oversized prompt splitting followed character length instead of measured token balance.'
    $source=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/AgentCore.ps1') -Raw -Encoding UTF8
    Assert-True ($source -notmatch 'Task goal.?\x27 262144|Task context.?\x27 262144|Combined common prompt.?\x27 262144' -and $source -match 'Get-AgentTokenBalancedSplit') 'Prompt character thresholds remain in the execution core.'
}

Test-Case 'Configurable workflow, context compression, and command harness' {
    $core=Get-Content -LiteralPath (Join-Path (Join-Path $projectRoot 'scripts') 'AgentCore.ps1') -Raw -Encoding UTF8
    $harness=Get-Content -LiteralPath (Join-Path (Join-Path $projectRoot 'scripts') 'AgentHarness.ps1') -Raw -Encoding UTF8
    $rules=Read-Json (Join-Path $projectRoot 'configs/agent-harness.json')
    Assert-True ($core -match 'Agent-ResolveTransition' -and $core -match 'Agent-CompressContext') 'Generic workflow or compression is absent.'
    Assert-True ($harness -match 'Apply-AgentWorkspaceChanges' -and $harness -match 'arguments_regex' -and $rules.allowed_commands.Count -gt 0) 'Workspace diff or allowlisted command rules are missing.'
}

Test-Case 'Shared JSON, language, KoboldCpp, and report configuration' {
    $config=Read-Json (Join-Path $projectRoot 'configs/config.example.json')
    $contracts=Read-Json (Join-Path $projectRoot 'configs/role-contracts.json')
    Assert-True ($config.llm_input_format -eq 'json' -and $config.user_output_language -eq 'Japanese') 'Structured input or output language defaults are missing.'
    Assert-True ($contracts.schemas.agent_reporter_output.required -contains 'heading' -and $contracts.schemas.agent_reporter_output.required -contains 'body') 'Reporter contract has no heading/body.'
    Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot 'configs/koboldcpp-settings.json')) 'Shared KoboldCpp settings are missing.'
    . (Join-Path $projectRoot 'scripts/KoboldCppSettings.ps1')
    Assert-True ((Resolve-KoboldCppBuild 'auto' @('NVIDIA GeForce RTX')) -eq 'cuda' -and (Resolve-KoboldCppBuild 'auto' @('AMD Radeon')) -eq 'nocuda' -and (Resolve-KoboldCppBuild 'oldpc' @('NVIDIA')) -eq 'oldpc') 'KoboldCpp auto build selection does not detect NVIDIA and preserve explicit overrides.'
    $initializer=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/Initialize-KoboldCpp.ps1') -Raw -Encoding UTF8
    Assert-True ($initializer -match 'ValidateSet\(''auto'',''cuda'',''nocuda'',''oldpc''\)' -and $initializer -match '\$Build = ''auto''') 'KoboldCpp initializer does not default to automatic build selection.'
    $spec=Get-Content -LiteralPath (Join-Path $projectRoot 'docs/SPECIFICATION.md') -Raw -Encoding UTF8
    Assert-True ($spec -match 'Initialize-KoboldCpp\.ps1' -and $spec -match '既定値 `auto`' -and $spec -match '-Launch' -and $spec -match '60秒' -and $spec -match 'model_file') 'KoboldCpp download, model selection, and launch procedure is not specified.'
    $namer=@($contracts.generic_agent.roles|Where-Object{$_.id -eq 'session_namer'})
    Assert-True ($namer.Count -eq 1 -and $contracts.schemas.session_namer_input.required -contains 'first_prompt' -and $contracts.schemas.session_namer_output.required -contains 'title') 'Session naming role does not use the first prompt and return a title.'
    Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot 'data/default-user/sysprompt/session_namer.json')) 'Session naming prompt is missing.'
    $activeRoleInputs=@($contracts.generic_agent.roles|Where-Object{$_.id -notin @('context_compressor','session_namer')}|ForEach-Object{$_.input_schema_ref}|Sort-Object -Unique)
    Assert-True ($activeRoleInputs.Count -eq 11 -and $null -eq $contracts.schemas.PSObject.Properties['agent_phase_input']) 'Workflow roles still share the obsolete generic input structure.'
    foreach($role in @($contracts.generic_agent.roles|Where-Object{$_.id -notin @('context_compressor','session_namer')})){
        $inputSchema=$contracts.schemas.PSObject.Properties[[string]$role.input_schema_ref].Value
        $outputSchema=$contracts.schemas.PSObject.Properties[[string]$role.output_schema_ref].Value
        Assert-True ($inputSchema.type -eq 'object' -and $inputSchema.additionalProperties -eq $false -and $outputSchema.type -eq 'object' -and $outputSchema.additionalProperties -eq $false) "Role $($role.id) has an incomplete structured input/output contract."
    }
    $ja=Read-Json (Join-Path $projectRoot 'locales/ja.json'); $en=Read-Json (Join-Path $projectRoot 'locales/en.json')
    $jaKeys=(@($ja.PSObject.Properties.Name | Sort-Object) -join ','); $enKeys=(@($en.PSObject.Properties.Name | Sort-Object) -join ',')
    Assert-True ($jaKeys -ceq $enKeys) 'Japanese and English locale keys differ.'
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $projectRoot 'scripts') -Filter '*.ps1' -File){$source=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8;foreach($match in [regex]::Matches($source,'Get-AppText\s+''([^'']+)''')){$key=$match.Groups[1].Value;Assert-True ($null -ne $ja.PSObject.Properties[$key]) "Missing localization key: $key"}}
}

Test-Case 'GUI theme modes use achromatic high contrast palettes' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'GuiTheme.ps1')
    $config=Read-Json (Join-Path $projectRoot 'configs/config.example.json')
    Assert-True ($config.gui_theme -eq 'system') 'System theme is not the default preference.'
    foreach($mode in @('light','dark')){
        $palette=Get-AtaraxiaThemePalette $mode
        foreach($property in $palette.PSObject.Properties){$rgb=[string]$property.Value;if($rgb -notmatch '^#([0-9A-Fa-f]{2})\1\1$'){throw "Theme color is not achromatic: $mode/$($property.Name)=$rgb"}}
        $contrast=Get-AtaraxiaContrastRatio $palette.primary_text $palette.app_background
        Assert-True ($contrast -ge 7) "Theme text contrast is too low: $mode/$contrast"
    }
    Assert-True ((Resolve-AtaraxiaThemeMode 'system' 'dark') -eq 'dark' -and (Resolve-AtaraxiaThemeMode 'light' 'dark') -eq 'light') 'Theme preference does not resolve system and explicit modes.'
}

Test-Case 'GUI model parameter definitions enforce editable valid ranges' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'GuiModelParameters.ps1')
    $modelConfig=Read-Json (Join-Path $projectRoot 'configs/koboldcpp-settings.json')
    $definitions=Get-AtaraxiaModelParameterDefinitions
    Assert-True (@($definitions|Where-Object{$_.key -eq 'max_tokens'}).Count -eq 1) 'Maximum response tokens have no editable definition.'
    Assert-True (@($definitions|Where-Object{$_.key -eq 'temperature'}).Count -eq 1) 'Temperature has no editable definition.'
    foreach($d in $definitions|Where-Object{$_.kind -eq 'number'}){Assert-True ($d.min -lt $d.max -and $d.step -gt 0) "Invalid control range for $($d.key)."}
    foreach($case in @(@{key='temperature';value=-0.1},@{key='max_tokens';value=0},@{key='top_p';value=1.1})){try{Assert-AtaraxiaModelParameterValue $case.key $case.value;throw "Invalid value accepted for $($case.key)."}catch{if($_.Exception.Message -like 'Invalid value accepted*'){throw}}}
    Assert-True ((Assert-AtaraxiaModelParameterValue 'temperature' 0.7) -eq 0.7) 'Valid temperature was rejected.'
    Assert-True ($modelConfig.request_parameters.temperature -eq 0.7 -and $modelConfig.request_parameters.stop.Count -eq 0) 'Default model parameter values are missing.'
    $stepRejected=$false;try{Assert-AtaraxiaModelParameterValue 'temperature' 0.705|Out-Null}catch{$stepRejected=$true};Assert-True $stepRejected 'Temperature step restriction was not enforced.'
}

Test-Case 'Generic conversation GUI supports reports and editing the last request' {
    $gui=Get-Content -LiteralPath (Join-Path (Join-Path $projectRoot 'scripts') 'Start-AtaraxiaGui.ps1') -Raw -Encoding UTF8
    $match=[regex]::Match($gui,"(?s)\[xml\]\`$xaml\s*=\s*@'\s*(.*?)\s*'@")
    Assert-True $match.Success 'GUI XAML is missing.'
    try { [xml]$guiXaml=$match.Groups[1].Value } catch { throw "GUI XAML is invalid: $($_.Exception.Message)" }
    $guiNamespaces=[System.Xml.XmlNamespaceManager]::new($guiXaml.NameTable);$guiNamespaces.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')
    Assert-True ($gui -match '\[switch\]\$NoSplash' -and $gui -match 'if\(\$NoSplash\)\{\$arguments\+=' -and $gui -match 'if\(-not \$NoSplash\)\{\$script:splashWindow=Show-AtaraxiaStartupSplash\}' -and $gui -match 'Width="560" Height="315" WindowStartupLocation="CenterScreen" WindowStyle="None"' -and $gui -match 'assets/splash/ataraxia-project-cover\.png' -and $gui -match 'minimumSplashMilliseconds=1100' -and $gui -match 'DispatcherFrame') 'Splash cover is not displayed briefly or NoSplash is not forwarded.'
    Assert-True ($gui -match 'Expander' -and $gui -match 'Conversation' -and $gui -match 'EditLast' -and $gui -match 'state\.json') 'Conversation reports or edit/resend flow is missing.'
    Assert-True ($gui -match 'IsExpanded="\{Binding is_expanded, Mode=TwoWay\}"') 'Conversation report expansion state is not bound to the view model.'
    Assert-True ($gui -match 'Path Data="\{Binding icon_geometry\}"' -and $gui -match 'StackPanel Orientation="Horizontal"') 'Role icon is not shown beside each report heading.'
    Assert-True ($gui -match 'TargetType="\{x:Type Button\}"' -and $gui -match 'TargetType="\{x:Type TextBox\}"' -and $gui -match 'TargetType="\{x:Type ComboBox\}"' -and $gui -match 'TargetType="\{x:Type Expander\}"' -and $gui -match 'TargetType="\{x:Type Slider\}"' -and $gui -match 'PART_ContentHost' -and $gui -match 'FocusVisualStyle" Value="\{x:Null\}') 'GUI controls still rely on default Windows chrome instead of custom vector templates.'
    Assert-True ($gui -match 'ThemeOptionTemplate.*Binding label' -and $gui -match '\$ThemeSelector\.ItemTemplate=\$window\.Resources\[''ThemeOptionTemplate''\]' -and $gui -notmatch '\$ThemeSelector\.DisplayMemberPath=''label''') 'Theme picker does not render the localized label from its option object.'
    Assert-True ($gui -match '<ToggleButton Grid.ColumnSpan="2" HorizontalAlignment="Stretch" Background="Transparent" IsChecked="\{Binding IsDropDownOpen') 'ComboBox clicks outside the arrow do not open the dropdown.'
    Assert-True ($gui -match 'ExpanderChevronRightGeometry' -and $gui -match 'ExpanderChevronDownGeometry' -and $gui -notmatch 'RotateTransform Angle="90" CenterX="6" CenterY="10"' -and $gui -match '\$Icon\.Width=16;\$Icon\.Height=16' -and $gui -match '\$iconControl\.Padding=\[Windows\.Thickness\]::new\(3\)') 'Expander chevrons or toolbar SVG icons are misaligned or clipped.'
    Assert-True ($gui -match 'IconButtonHover' -and $gui -match 'MouseOver' -and $gui -match 'ProjectGroupExpander' -and $gui -match 'gui_no_projects' -and $gui -match 'gui_projects') 'Icon hover feedback or the always-available project group is missing.'
    Assert-True ($gui -notmatch 'Text="Ataraxia"|ProjectManagerTitle|ToggleDrawer' -and $gui -match 'Title=""' -and $gui -match 'ataraxia-app-icon\.ico' -and $gui -notmatch 'Content=\$\(Get-AppText ''gui_active_project''\)|Content=if\(\$projectName -ieq \$active\)\{Get-AppText ''gui_active_project''') 'GUI still shows the brand label, drawer toggle, or window title, or is missing its app icon.'
    Assert-True ($gui -match 'RecentSessionsExpander' -and $gui -match 'RecentSessionsPanel' -and $gui -notmatch '\$ProjectTreePanel\.Children\.Add\(\$recentNode\)' -and $gui -match 'Background="\{DynamicResource AppBackgroundBrush\}" VerticalScrollBarVisibility="Auto" Padding="10"' -and $gui -match 'ConversationBubble.*Value="Transparent".*Value="\{DynamicResource PanelBrush\}"') 'Recent sessions are not a sibling group or conversation surfaces do not use transparent and tinted backgrounds.'
    $projectGroupNode=$guiXaml.SelectSingleNode("//*[@x:Name='ProjectGroupExpander']",$guiNamespaces);$recentGroupNode=$guiXaml.SelectSingleNode("//*[@x:Name='RecentSessionsExpander']",$guiNamespaces)
    Assert-True ($null -ne $projectGroupNode -and $null -ne $recentGroupNode -and [object]::ReferenceEquals($projectGroupNode.ParentNode,$recentGroupNode.ParentNode)) 'Recent sessions do not sit beside the project group in the drawer.'
    $iconHoverStyle=[regex]::Match($gui,'(?s)<Style x:Key="IconButtonHover".*?</Style>').Value
    Assert-True ($iconHoverStyle -match 'HoverTint.*TemplateBinding Foreground.*Opacity="0"' -and $iconHoverStyle -match 'IsMouseOver" Value="True"><Setter TargetName="HoverTint" Property="Opacity" Value="0.12"' -and $iconHoverStyle -notmatch 'IsMouseOver" Value="True"><Setter TargetName="Chrome"') 'Hover treatment changes the button foreground or fails to tint its background toward that foreground.'
    $svgModel=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/GuiConversationModel.ps1') -Raw -Encoding UTF8
    Assert-True ($svgModel -match 'assets/role-icons' -and $svgModel -match 'Get-AtaraxiaSvgPathGeometry') 'Role heading visuals are not loaded from SVG assets.'
    foreach($iconName in @('new-project','rename-project','project-prompt-button','rename-session','session-prompt-button','new-session','browse-config','kobold-restart','browse-task','browse-workspace','refresh-models','scroll-to-latest','create-task','edit-last','send','stop','menu','more','kobold-start','kobold-stop','chevron-right','chevron-down')){Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot ('assets/ui-icons/'+$iconName+'.svg')) -PathType Leaf) "Missing GUI SVG icon: $iconName"}
    Assert-True ($gui -match 'Invoke-Agent\.ps1' -and $gui -match "'-Step','-1'") 'GUI does not run the generic workflow to completion.'
    Assert-True ($gui -match 'ProjectDrawer' -and $gui -notmatch 'ProjectSelector|SwitchProject' -and $gui -match 'NewProject' -and $gui -match 'RenameProject') 'Project drawer shows duplicate project selection controls.'
    Assert-True ($gui -match 'ProjectTreePanel' -and $gui -match 'Refresh-ProjectSessionTree' -and $gui -match 'Add_Expanded' -and $gui -match 'Add_Collapsed' -and $gui -match 'Select-AtaraxiaDrawerSession' -and $gui -match 'Select-AtaraxiaDrawerProject') 'Drawer projects cannot be selected and expanded to show their sessions.'
    Assert-True ($gui -match 'newSessionForProject' -and $gui -match 'Begin-AtaraxiaNewSessionScreen \(\[string\]\$this\.Tag\)' -and $gui -match 'gui_new_session_for_project') 'Project rows do not offer an icon action to open a new session for that project.'
    Assert-True ($gui -match 'function Begin-AtaraxiaNewSessionScreen' -and $gui -match 'function Materialize-AtaraxiaPendingSession' -and $gui -match 'pendingSessionProject' -and $gui -match 'IsNullOrWhiteSpace\(\$Goal\.Text\)') 'A new session is created before the user submits a non-empty first request.'
    Assert-True ($gui -match 'Stop-AtaraxiaRun' -and $gui -notmatch 'StopTask' -and $gui -match 'Get-AppText.+gui_stop') 'Run button does not switch to a stop-and-restore action.'
    Assert-True ($gui -match 'SessionSelector' -and $gui -match 'NewSession' -and $gui -match 'RenameSession' -and $gui -match 'New-AtaraxiaGuiSession' -and $gui -match 'Rename-AtaraxiaGuiSession') 'Project sessions cannot be created, selected, and renamed from the main screen.'
    Assert-True ($gui -match 'OtherSession' -and $gui -match 'CopySessionIdMenuItem' -and $gui -match 'gui_copy_session_id' -and $gui -match '\[Windows\.Clipboard\]::SetText') 'Session ID copy action is missing from the additional actions menu.'
    Assert-True ($gui -match 'Convert-AtaraxiaRunOutput' -and $gui -match "gui_running_role" -and $gui -match "item.kind -eq 'role'") 'GUI does not display the currently running role.'
    Assert-True ($gui -match 'ThemeSelector' -and $gui -match 'Apply-AtaraxiaTheme' -and $gui -match 'Get-AtaraxiaSystemTheme') 'GUI does not provide system, light, and dark theme selection.'
    Assert-True ($gui -match 'KoboldToggle' -and $gui -match 'KoboldStatusDot' -and $gui -match 'Start-KoboldCppFromGui' -and $gui -match 'Stop-KoboldCppFromGui' -and $gui -match 'Get-KoboldCppLaunchArguments' -and $gui -match '#2E7D32' -and $gui -match '#C62828') 'GUI does not launch/stop KoboldCpp and color its API connection state.'
    Assert-True ($gui -match 'Start-KoboldCppAcquisitionIfMissing' -and $gui -match 'if\(Test-Path -LiteralPath \$executable -PathType Leaf\)\{return\}' -and $gui -match 'Initialize-KoboldCpp\.ps1' -and $gui -match 'RedirectStandardOutput' -and $gui -match 'Complete-KoboldCppAcquisitionIfFinished') 'GUI does not acquire a missing KoboldCpp executable asynchronously through the separate initializer.'
    Assert-True ($gui -match 'ModelFileSelector' -and $gui -match 'Get-AtaraxiaAvailableModels' -and $gui -match 'Save-AtaraxiaSelectedModel' -and $gui -match 'Get-KoboldCppModelSettings' -and $gui -match 'Save-KoboldCppSettings' -and $gui -match "-Filter '\*\.gguf' -Recurse" -and $gui -match '\$script:loadingModelSelector=\$true;try\{Refresh-AtaraxiaModelSelector\}') 'GUI does not recursively load local GGUF files on startup and save selected model and sidecar settings.'
    Assert-True ($gui -match 'KoboldRestart' -and $gui -match 'Restart-KoboldCppFromGui' -and $gui -match 'gui_kobold_restart_requires_managed' -and $gui -match 'gui_kobold_restart_port_busy') 'GUI cannot safely restart its managed KoboldCpp process.'
    Assert-True ($gui -match 'x:Name="NewSession"[^>]*ToolTip="New session"' -and $gui -match '<Path Data="M4,1 H12 L16,5 V16 H4 Z M12,1 V5 H16 M10,8 V14 M7,11 H13"' -and $gui -match '\$NewSession\.ToolTip=Get-AppText ''gui_new_session''') 'New session action is not an icon button with a localized tooltip.'
    foreach($control in @('NewProject','RenameProject','ProjectPromptButton','RenameSession','SessionPromptButton','BrowseConfig','BrowseTask','BrowseWorkspace','CreateTask','EditLast','RunTask','KoboldToggle','KoboldRestart','RefreshModels')){Assert-True ($gui -match ('x:Name="'+$control+'"[^>]*ToolTip=') -or $gui -match ('\$'+$control+'\.ToolTip=Get-AppText')) "Icon action $control has no tooltip."}
    Assert-True ($gui -match 'function Set-RunTaskIcon' -and $gui -match 'function Set-KoboldToggleIcon' -and $gui -match 'DynamicResource IconBrush') 'Action icons do not reflect state and theme colors.'
    Assert-True ($gui -match 'x:Name="ConversationScrollViewer"' -and $gui -match 'x:Name="ScrollToLatest"[^>]*Visibility="Collapsed"' -and $gui -match 'Update-AtaraxiaScrollToLatestButton' -and $gui -match '\$ConversationScrollViewer\.ScrollToEnd\(\)') 'The conversation does not provide a conditional jump-to-latest control.'
    Assert-True ($gui -match 'gui_copy_request' -and $gui -match 'ContextMenu' -and $gui -match 'Wire-AtaraxiaRequestCopyMenus' -and $gui -match '\[Windows\.Clipboard\]::SetText') 'Past user requests cannot be copied from their context menu.'
    Assert-True ($gui -match 'x:Name="ConversationHeading"[^>]*IsReadOnly="True"' -and $gui -match 'x:Name="ConversationBody"[^>]*IsReadOnly="True"') 'Conversation headings and bodies are not selectable text.'
    Assert-True ($gui -match 'ConversationBubble' -and $gui -match 'HorizontalAlignment" Value="Right"' -and $gui -match 'HorizontalAlignment" Value="Left"' -and $gui -match 'CornerRadius="7" BorderThickness="0"') 'Requests and reports are not shown in a minimal left/right chat layout.'
    Assert-True ($gui -match 'TaskSettingsExpander" Grid.Row="1" Header="Settings" IsExpanded="False"' -and $gui -match "gui_task_settings") 'Advanced task and runtime controls are not grouped under a collapsed settings section.'
    Assert-True ($gui -match 'gui_recent_sessions' -and $gui -match 'Get-AtaraxiaRecentSessions' -and $gui -match 'Select-AtaraxiaDrawerSession \(\[string\]\$sessionCopy\.project_name\)' -and $gui -match 'recent_sessions_max') 'Recent sessions drawer is missing or does not use the normal project/session selection flow.'
    Assert-True ($gui -match '\$Goal\.Add_PreviewKeyDown' -and $gui -match 'ModifierKeys\]::Shift' -and $gui -match 'ButtonBase\]::ClickEvent') 'Enter does not send requests or Shift+Enter preserve a newline.'
    Assert-True ($gui -match 'ProjectPromptButton' -and $gui -match 'SessionPromptButton' -and $gui -match 'Save-AtaraxiaCommonPrompt') 'GUI cannot edit project and session common prompts.'
    Assert-True ($gui -notmatch 'lastSystemThemeCheck|TotalSeconds -ge 2' -and $gui -match 'Slider' -and $gui -match 'TextBox' -and $gui -match 'Save-AtaraxiaModelParameters') 'GUI still polls themes or lacks synchronized parameter controls.'
    $ja=Read-Json (Join-Path $projectRoot 'locales/ja.json');$en=Read-Json (Join-Path $projectRoot 'locales/en.json')
    foreach($key in @('gui_kobold_start','gui_kobold_stop','gui_kobold_restart','gui_kobold_connected','gui_kobold_disconnected','gui_kobold_starting','gui_kobold_downloading','gui_kobold_downloaded','gui_kobold_download_failed','gui_kobold_missing_executable','gui_kobold_model_required','gui_kobold_restart_requires_managed','gui_kobold_restart_port_busy','gui_model_file','gui_refresh_models')){Assert-True ($null -ne $ja.PSObject.Properties[$key] -and $null -ne $en.PSObject.Properties[$key]) "KoboldCpp GUI label is missing localization: $key"}
    Assert-True ($null -ne $ja.PSObject.Properties['gui_new_session_for_project'] -and $null -ne $en.PSObject.Properties['gui_new_session_for_project']) 'Project-scoped new-session status is not localized.'
    Assert-True ($null -ne $ja.PSObject.Properties['gui_scroll_to_latest'] -and $null -ne $en.PSObject.Properties['gui_scroll_to_latest']) 'Jump-to-latest tooltip is not localized.'
    Assert-True ($null -ne $ja.PSObject.Properties['gui_role_session_namer'] -and $null -ne $en.PSObject.Properties['gui_role_session_namer'] -and $null -ne $ja.PSObject.Properties['gui_running_role'] -and $null -ne $en.PSObject.Properties['gui_running_role']) 'Role status is missing localized labels.'
}

Test-Case 'Dialogs use portable contracts and custom SVG rendering' {
    $dialogScript=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/GuiDialogs.ps1') -Raw -Encoding UTF8
    $dialogConfig=Read-Json (Join-Path $projectRoot 'configs/gui-dialog-contracts.json')
    $gui=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/Start-AtaraxiaGui.ps1') -Raw -Encoding UTF8
    Assert-True ($dialogConfig.schema_version -eq 1 -and $dialogConfig.contract_id -eq 'ataraxia.dialog.v1') 'Dialog contract configuration has an unsupported schema.'
    foreach($kind in @('message','confirm','input','multiline','file_picker','folder_picker')){Assert-True ($null -ne $dialogConfig.kinds.PSObject.Properties[$kind]) "Dialog contract kind is missing: $kind"}
    Assert-True ($dialogScript -match 'gui-dialog-contracts\.json' -and $dialogScript -match 'AtaraxiaDialogKinds\[\$Kind\]' -and $dialogScript -match 'contract_id=') 'Dialog service does not create contracts from the portable dialog definition.'
    Assert-True ($dialogScript -match 'WindowStyle="None"' -and $dialogScript -match 'AllowsTransparency="True"' -and $dialogScript -match 'Get-AtaraxiaUiIconGeometry' -and $dialogScript -match 'Show-AtaraxiaPathPicker') 'Dialog renderer relies on native window chrome or native path pickers.'
    Assert-True ($gui -match "GuiDialogs\.ps1" -and $gui -match 'Show-AtaraxiaPathPicker' -and $gui -notmatch 'MessageBox\]::Show|OpenFileDialog|FolderBrowserDialog') 'Main GUI still uses system dialogs.'
    foreach($iconName in @('dialog-info','dialog-warning','dialog-error','dialog-question','dialog-input','dialog-text','dialog-close','dialog-folder','dialog-file','dialog-up')){Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot ('assets/ui-icons/'+$iconName+'.svg')) -PathType Leaf) "Dialog SVG icon is missing: $iconName"}
}

Test-Case 'Conversation store replaces the latest request and branches cleanly' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'ConversationStore.ps1')
    $tempDirectory=Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDirectory | Out-Null
    $conversationPath=Join-Path $tempDirectory 'conversation.json'
    Add-AtaraxiaRequest $conversationPath 'First goal' | Out-Null
    Add-AtaraxiaRequest $conversationPath 'Second goal' | Out-Null
    Add-AtaraxiaRequest $conversationPath 'Revised goal' -ReplaceLatest | Out-Null
    $conversation=Get-AtaraxiaConversation $conversationPath
    Assert-True ($conversation.entries.Count -eq 2 -and $conversation.entries[-1].body -eq 'Revised goal') 'Editing the latest request did not replace the active conversation branch.'
    Remove-Item -LiteralPath $conversationPath -Force
    Remove-Item -LiteralPath $tempDirectory -Force
}

Test-Case 'Conversation view expands only the latest report' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'GuiConversationModel.ps1')
    $conversation=[pscustomobject]@{entries=@([pscustomobject]@{kind='user_query';body='First prompt';timestamp='2026-01-01T00:00:00Z'})}
    $state=[pscustomobject]@{history=@(
        [pscustomobject]@{role='planner';timestamp='2026-01-01T00:00:01Z';report=[pscustomobject]@{heading='Plan';body='Plan details'}},
        [pscustomobject]@{role='executor';timestamp='2026-01-01T00:00:02Z';report=[pscustomobject]@{heading='Changes';body='Change details'}},
        [pscustomobject]@{role='reviewer';timestamp='2026-01-01T00:00:03Z';report=[pscustomobject]@{heading='Review';body='Review details'}}
    )}
    $view=ConvertTo-AtaraxiaConversationView $conversation $state
    $reports=@($view|Where-Object{$_.kind -eq 'report'})
    Assert-True ($reports.Count -eq 3 -and @($reports|Where-Object{$_.is_expanded}).Count -eq 1 -and $reports[-1].is_expanded) 'Only the last report should be expanded by default.'
}

Test-Case 'Every built-in role has an SVG icon in report headings' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'GuiConversationModel.ps1')
    $contracts=Read-Json (Join-Path $projectRoot 'configs/role-contracts.json')
    $history=@()
    foreach($role in $contracts.generic_agent.roles){
        $iconPath=Join-Path (Join-Path $projectRoot 'assets/role-icons') ($role.id+'.svg')
        Assert-True (Test-Path -LiteralPath $iconPath -PathType Leaf) "Missing SVG role icon: $($role.id)"
        $xml=[xml]::new();$xml.Load($iconPath)
        Assert-True ($xml.DocumentElement.LocalName -eq 'svg') "Role icon is not a valid SVG: $($role.id)"
        $history+=@([pscustomobject]@{role=$role.id;timestamp='2026-01-01T00:00:01Z';report=[pscustomobject]@{heading=$role.id;body='result'}})
    }
    $view=ConvertTo-AtaraxiaConversationView ([pscustomobject]@{entries=@()}) ([pscustomobject]@{history=$history})
    Assert-True (@($view|Where-Object{[string]::IsNullOrWhiteSpace([string]$_.icon_geometry)}).Count -eq 0) 'A built-in role report has no display icon geometry.'
}

Test-Case 'Project drawer operations create, switch, list, and rename safely' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'Localization.ps1')
    . (Join-Path (Join-Path $projectRoot 'scripts') 'ProjectStore.ps1')
    $tempDirectory=Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
    $projectsRoot=Join-Path $tempDirectory 'projects';$configPath=Join-Path $tempDirectory 'config.json'
    New-Item -ItemType Directory -Path $projectsRoot -Force | Out-Null
    [IO.File]::WriteAllText($configPath,'{"project_name":"Ataraxia"}',[Text.UTF8Encoding]::new($false))
    New-AtaraxiaProject $projectsRoot 'Research' | Out-Null
    $listed=Get-AtaraxiaProjectNames $projectsRoot
    Assert-True ($listed -contains 'Research') 'New project is absent from the project list.'
    Set-AtaraxiaActiveProject $configPath $projectsRoot 'Research' | Out-Null
    Assert-True ((Read-Json $configPath).project_name -eq 'Research') 'Switching project did not update the active project setting.'
    Rename-AtaraxiaProject $projectsRoot 'Research' 'Studio' | Out-Null
    Assert-True ((Get-AtaraxiaProjectNames $projectsRoot) -contains 'Studio' -and -not (Test-Path (Join-Path $projectsRoot 'Research'))) 'Project rename did not move the folder.'
    Set-AtaraxiaActiveProject $configPath $projectsRoot 'Studio' | Out-Null
    Assert-True ((Read-Json $configPath).project_name -eq 'Studio') 'Renamed active project was not selected.'
    $rejected=$false;try{New-AtaraxiaProject $projectsRoot '../escape'|Out-Null}catch{$rejected=$true}
    Assert-True $rejected 'Invalid project name was accepted.'
    Remove-Item -LiteralPath $configPath -Force
    Remove-Item -LiteralPath (Join-Path $projectsRoot 'Studio') -Force
    Remove-Item -LiteralPath $projectsRoot -Force
    Remove-Item -LiteralPath $tempDirectory -Force
}

Test-Case 'Project sessions retain isolated task context' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'RoleContracts.ps1')
    . (Join-Path (Join-Path $projectRoot 'scripts') 'AgentCore.ps1')
    . (Join-Path (Join-Path $projectRoot 'scripts') 'SessionStore.ps1')
    . (Join-Path (Join-Path $projectRoot 'scripts') 'ConversationStore.ps1')
    $tempDirectory=Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
    $projectPath=Join-Path $tempDirectory 'Ataraxia';New-Item -ItemType Directory -Path $projectPath -Force|Out-Null
    $contracts=Import-RoleContracts ([pscustomobject]@{})
    $first=New-AtaraxiaSession $projectPath $contracts 'First context'
    $second=New-AtaraxiaSession $projectPath $contracts 'Second context'
    Assert-True ($first.id -ne $second.id -and (Test-Path (Join-Path $first.path $first.task_file)) -and (Test-Path (Join-Path $second.path $second.task_file))) 'Sessions do not have distinct task contexts.'
    $firstConversation=Join-Path $first.path 'conversation.json';$secondConversation=Join-Path $second.path 'conversation.json'
    Add-AtaraxiaRequest $firstConversation 'Context for the first session'|Out-Null
    Assert-True ((Get-AtaraxiaSessions $projectPath).Count -eq 2 -and -not(Test-Path $secondConversation)) 'Session context leaked into another session.'
    Add-AtaraxiaRequest $secondConversation 'A more recent request'|Out-Null
    $older=Get-AtaraxiaConversation $firstConversation;$older.entries[0].timestamp='2026-01-01T00:00:00.0000000Z';Save-AtaraxiaConversation $firstConversation $older
    $newer=Get-AtaraxiaConversation $secondConversation;$newer.entries[0].timestamp='2026-01-02T00:00:00.0000000Z';Save-AtaraxiaConversation $secondConversation $newer
    $recent=Get-AtaraxiaRecentSessions $tempDirectory 5
    Assert-True ($recent.Count -eq 2 -and $recent[0].id -eq $second.id -and $recent[1].id -eq $first.id -and $recent[0].project_name -eq 'Ataraxia') 'Recent requests are not ordered newest first or session project ownership was lost.'
    $renamed=Set-AtaraxiaSessionTitle $first.path 'Planning notes' 'user'
    Assert-True ($renamed.title -eq 'Planning notes' -and $renamed.title_generated -and $renamed.title_source -eq 'user') 'Manual session naming was not persisted.'
    $runner=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/Invoke-Agent.ps1') -Raw -Encoding UTF8
    Assert-True ($runner -match 'title_generated' -and $runner -match 'session_namer' -and $runner -match 'first_prompt') 'Runner does not name new sessions from their first prompt.'
    Assert-True ($runner -match 'Agent-SelectRoleInput \$reportInput \$reportConfig') 'Reporter input bypasses the configured role contract.'
    Touch-AtaraxiaSession $first.path
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force
}

Test-Case 'Project and session common prompts are stored and composed' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'CommonPrompts.ps1')
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-prompt-'+[guid]::NewGuid().ToString('N'))
    $project=Join-Path $root 'Sample';$session=Join-Path $project 'sessions/session-1';New-Item -ItemType Directory -Force $session|Out-Null;[IO.File]::WriteAllText((Join-Path $session 'session.json'),'{"artifact_type":"session","id":"session-1"}')
    try{
        Set-AtaraxiaProjectCommonPrompt $project 'Keep all output concise.'
        Set-AtaraxiaSessionCommonPrompt $session 'Use the existing terminology.'
        $combined=Get-AtaraxiaCommonPromptForTaskDirectory $session
        Assert-True ($combined -match 'Keep all output concise\.' -and $combined -match 'Use the existing terminology\.') 'Common prompts were not both resolved for the session.'
        . (Join-Path (Join-Path $projectRoot 'scripts') 'AgentCore.ps1')
        $rolePrompt=Agent-GetRoleSystemPrompt ([pscustomobject]@{resources_root='';resources_user='default-user';agent_common_prompt=$combined}) ([pscustomobject]@{system_prompt='missing-prompt';purpose='Role purpose.'}) 'Role purpose.'
        Assert-True ($rolePrompt -match 'Role purpose\.' -and $rolePrompt -match 'Keep all output concise\.' -and $rolePrompt -match 'Use the existing terminology\.') 'Common prompts are not appended to role system messages.'
        $sessionOnly=Get-AtaraxiaCommonPromptForTaskDirectory (Join-Path $root 'NoProject/sessions/session-2')
        Assert-True ([string]::IsNullOrEmpty($sessionOnly)) 'Missing common prompts should resolve to empty text.'
    }finally{Remove-Item -LiteralPath $root -Recurse -Force}
}

Test-Case 'Stopped agent run restores workspace diffs and prior task state' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'WorkspaceDiff.ps1')
    . (Join-Path (Join-Path $projectRoot 'scripts') 'AgentHarness.ps1')
    . (Join-Path (Join-Path $projectRoot 'scripts') 'AgentCore.ps1')
    $root=Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
    $workspace=Join-Path $root 'workspace';$task=Join-Path $root 'task';New-Item -ItemType Directory -Path $workspace,$task -Force|Out-Null
    $existing=Join-Path $workspace 'existing.txt';$statePath=Join-Path $task 'state.json';$journal=Join-Path $task 'run-changes.json'
    [IO.File]::WriteAllText($existing,'before',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($statePath,'old-state',[Text.UTF8Encoding]::new($false))
    New-AgentChangeJournal $journal $workspace $statePath | Out-Null
    $change=[pscustomobject]@{path='existing.txt';action='modify';base_hash=(Get-AgentWorkspaceHash 'before');operations=@([pscustomobject]@{op='delete';count=0;lines=@('before')},[pscustomobject]@{op='insert';count=0;lines=@('after')})}
    $create=[pscustomobject]@{path='created.txt';action='create';base_hash=(Get-AgentWorkspaceHash '');operations=@([pscustomobject]@{op='insert';count=0;lines=@('new')})}
    Apply-AgentWorkspaceChanges $workspace @($change,$create) $journal | Out-Null
    Agent-SaveState $statePath ([pscustomobject]@{value='new-state'}) $journal
    Assert-True (([IO.File]::ReadAllText($existing) -eq 'after') -and (Test-Path -LiteralPath (Join-Path $workspace 'created.txt'))) 'Diffs were not applied for the rollback test.'
    Restore-AgentRunChanges $workspace $journal $statePath | Out-Null
    Assert-True (([IO.File]::ReadAllText($existing) -eq 'before') -and -not (Test-Path -LiteralPath (Join-Path $workspace 'created.txt')) -and [IO.File]::ReadAllText($statePath) -eq 'old-state') 'Stopping did not restore changed files and prior task state.'
    Remove-Item -LiteralPath $existing -Force;Remove-Item -LiteralPath $statePath -Force;Remove-Item -LiteralPath $workspace -Force;Remove-Item -LiteralPath $task -Force;Remove-Item -LiteralPath $root -Force
}

Test-Case 'Documentation uses Ataraxia and domain independent requirements' {
    $readme=Get-Content -LiteralPath (Join-Path $projectRoot 'README.md') -Raw -Encoding UTF8
    $spec=Get-Content -LiteralPath (Join-Path $projectRoot 'docs/SPECIFICATION.md') -Raw -Encoding UTF8
    $policy=Get-Content -LiteralPath (Join-Path $projectRoot 'docs/AGENTS.md') -Raw -Encoding UTF8
    Assert-True ($readme.StartsWith('# Ataraxia') -and $readme -match 'Invoke-Agent\.ps1') 'README does not describe Ataraxia generic CLI.'
    Assert-True ($spec -match '特定のドメインに限定しない' -and $spec -notmatch 'Invoke-NovelWriter') 'Specification retains domain-specific workflow assumptions.'
    Assert-True ($spec.StartsWith('# Ataraxia 技術仕様書') -and $spec -notmatch '(?m)^## (Purpose|Entry points|Domain-independent workflow|Workspace changes and commands|Context and local resource assumptions|Reports and GUI behavior|Configuration and dependencies|Development requirements)$') 'Technical specification prose and section headings are not Japanese.'
    Assert-True ($spec -match '(?m)^## 用語定義$' -and $spec -match '\| 用語 \| 定義 \| 対応する識別子・保存先 \| 表記規則 \|' -and $spec -match '\| セッション \|' -and $spec -match '\| 作業対象 \|' -and $spec -match '\| ワークフロー段階 \|') 'Project terminology and canonical usage are not defined in a table after the overview.'
    foreach($roleId in @('core','planner','researcher','executor','reviewer','improver','router','verifier','security_reviewer','impact_reviewer','context_compressor','reporter','session_namer')){Assert-True ($spec -match [regex]::Escape($roleId) -and $spec -match ([regex]::Escape($roleId)+'.svg')) "Specification role table is missing detail for $roleId."}
    Assert-True ($policy -match 'テスト駆動開発') 'Development policy no longer states TDD.'
}

Write-Output "Result: $passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }


