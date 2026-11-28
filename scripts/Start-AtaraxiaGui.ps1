[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$NoSplash
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $projectRoot 'configs/config.json' }
. (Join-Path $PSScriptRoot 'GuiApplication.ps1')
. (Join-Path $PSScriptRoot 'GuiModelParameterApplication.ps1')
. (Join-Path $PSScriptRoot 'GuiThemeApplication.ps1')
. (Join-Path $PSScriptRoot 'GuiSingleInstance.ps1')
. (Join-Path $PSScriptRoot 'adapters/PowerShellGuiSingleInstanceAdapter.ps1')
. (Join-Path $PSScriptRoot 'GuiErrorLogging.ps1')
. (Join-Path $PSScriptRoot 'GuiProcessApplication.ps1')
. (Join-Path $PSScriptRoot 'adapters/PowerShellGuiProcessAdapter.ps1')
$guiStartupPlan=New-AtaraxiaGuiStartupPlan -ScriptPath $PSCommandPath -ConfigPath $ConfigPath -NoSplash:$NoSplash
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    $hostPath = (Get-Process -Id $PID).Path
    $request=New-AtaraxiaGuiStartupRelaunchRequest $hostPath $guiStartupPlan $projectRoot
    $null=Start-AtaraxiaGuiChildProcess $request
    exit 0
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$script:guiInstance=Enter-AtaraxiaGuiInstance (Get-AtaraxiaGuiInstanceIdentity $ConfigPath)
if(-not $script:guiInstance.is_primary){exit 0}
. (Join-Path $PSScriptRoot 'Localization.ps1')
. (Join-Path $PSScriptRoot 'ConversationStore.ps1')
. (Join-Path $PSScriptRoot 'GuiConversationModel.ps1')
. (Join-Path $PSScriptRoot 'GuiPresentationPort.ps1')
. (Join-Path $PSScriptRoot 'GuiScreenState.ps1')
. (Join-Path $PSScriptRoot 'GuiNavigationState.ps1')
$script:guiScreenState=New-AtaraxiaGuiScreenState
$script:guiNavigationState=New-AtaraxiaGuiNavigationState
. (Join-Path $PSScriptRoot 'GuiLocalizedPresentation.ps1')
. (Join-Path $PSScriptRoot 'adapters/WpfContextMenuAdapter.ps1')
. (Join-Path $PSScriptRoot 'adapters/ModelFileSystemAdapter.ps1')
. (Join-Path $PSScriptRoot 'ProjectStore.ps1')
. (Join-Path $PSScriptRoot 'RoleContracts.ps1')
. (Join-Path $PSScriptRoot 'AgentCore.ps1')
. (Join-Path $PSScriptRoot 'SessionStore.ps1')
. (Join-Path $PSScriptRoot 'GuiTheme.ps1')
. (Join-Path $PSScriptRoot 'adapters/WindowsSystemThemeAdapter.ps1')
. (Join-Path $PSScriptRoot 'GuiModelParameters.ps1')
. (Join-Path $PSScriptRoot 'GuiModelParameterEditorState.ps1')
. (Join-Path $PSScriptRoot 'GuiInputLayout.ps1')
. (Join-Path $PSScriptRoot 'CommonPrompts.ps1')
. (Join-Path $PSScriptRoot 'KoboldCppSettings.ps1')
$script:queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:process = $null
. (Join-Path $PSScriptRoot 'GuiProcessState.ps1')
$script:guiProcessState=New-AtaraxiaGuiProcessState
. (Join-Path $PSScriptRoot 'adapters/PowerShellGuiProcessOutputAdapter.ps1')
. (Join-Path $PSScriptRoot 'adapters/TcpConnectionAdapter.ps1')
function New-AtaraxiaGuiProjectSessionAdapters {
    $script:guiJsonFileStore=$script:guiJsonStore
    $script:guiSessionStore=New-AtaraxiaSessionStoreDependencies -FileStore $script:guiJsonFileStore -ReadJson {param($Path,$MaximumBytes)Read-AtaraxiaGuiJsonFile $Path $MaximumBytes} -WriteJson {param($Path,$Value,$Depth)if($null -eq $Depth -or [int]$Depth -lt 1){$Depth=50};Write-AtaraxiaJsonStoreFile $Path $Value $script:guiJsonFileStore $Depth}
    $listProjects={param($Root)Get-AtaraxiaProjectNames $Root $script:guiJsonFileStore}.GetNewClosure()
    $resolvePath={param($Root,$Name)Get-AtaraxiaProjectPath $Root $Name}.GetNewClosure()
    $guiReadJson={param($JsonPath,$MaximumBytes)Read-AtaraxiaGuiJsonFile $JsonPath $MaximumBytes}.GetNewClosure()
    $listSessions={param($Path,$Reader)Get-AtaraxiaSessions $Path $script:guiSessionStore}.GetNewClosure()
    $listRecent={param($Root,$Maximum,$Reader)Get-AtaraxiaRecentSessions $Root $Maximum $script:guiSessionStore}.GetNewClosure()
    $projectExists={param($Path)(Test-AtaraxiaStorePath $Path 'Container' $script:guiJsonFileStore)}.GetNewClosure()
    $createProject={param($Root,$Name)New-AtaraxiaProject $Root $Name $script:guiJsonFileStore}.GetNewClosure()
    $renameProject={param($Root,$Old,$New)Rename-AtaraxiaProject $Root $Old $New $script:guiJsonFileStore}.GetNewClosure()
    $roleContracts=Import-RoleContracts (Get-AtaraxiaConfig) $RuntimeConfig.Text
    $createSession={param($Path,$Contracts,$Title)New-AtaraxiaSession $Path $Contracts $Title $script:guiSessionStore}.GetNewClosure()
    $renameSession={param($Path,$Title,$Source)Set-AtaraxiaSessionTitle $Path $Title $Source $script:guiSessionStore}.GetNewClosure()
    $configPath=[IO.Path]::GetFullPath($RuntimeConfig.Text);$projectsRoot=Get-ProjectsRoot
    $activate={param($Name)$null=Set-AtaraxiaActiveProject $configPath $projectsRoot $Name $script:guiSessionStore}.GetNewClosure()
    $dependencies=New-AtaraxiaGuiProjectSessionDependencies $listProjects $resolvePath $listSessions $listRecent $projectExists $createProject $renameProject $createSession $renameSession $activate
    $dependencies|Add-Member -NotePropertyName json_reader -NotePropertyValue $guiReadJson
    return $dependencies
}
$script:koboldProcess=$null
$script:koboldSetupProcess=$null
$script:koboldSetupStdoutPath=''
$script:koboldSetupStderrPath=''
$script:sessionSelectionState=New-AtaraxiaGuiSessionSelectionState

$script:themeState=New-AtaraxiaGuiThemeState
$script:updatingTheme=$false

$xamlPath=Join-Path $PSScriptRoot 'presentation/AtaraxiaWindow.xaml'
[xml]$xaml=[IO.File]::ReadAllText($xamlPath)

$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
$windowIconPath=Join-Path $projectRoot 'assets/branding/ataraxia-app-icon.png';if(Test-Path -LiteralPath $windowIconPath -PathType Leaf){$window.Icon=[Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new([IO.Path]::GetFullPath($windowIconPath)))}
foreach ($name in @('ProjectDrawer','SettingsPanel','ConversationPage','SettingsToggle','CloseSettings','SettingsTitle','ProjectGroupExpander','ProjectGroupTitle','ProjectTreePanel','ProjectTreeScroll','RecentSessionsExpander','RecentSessionsHeaderButton','RecentSessionsTitle','RecentSessionsPanel','NewProject','ProjectPromptButton','SessionPromptButton','SettingsScrollViewer','SettingsGeneralTitle','SettingsModelTitle','ModelSettingsSection','SessionSelector','NewSession','OtherSession','ConfigLabel','RuntimeConfig','BrowseConfig','ThemeLabel','ThemeSelector','KoboldStatusDot','KoboldStatusText','KoboldToggle','KoboldRestart','TaskNameLabel','TaskName','WorkspaceLabel','Workspace','BrowseTask','BrowseWorkspace','ModelFileLabel','ModelFileSelector','RefreshModels','ParameterPresetBar','ParameterPresetSelector','SaveParameterPreset','SaveAsParameterPreset','RenameParameterPreset','DeleteParameterPreset','ParameterPanel','ConversationLabel','ConversationScrollViewer','Conversation','Goal','ScrollToLatest','CreateTask','EditLast','RunTask','Status','Progress')) { Set-Variable -Name $name -Value $window.FindName($name) -Scope Script }
. (Join-Path $PSScriptRoot 'adapters/WpfGuiViewAdapter.ps1')
. (Join-Path $PSScriptRoot 'adapters/WpfThemeAdapter.ps1')
. (Join-Path $PSScriptRoot 'adapters/WpfIconAssetAdapter.ps1')
. (Join-Path $PSScriptRoot 'adapters/WpfSmoothExpanderAdapter.ps1')
. (Join-Path $PSScriptRoot 'adapters/WpfProjectDrawerAdapter.ps1')
. (Join-Path $PSScriptRoot 'adapters/WpfModelParameterAdapter.ps1')
$script:wpfSmoothExpanderRegistry=New-AtaraxiaWpfSmoothExpanderRegistry
$script:guiLocalizedPresentation=New-AtaraxiaGuiLocalizedPresentation {param($Key)Get-AppText $Key}
$script:guiSessionMenu=New-AtaraxiaWpfSessionContextMenu $OtherSession $script:guiLocalizedPresentation
$script:guiViewPort=New-AtaraxiaWpfGuiViewPort @{conversation=$Conversation;sessions=$SessionSelector;models=$ModelFileSelector;status=$Status;session_selector=$SessionSelector;theme_selector=$ThemeSelector;model_selector=$ModelFileSelector;refresh_models=$RefreshModels;parameter_presets=$ParameterPresetSelector;save_parameter_preset=$SaveParameterPreset;save_as_parameter_preset=$SaveAsParameterPreset;rename_parameter_preset=$RenameParameterPreset;delete_parameter_preset=$DeleteParameterPreset;new_session=$NewSession;create_task=$CreateTask;edit_last=$EditLast;run_task=$RunTask;goal=$Goal;conversation_scroll=$ConversationScrollViewer;scroll_latest=$ScrollToLatest;main_window=$window;conversation_page=$ConversationPage;project_drawer=$ProjectDrawer;settings_panel=$SettingsPanel;recent_sessions_header=$RecentSessionsHeaderButton;recent_sessions_group=$RecentSessionsExpander;new_project=$NewProject;settings_toggle=$SettingsToggle;close_settings=$CloseSettings;project_prompt=$ProjectPromptButton;session_prompt_button=$SessionPromptButton;other_session=$OtherSession;copy_session_id_menu=$script:guiSessionMenu.copy_session_id;rename_session_menu=$script:guiSessionMenu.rename_session;session_prompt_menu=$script:guiSessionMenu.session_prompt;browse_config=$BrowseConfig;browse_task=$BrowseTask;browse_workspace=$BrowseWorkspace;kobold_toggle=$KoboldToggle;kobold_restart=$KoboldRestart;dispatcher=$window.Dispatcher} @{status='Text';conversation_page='Visibility';project_drawer='Visibility';settings_panel='Visibility';rename_session_menu='IsEnabled';delete_parameter_preset='ToolTip'} -InputHeightCalculator ${function:Get-AtaraxiaGuiInputHeight}

$script:createThemeBrush={param($Hex)$color=[Windows.Media.ColorConverter]::ConvertFromString([string]$Hex);[Windows.Media.SolidColorBrush]::new($color)}.GetNewClosure()
function Set-AtaraxiaGuiStatusText([object]$Value){Set-AtaraxiaGuiViewValue $script:guiViewPort 'status' $Value}
function Report-AtaraxiaGuiError([object]$ErrorRecord,[string]$Context){
    $log=Write-AtaraxiaGuiErrorLog $ErrorRecord $Context
    if($log.written){Set-AtaraxiaGuiStatusText (Get-AppText 'gui_error_logged' @($log.path))}
    else{Set-AtaraxiaGuiStatusText (Get-AppText 'gui_error_log_failed' @($log.path,$log.error))}
}
function Invoke-AtaraxiaGuiNavigation([ValidateSet('open_settings','close_settings')][string]$Action) {
    $transition=Set-AtaraxiaGuiNavigationState $script:guiNavigationState $Action;$script:guiNavigationState=$transition.state
    foreach($target in $transition.visibility.PSObject.Properties.Name){Set-AtaraxiaGuiViewValue $script:guiViewPort $target ([bool]$transition.visibility.$target)}
}
function Update-AtaraxiaGoalInputHeight {
    if($null -eq $Goal){return}
    Schedule-AtaraxiaGuiViewCallback $script:guiViewPort 'layout_idle' {Invoke-AtaraxiaGuiViewOperation $script:guiViewPort update_multiline_input_height 'goal'}
}
Register-AtaraxiaGuiViewAction $script:guiViewPort 'goal' 'text_change' {Update-AtaraxiaGoalInputHeight};Register-AtaraxiaGuiViewAction $script:guiViewPort 'goal' 'size_change' {Update-AtaraxiaGoalInputHeight}
$window.Resources['ExpanderChevronRightGeometry']=Get-AtaraxiaWpfUiIconGeometry $projectRoot 'chevron-right';$window.Resources['ExpanderChevronDownGeometry']=Get-AtaraxiaWpfUiIconGeometry $projectRoot 'chevron-down'
foreach($iconButton in @(@('NewProject','new-project'),@('ProjectPromptButton','project-prompt-button'),@('SessionPromptButton','session-prompt-button'),@('SettingsToggle','settings'),@('NewSession','new-session'),@('BrowseConfig','browse-config'),@('KoboldRestart','kobold-restart'),@('BrowseTask','browse-task'),@('BrowseWorkspace','browse-workspace'),@('RefreshModels','refresh-models'),@('ScrollToLatest','scroll-to-latest'),@('CreateTask','create-task'),@('EditLast','edit-last'),@('RunTask','send'),@('SaveParameterPreset','save'),@('SaveAsParameterPreset','save-as'),@('RenameParameterPreset','rename-session'),@('DeleteParameterPreset','trash'))){$iconControl=$window.FindName($iconButton[0]);Set-AtaraxiaWpfPathIcon $iconControl.Content $projectRoot $iconButton[1];$iconControl.Padding=[Windows.Thickness]::new(3);if($iconButton[0] -match 'ParameterPreset') {Set-AtaraxiaWpfPathForeground $iconControl.Content}}
Set-AtaraxiaWpfPathForeground $NewSession.Content;Set-AtaraxiaWpfPathForeground $CloseSettings.Content
$OtherSession.Content=[Windows.Shapes.Path]::new();Set-AtaraxiaWpfPathIcon $OtherSession.Content $projectRoot 'more';$OtherSession.Content.Width=18;$OtherSession.Content.Height=18;$OtherSession.Content.Stretch='Uniform';Set-AtaraxiaWpfPathForeground $OtherSession.Content;$OtherSession.Content.StrokeThickness=1.8
. (Join-Path $PSScriptRoot 'GuiDialogContracts.ps1')
$script:guiDialogDefinitions=[IO.File]::ReadAllText((Join-Path $projectRoot 'configs/gui-dialog-contracts.json'))|ConvertFrom-Json
. (Join-Path $PSScriptRoot 'GuiDialogs.ps1')
. (Join-Path $PSScriptRoot 'adapters/PowerShellDialogPathAdapter.ps1')
. (Join-Path $PSScriptRoot 'adapters/WpfDialogAdapter.ps1')
$script:guiDialogContractFactory={param($Definitions,$Kind,$Title,$Message,$Value,$Icon,$PrimaryLabel,$SecondaryLabel)New-AtaraxiaDialogContract -Definitions $Definitions -Kind $Kind -Title $Title -Message $Message -Value $Value -Icon $Icon -PrimaryLabel $PrimaryLabel -SecondaryLabel $SecondaryLabel}
$script:guiDialogResultResolver={param($Contract,$Result)ConvertTo-AtaraxiaGuiDialogResult $Contract $Result}
$script:guiDialogTextResolver={param($Key)Get-AppText $Key}
$script:guiDialogRenderer={param($Contract)Render-AtaraxiaWpfDialog $Contract $window}.GetNewClosure()
$script:guiDialogPathPicker={param($Contract,$InitialDirectory,$Patterns)Render-AtaraxiaWpfPathPicker $Contract $window $InitialDirectory $Patterns $script:guiDialogTextResolver}.GetNewClosure()
$script:guiDialogService=New-AtaraxiaGuiDialogService $script:guiDialogDefinitions $script:guiDialogContractFactory $script:guiDialogResultResolver $script:guiDialogTextResolver $script:guiDialogRenderer $script:guiDialogPathPicker
function Show-AtaraxiaMessageDialog { param([string]$Message,[string]$Title,[ValidateSet('information','warning','question')][string]$Kind='information',[bool]$Confirm=$false,[string]$PrimaryLabel='',[string]$SecondaryLabel='');Invoke-AtaraxiaGuiDialogService $script:guiDialogService message @($Title,$Kind,$Message,$Confirm,$PrimaryLabel,$SecondaryLabel) }
function Invoke-AtaraxiaGuiJsonRepair([object]$Proposal,[object]$FileSystem) {
    if(-not $Proposal.repairable){$message=Get-AppText 'gui_json_repair_unavailable' @($Proposal.path,$Proposal.reason);Report-AtaraxiaGuiError ([InvalidOperationException]::new($message)) 'json_repair_unavailable';return [pscustomobject]@{applied=$false;reason='unrepairable';backup_path=''}}
    $recovered=if(@($Proposal.recovered).Count -gt 0){@($Proposal.recovered) -join ', '}else{Get-AppText 'gui_json_repair_none'}
    $defaulted=if(@($Proposal.defaulted).Count -gt 0){@($Proposal.defaulted) -join ', '}else{Get-AppText 'gui_json_repair_none'}
    $message=Get-AppText 'gui_json_repair_question' @($Proposal.path,$recovered,$defaulted,$Proposal.backup_path)
    $confirm=Show-AtaraxiaMessageDialog -Message $message -Title (Get-AppText 'gui_json_repair_title') -Kind question -Confirm $true -PrimaryLabel (Get-AppText 'gui_yes') -SecondaryLabel (Get-AppText 'gui_no')
    if(-not $confirm){return [pscustomobject]@{applied=$false;reason='declined';backup_path=''}}
    $approved={param($IgnoredProposal)return $true}
    $result=Invoke-AgentJsonRepairProposal $Proposal $Proposal.path $approved $FileSystem
    if($result.applied){$null=Set-AtaraxiaGuiStatusText (Get-AppText 'gui_json_repair_done' @($result.backup_path))}
    return $result
}
$script:guiJsonFileSystem=New-AgentJsonFileSystemPort
function Read-AtaraxiaGuiJsonFile([string]$Path,[long]$MaximumBytes=4194304) { Read-AgentJsonFile $Path $MaximumBytes {param($Proposal,$FileSystem)Invoke-AtaraxiaGuiJsonRepair $Proposal $FileSystem} $script:guiJsonFileSystem }
$script:guiJsonStore=New-AtaraxiaJsonFileStoreDependencies -ReadJson {param($Path,$MaximumBytes)Read-AtaraxiaGuiJsonFile $Path $MaximumBytes}
$script:guiJsonFileStore=$script:guiJsonStore
function Show-AtaraxiaInputDialog([string]$Title,[string]$InitialValue='',[string]$Message='') { Invoke-AtaraxiaGuiDialogService $script:guiDialogService input @($Title,$InitialValue,$Message) }
function Show-AtaraxiaMultilineDialog([string]$Title,[string]$InitialValue='',[string]$Message='') { Invoke-AtaraxiaGuiDialogService $script:guiDialogService multiline @($Title,$InitialValue,$Message) }
function Show-AtaraxiaProjectNameDialog([string]$Title,[string]$InitialValue='') { Invoke-AtaraxiaGuiDialogService $script:guiDialogService project_name @($Title,$InitialValue) }
function Show-AtaraxiaCommonPromptDialog([string]$Title,[string]$InitialValue) { Invoke-AtaraxiaGuiDialogService $script:guiDialogService common_prompt @($Title,$InitialValue) }
function Show-AtaraxiaPathPicker { param([Parameter(Mandatory)][Windows.Window]$Owner,[ValidateSet('file','folder')][string]$Kind,[string]$Title,[string]$InitialDirectory,[string[]]$Patterns=@('*'));Invoke-AtaraxiaGuiDialogService $script:guiDialogService path_picker @($Kind,$Title,$InitialDirectory,$Patterns) }
$script:localizedControls=@{window=$window;theme_selector=$ThemeSelector;settings_general_title=$SettingsGeneralTitle;config_label=$ConfigLabel;theme_label=$ThemeLabel;settings_model_title=$SettingsModelTitle;project_prompt_button=$ProjectPromptButton;session_prompt_button=$SessionPromptButton;project_group_title=$ProjectGroupTitle;recent_sessions_title=$RecentSessionsTitle;new_project=$NewProject;task_name_label=$TaskNameLabel;workspace_label=$WorkspaceLabel;browse_config=$BrowseConfig;new_session=$NewSession;other_session=$OtherSession;browse_task=$BrowseTask;browse_workspace=$BrowseWorkspace;kobold_restart=$KoboldRestart;model_file_label=$ModelFileLabel;refresh_models=$RefreshModels;conversation_label=$ConversationLabel;scroll_latest=$ScrollToLatest;create_task=$CreateTask;edit_last=$EditLast;run_task=$RunTask;save_parameter_preset=$SaveParameterPreset;save_as_parameter_preset=$SaveAsParameterPreset;rename_parameter_preset=$RenameParameterPreset;delete_parameter_preset=$DeleteParameterPreset}
$RuntimeConfig.Text = [IO.Path]::GetFullPath($ConfigPath)
Register-AgentJsonRepairKind $RuntimeConfig.Text 'config'
function Set-AtaraxiaLanguage([string]$Language) {
    Set-AppLanguage $Language
    $script:guiLocalizedPresentation=New-AtaraxiaGuiLocalizedPresentation {param($Key)Get-AppText $Key}
    $script:updatingTheme=$true
    try { Set-AtaraxiaWpfLocalizedPresentation $script:localizedControls $script:guiLocalizedPresentation $script:themeState.preference } finally { $script:updatingTheme=$false }
    Set-AtaraxiaWpfSessionContextMenuLanguage $script:guiSessionMenu $script:guiLocalizedPresentation
    Set-AtaraxiaGuiStatusText $script:guiLocalizedPresentation.status_ready
    Set-KoboldToggleIcon;Set-RunTaskIcon $false
}
function Apply-AtaraxiaTheme([string]$Mode) {
    Set-AtaraxiaWpfThemeResources $window.Resources $Mode $script:createThemeBrush
}
function Load-AtaraxiaThemePreference {
    try{$settings=Get-AtaraxiaConfig;$mode=[string]$settings.gui_theme;if($mode -notin @('system','light','dark')){$mode='system'}}catch{$mode='system'}
    $transition=Set-AtaraxiaGuiThemeState $script:themeState $mode (Get-AtaraxiaWindowsSystemTheme);$script:themeState=$transition.state
    if($transition.sync_selector){$script:updatingTheme=$true;$ThemeSelector.SelectedValue=$script:themeState.preference;$script:updatingTheme=$false}
    if($transition.apply_theme){Apply-AtaraxiaTheme $script:themeState.effective}
}
function Save-AtaraxiaThemePreference([string]$Mode) {
    $savePreference={param($Preference)$configPath=[IO.Path]::GetFullPath($RuntimeConfig.Text);$settings=Get-AtaraxiaConfig;$settings|Add-Member -NotePropertyName gui_theme -NotePropertyValue $Preference -Force;Write-AtaraxiaJsonStoreFile $configPath $settings $script:guiJsonStore 100}
    try{$transition=Invoke-AtaraxiaGuiThemePreferenceSave $script:themeState $Mode (Get-AtaraxiaWindowsSystemTheme) $savePreference}catch{$script:updatingTheme=$true;try{$ThemeSelector.SelectedValue=$script:themeState.preference}finally{$script:updatingTheme=$false};throw}
    if(-not $transition.accepted){return};$script:themeState=$transition.state;if($transition.apply_theme){Apply-AtaraxiaTheme $script:themeState.effective}
}
function Get-AtaraxiaRoleLabel([string]$RoleId) {
    $key='gui_role_'+(($RoleId -replace '[^A-Za-z0-9_]','_').ToLowerInvariant())
    try{return Get-AppText $key}catch{return $RoleId}
}
function Convert-AtaraxiaRunOutput([string]$Line) {
    $match=[regex]::Match($Line,'^\s*Run:\s*(?<role>\S.*?)\s*$')
    if(-not $match.Success){return $null}
    return [pscustomobject]@{kind='role';role=$match.Groups['role'].Value.Trim()}
}
function Set-KoboldConnectionIndicator([ValidateSet('connected','disconnected','starting')][string]$State) {
    switch($State){
        'connected'{$KoboldStatusDot.Fill=[Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#2E7D32'));$KoboldStatusText.Text=Get-AppText 'gui_kobold_connected'}
        'starting'{$KoboldStatusDot.Fill=[Windows.Media.Brushes]::DarkOrange;$KoboldStatusText.Text=Get-AppText 'gui_kobold_starting'}
        default{$KoboldStatusDot.Fill=[Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#C62828'));$KoboldStatusText.Text=Get-AppText 'gui_kobold_disconnected'}
    }
    Set-KoboldToggleIcon
    $KoboldRestart.IsEnabled=($null -ne $script:koboldProcess -and -not (Get-AtaraxiaGuiChildProcessStatus $script:koboldProcess).has_exited)
}
function Set-KoboldToggleIcon {
    $managed=($null -ne $script:koboldProcess -and -not (Get-AtaraxiaGuiChildProcessStatus $script:koboldProcess).has_exited)
    $KoboldToggle.ToolTip=if($managed){Get-AppText 'gui_kobold_stop'}else{Get-AppText 'gui_kobold_start'}
    $KoboldToggle.Padding=[Windows.Thickness]::new(3)
    $icon=[Windows.Shapes.Path]$KoboldToggle.Content
    Set-AtaraxiaWpfPathIcon $icon $projectRoot $(if($managed){'kobold-stop'}else{'kobold-start'})
}
function Set-RunTaskIcon([bool]$Stop) {
    $RunTask.ToolTip=if($Stop){Get-AppText 'gui_stop'}else{Get-AppText 'gui_send_run'}
    $icon=[Windows.Shapes.Path]$RunTask.Content
    Set-AtaraxiaWpfPathIcon $icon $projectRoot $(if($Stop){'stop'}else{'send'})
}
function Test-KoboldCppConnection {
    try{$config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text $script:guiJsonStore;$probe={param($HostName,$Port,$TimeoutMilliseconds)Test-AtaraxiaTcpEndpoint $HostName $Port $TimeoutMilliseconds}.GetNewClosure();return Test-AtaraxiaGuiServiceConnection ([string]$config.api_server) $probe 250}catch{return $false}
}
function Update-KoboldConnectionIndicator {
    if($null -ne $script:koboldProcess){$managedStatus=Get-AtaraxiaGuiChildProcessStatus $script:koboldProcess;if($managedStatus.has_exited){Close-AtaraxiaGuiChildProcess $script:koboldProcess;$script:koboldProcess=$null}}
    $setupRunning=$false;if($null -ne $script:koboldSetupProcess){$setupRunning=(-not (Get-AtaraxiaGuiChildProcessStatus $script:koboldSetupProcess).has_exited)}
    $state=Resolve-AtaraxiaGuiKoboldStatus (Test-KoboldCppConnection) ($null -ne $script:koboldProcess) $setupRunning
    Set-KoboldConnectionIndicator $state
}
function Start-KoboldCppFromGui {
    if(Test-KoboldCppConnection){Set-KoboldConnectionIndicator 'connected';Set-AtaraxiaGuiStatusText (Get-AppText 'gui_kobold_already_running');return}
    $config=Get-AtaraxiaConfig;$settings=Import-KoboldCppSettings $config $RuntimeConfig.Text $script:guiJsonStore
    $pathExists={param($Path)(Test-AtaraxiaStoreFile $Path $script:guiJsonFileStore)}.GetNewClosure();$resolveSettings={param($BaseSettings)Get-KoboldCppEffectiveSettings $BaseSettings}.GetNewClosure();$buildArguments={param($EffectiveSettings,$ModelPath)Get-KoboldCppLaunchArguments $EffectiveSettings $ModelPath}.GetNewClosure()
    $plan=New-AtaraxiaGuiKoboldLaunchPlan $settings $projectRoot $pathExists $resolveSettings $buildArguments
    if(-not $plan.ready){switch($plan.reason){'missing_executable'{throw (Get-AppText 'gui_kobold_missing_executable')}'model_required'{throw (Get-AppText 'gui_kobold_model_required')}'missing_model'{throw (Get-AppText 'gui_kobold_model_missing' @($plan.model_path))}default{throw 'KoboldCpp launch plan is invalid.'}}}
    $arguments=@($plan.arguments) -join ' '
    $request=New-AtaraxiaGuiChildProcessRequest $plan.executable $arguments $plan.working_directory
    $process=Start-AtaraxiaGuiChildProcess $request
    $script:koboldProcess=$process;Set-KoboldConnectionIndicator 'starting';Set-AtaraxiaGuiStatusText (Get-AppText 'gui_kobold_starting')
}
function Stop-KoboldCppFromGui {
    $process=$script:koboldProcess;if($null -eq $process){Set-KoboldConnectionIndicator 'disconnected';return}
    try{$null=Stop-AtaraxiaGuiChildProcess $process 5000}finally{$script:koboldProcess=$null}
    Set-KoboldConnectionIndicator 'disconnected';Set-AtaraxiaGuiStatusText (Get-AppText 'gui_kobold_stopped')
}
function Toggle-KoboldCppFromGui {
    try{if($null -ne $script:koboldProcess -and -not (Get-AtaraxiaGuiChildProcessStatus $script:koboldProcess).has_exited){Stop-KoboldCppFromGui}else{Start-KoboldCppFromGui}}catch{Report-AtaraxiaGuiError $_ 'toggle_kobold';Update-KoboldConnectionIndicator}
}
function Restart-KoboldCppFromGui {
    $managedRunning=$null -ne $script:koboldProcess -and -not (Get-AtaraxiaGuiChildProcessStatus $script:koboldProcess).has_exited
    $save={if($script:modelParameterControls.Count -gt 0){Save-AtaraxiaModelParameters}}.GetNewClosure()
    $stop={Stop-KoboldCppFromGui}.GetNewClosure();$probe={Test-KoboldCppConnection}.GetNewClosure()
    $wait={param($milliseconds)Start-Sleep -Milliseconds $milliseconds}.GetNewClosure();$clock={[DateTime]::UtcNow}.GetNewClosure()
    $start={Start-KoboldCppFromGui}.GetNewClosure()
    try {
        $result=Invoke-AtaraxiaGuiKoboldRestart $managedRunning $save $stop $probe $wait $clock $start
        if($result.reason -eq 'managed_process_required'){Set-AtaraxiaGuiStatusText (Get-AppText 'gui_kobold_restart_requires_managed');return}
        if($result.reason -eq 'port_busy'){Set-AtaraxiaGuiStatusText (Get-AppText 'gui_kobold_restart_port_busy');return}
    }catch{Report-AtaraxiaGuiError $_ 'restart_kobold';Update-KoboldConnectionIndicator}
}
function Start-KoboldCppAcquisitionIfMissing {
    $config=Get-AtaraxiaConfig;$settings=Import-KoboldCppSettings $config $RuntimeConfig.Text $script:guiJsonStore
    $configuredExecutable=[string]$settings.paths.executable
    $executable=if([IO.Path]::IsPathRooted($configuredExecutable)){[IO.Path]::GetFullPath($configuredExecutable)}else{[IO.Path]::GetFullPath((Join-Path $projectRoot $configuredExecutable))}
    if(Test-AtaraxiaStoreFile $executable $script:guiJsonFileStore){return}
    $initializer=Join-Path $PSScriptRoot 'Initialize-KoboldCpp.ps1'
    if(-not(Test-AtaraxiaStoreFile $initializer $script:guiJsonFileStore)){throw "KoboldCpp initializer was not found: $initializer"}
    $hostPath=(Get-Process -Id $PID).Path
    $configPath=[IO.Path]::GetFullPath($RuntimeConfig.Text)
    $script:koboldSetupStdoutPath=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-kobold-setup-'+[Guid]::NewGuid().ToString('N')+'.out')
    $script:koboldSetupStderrPath=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-kobold-setup-'+[Guid]::NewGuid().ToString('N')+'.err')
    $arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $initializer.Replace('"','\"'),$configPath.Replace('"','\"')
    $setupRequest=New-AtaraxiaGuiChildProcessRequest $hostPath $arguments $projectRoot $script:koboldSetupStdoutPath $script:koboldSetupStderrPath
    $script:koboldSetupProcess=Start-AtaraxiaGuiChildProcess $setupRequest
    $KoboldToggle.IsEnabled=$false;$KoboldRestart.IsEnabled=$false
    Set-KoboldConnectionIndicator 'starting';Set-AtaraxiaGuiStatusText (Get-AppText 'gui_kobold_downloading')
}
function Complete-KoboldCppAcquisitionIfFinished {
    if($null -eq $script:koboldSetupProcess){return}
    $setupStatus=Get-AtaraxiaGuiChildProcessStatus $script:koboldSetupProcess;if(-not $setupStatus.has_exited){return}
    $exitCode=$setupStatus.exit_code;$details=''
    if(Test-Path -LiteralPath $script:koboldSetupStderrPath){$details=(Get-Content -LiteralPath $script:koboldSetupStderrPath -Raw -ErrorAction SilentlyContinue).Trim()}
    if($exitCode -eq 0){Set-AtaraxiaGuiStatusText (Get-AppText 'gui_kobold_downloaded')}else{$message=Get-AppText 'gui_kobold_download_failed';if(-not [string]::IsNullOrWhiteSpace($details)){$message+=': '+$details};Set-AtaraxiaGuiStatusText $message}
    Close-AtaraxiaGuiChildProcess $script:koboldSetupProcess;$script:koboldSetupProcess=$null
    foreach($path in @($script:koboldSetupStdoutPath,$script:koboldSetupStderrPath)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}}
    $script:koboldSetupStdoutPath='';$script:koboldSetupStderrPath='';$KoboldToggle.IsEnabled=$true;$KoboldRestart.IsEnabled=$true
    Update-KoboldConnectionIndicator
}
function Show-AtaraxiaStartupSplash {
    [xml]$splashXaml=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'presentation/AtaraxiaSplash.xaml'))
    $splash=[Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($splashXaml))
    $coverPath=Join-Path $projectRoot 'assets/splash/ataraxia-project-cover.png'
    if(-not (Test-Path -LiteralPath $coverPath -PathType Leaf)){throw "Splash cover image is missing: $coverPath"}
    $coverImage=[Windows.Media.Imaging.BitmapImage]::new([Uri]::new([IO.Path]::GetFullPath($coverPath)))
    $splash.FindName('SplashImage').Source=$coverImage
    $splash.Show();$script:splashShownAt=[Diagnostics.Stopwatch]::StartNew();return $splash
}
try { $languagePath=if(Test-AtaraxiaStoreFile $RuntimeConfig.Text $script:guiJsonFileStore){$RuntimeConfig.Text}else{Join-Path $projectRoot 'configs/config.example.json'}; $languageConfig=Read-AtaraxiaGuiJsonFile $languagePath; Set-AtaraxiaLanguage ([string]$languageConfig.interface_language) } catch { Set-AtaraxiaLanguage 'English' }; Load-AtaraxiaThemePreference
$script:splashWindow=$null
if($guiStartupPlan.show_splash){$script:splashWindow=Show-AtaraxiaStartupSplash}
Update-KoboldConnectionIndicator

Register-AtaraxiaGuiViewAction $script:guiViewPort 'theme_selector' 'selection_change' {if(-not $script:updatingTheme -and $null -ne $ThemeSelector.SelectedValue){try{Save-AtaraxiaThemePreference ([string]$ThemeSelector.SelectedValue)}catch{Report-AtaraxiaGuiError $_ 'save_theme'}}}

$script:modelParameterEditorState=New-AtaraxiaModelParameterEditorState
$script:modelParameterControls=@{};

function Initialize-AtaraxiaModelParameterEditor {try{Build-AtaraxiaModelParameterControls}catch{Report-AtaraxiaGuiError $_ 'initialize_model_editor'}}
function Get-AtaraxiaConfig { Read-AtaraxiaGuiJsonFile $RuntimeConfig.Text }
function Get-AtaraxiaSelectedModelPath {
    $config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text $script:guiJsonStore;$settings=$config.koboldcpp_base_settings;$modelFile=[string]$settings.paths.model_file
    if([string]::IsNullOrWhiteSpace($modelFile)){return ''}
    if([IO.Path]::IsPathRooted($modelFile)){return [IO.Path]::GetFullPath($modelFile)}
    $modelDirectory=[string]$settings.paths.model_directory
    if(-not [IO.Path]::IsPathRooted($modelDirectory)){$modelDirectory=Join-Path (Split-Path -Parent $PSScriptRoot) $modelDirectory}
    return [IO.Path]::GetFullPath((Join-Path $modelDirectory $modelFile))
}
function Get-AtaraxiaAvailableModels {
    $config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text $script:guiJsonStore;$directory=[string]$config.koboldcpp_base_settings.paths.model_directory
    if(-not [IO.Path]::IsPathRooted($directory)){$directory=Join-Path (Split-Path -Parent $PSScriptRoot) $directory}
    $dependencies=New-AtaraxiaModelFileSystemDependencies
    return @(Get-AtaraxiaModelFiles $directory $dependencies)
}
function Refresh-AtaraxiaModelSelector {
    $selectedPath=Get-AtaraxiaSelectedModelPath;$models=@(Get-AtaraxiaAvailableModels);Set-AtaraxiaGuiViewItems $script:guiViewPort 'models' $models;$ModelFileSelector.SelectedValuePath='path'
    $selected=@($models|Where-Object{$_.path -ieq $selectedPath}|Select-Object -First 1)
    if($selected.Count -gt 0){$ModelFileSelector.SelectedItem=$selected[0]}elseif(-not [string]::IsNullOrWhiteSpace($selectedPath)){$ModelFileSelector.Items.Add([pscustomobject]@{name=[IO.Path]::GetFileName($selectedPath);path=$selectedPath})|Out-Null;$ModelFileSelector.SelectedIndex=$ModelFileSelector.Items.Count-1}
}
function Sync-AtaraxiaModelParameterPresetSelector([object]$Settings) {
    $language=[string](Get-AtaraxiaConfig).interface_language
    $items=@(foreach($preset in $Settings.parameter_presets){$name=[string]$preset.name;if([string]$preset.origin -eq 'builtin' -and $language -eq 'English' -and $null -ne $preset.PSObject.Properties['name_en']){$name=[string]$preset.name_en};$suffixKey=if([string]$preset.origin -eq 'user'){'gui_parameter_preset_user_suffix'}elseif([bool]$preset.has_user_override){'gui_parameter_preset_customized_suffix'}else{'gui_parameter_preset_builtin_suffix'};[pscustomobject]@{id=[string]$preset.id;name=($name+' '+(Get-AppText $suffixKey))}})
    $active=Get-AtaraxiaModelParameterPreset $Settings ([string]$Settings.active_parameter_preset_id);$deleteLabel=if([string]$active.origin -eq 'builtin'){Get-AppText 'gui_parameter_preset_reset'}else{Get-AppText 'gui_parameter_preset_delete'};Set-AtaraxiaGuiViewValue $script:guiViewPort 'delete_parameter_preset' $deleteLabel
    $wasLoading=[bool]$script:modelParameterEditorState.loading;$null=Set-AtaraxiaModelParameterEditorLoading $script:modelParameterEditorState $true
    try{Set-AtaraxiaGuiViewItems $script:guiViewPort 'parameter_presets' $items;$ParameterPresetSelector.SelectedValuePath='id';$ParameterPresetSelector.SelectedValue=[string]$Settings.active_parameter_preset_id;$null=Set-AtaraxiaModelParameterEditorPreset $script:modelParameterEditorState ([string]$Settings.active_parameter_preset_id)}finally{$null=Set-AtaraxiaModelParameterEditorLoading $script:modelParameterEditorState $wasLoading}
}
function Save-AtaraxiaModelParameterPresetSettings([object]$Settings) {
    $config=Get-AtaraxiaConfig;$settingsPath=Get-KoboldCppSettingsPath $config $RuntimeConfig.Text;$presetPath=Get-AtaraxiaUserModelParameterPresetPath;$store=$script:guiJsonStore
    $saveUserPresets={param($Value)Save-AtaraxiaUserModelParameterPresetData $presetPath $Value $store|Out-Null}.GetNewClosure();$saveSharedSettings={param($Value)Save-KoboldCppSettings $settingsPath $Value $store|Out-Null}.GetNewClosure()
    Save-AtaraxiaGuiModelParameterSettings $Settings $saveUserPresets $saveSharedSettings|Out-Null
    $config|Add-Member -NotePropertyName koboldcpp_base_settings -NotePropertyValue $Settings -Force;$config|Add-Member -NotePropertyName override -NotePropertyValue $Settings.request_parameters -Force
}
function Save-AtaraxiaSelectedModel {
    $selected=$ModelFileSelector.SelectedItem;if($null -eq $selected){return}
    if($script:modelParameterEditorState.dirty){Save-AtaraxiaModelParameters}
    $settingsPath=Get-KoboldCppSettingsPath (Get-AtaraxiaConfig) $RuntimeConfig.Text;$config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text $script:guiJsonStore;$settings=$config.koboldcpp_base_settings
    $modelDirectory=[string]$settings.paths.model_directory;if(-not [IO.Path]::IsPathRooted($modelDirectory)){$modelDirectory=Join-Path (Split-Path -Parent $PSScriptRoot) $modelDirectory};$modelDirectory=[IO.Path]::GetFullPath($modelDirectory)
    $modelPath=[IO.Path]::GetFullPath([string]$selected.path)
    $settings.paths.model_file=Get-AtaraxiaModelRelativePath $modelDirectory $modelPath
    $presetPath=Get-AtaraxiaUserModelParameterPresetPath;$store=$script:guiJsonStore;$saveUserPresets={param($Value)Save-AtaraxiaUserModelParameterPresetData $presetPath $Value $store|Out-Null}.GetNewClosure();$saveSharedSettings={param($Value)Save-KoboldCppSettings $settingsPath $Value $store|Out-Null}.GetNewClosure()
    Save-AtaraxiaGuiModelParameterSettings $settings $saveUserPresets $saveSharedSettings|Out-Null
    $null=Set-AtaraxiaModelParameterEditorDirty $script:modelParameterEditorState $false
    Build-AtaraxiaModelParameterControls
}
Register-AtaraxiaGuiViewAction $script:guiViewPort 'model_selector' 'selection_change' {if((Test-AtaraxiaModelParameterEditorChangeAllowed $script:modelParameterEditorState) -and $null -ne $ModelFileSelector.SelectedItem){try{Save-AtaraxiaSelectedModel}catch{Report-AtaraxiaGuiError $_ 'select_model'}}}
Register-AtaraxiaGuiViewAction $script:guiViewPort 'refresh_models' 'activate' {try{$null=Set-AtaraxiaModelParameterEditorLoading $script:modelParameterEditorState $true;Refresh-AtaraxiaModelSelector}finally{$null=Set-AtaraxiaModelParameterEditorLoading $script:modelParameterEditorState $false}}
$null=Set-AtaraxiaModelParameterEditorLoading $script:modelParameterEditorState $true;try{Refresh-AtaraxiaModelSelector}catch{Report-AtaraxiaGuiError $_ 'refresh_models'}finally{$null=Set-AtaraxiaModelParameterEditorLoading $script:modelParameterEditorState $false}
function Save-AtaraxiaModelParameters {
    $settingsPath=Get-KoboldCppSettingsPath (Get-AtaraxiaConfig) $RuntimeConfig.Text
    $config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text $script:guiJsonStore;$settings=$config.koboldcpp_base_settings
    $values=[ordered]@{}
    foreach($definition in Get-AtaraxiaModelParameterDefinitions){$control=$script:modelParameterControls[$definition.key];if($definition.kind -eq 'string'){$raw=[string]$control.Text;if($definition.key -eq 'stop'){if([string]::IsNullOrWhiteSpace($raw)){$values[$definition.key]=@()}else{$values[$definition.key]=@($raw -split "`r?`n"|Where-Object{$_ -ne ''})}}else{$values[$definition.key]=$raw}}else{$inputResult=Get-AtaraxiaModelParameterInputResult $definition.key $control.Text;if(-not $inputResult.valid){throw $inputResult.error};$values[$definition.key]=$inputResult.value}}
    $presetId=[string]$script:modelParameterEditorState.active_preset_id;if([string]::IsNullOrWhiteSpace($presetId)){$presetId=[string]$settings.active_parameter_preset_id}
    Save-AtaraxiaModelParameterPresetValues $settings $presetId $values|Out-Null
    $presetPath=Get-AtaraxiaUserModelParameterPresetPath;$store=$script:guiJsonStore;$saveUserPresets={param($Value)Save-AtaraxiaUserModelParameterPresetData $presetPath $Value $store|Out-Null}.GetNewClosure();$saveSharedSettings={param($Value)Save-KoboldCppSettings $settingsPath $Value $store|Out-Null}.GetNewClosure()
    Save-AtaraxiaGuiModelParameterSettings $settings $saveUserPresets $saveSharedSettings|Out-Null
    $config|Add-Member -NotePropertyName koboldcpp_base_settings -NotePropertyValue $settings -Force
    $config|Add-Member -NotePropertyName override -NotePropertyValue $settings.request_parameters -Force
    $script:modelParameterValues=$values
    Sync-AtaraxiaModelParameterPresetSelector $settings
    $null=Set-AtaraxiaModelParameterEditorDirty $script:modelParameterEditorState $false
}
function Build-AtaraxiaModelParameterControls {
    $config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text $script:guiJsonStore;$settings=$config.koboldcpp_base_settings;$values=Get-AtaraxiaModelParameterValues $settings;Sync-AtaraxiaModelParameterPresetSelector $settings
    $getText={param($Key)Get-AppText $Key}.GetNewClosure()
    $onSaveAction={try{Save-AtaraxiaModelParameters}catch{Report-AtaraxiaGuiError $_ 'save_model_parameters'}}.GetNewClosure()
    $editorHandlers=New-AtaraxiaModelParameterEditorHandlers $script:modelParameterEditorState $onSaveAction
    $onDirty=$editorHandlers.on_dirty;$onSave=$editorHandlers.on_save
    $getInputResult=${function:Get-AtaraxiaModelParameterInputResult};$getStepValue=${function:Get-AtaraxiaModelParameterStepValue}
    $script:modelParameterControls=New-AtaraxiaWpfModelParameterControls -Panel $ParameterPanel -Definitions @(Get-AtaraxiaModelParameterDefinitions) -Values $values -Port $script:guiViewPort -Owner $window -GetText $getText -OnDirty $onDirty -OnSave $onSave -GetInputResult $getInputResult -GetStepValue $getStepValue
}
function Save-AtaraxiaModelParameterPresetAs {
    if($script:modelParameterEditorState.dirty){Save-AtaraxiaModelParameters}
    $name=Show-AtaraxiaInputDialog (Get-AppText 'gui_parameter_preset_name_title') '' (Get-AppText 'gui_parameter_preset_name_message');if($null -eq $name){return};$name=([string]$name).Trim();if([string]::IsNullOrWhiteSpace($name)){return}
    $config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text $script:guiJsonStore;$settings=$config.koboldcpp_base_settings
    $preset=New-AtaraxiaModelParameterPreset $settings $name ([guid]::NewGuid().ToString('N'));Save-AtaraxiaModelParameterPresetSettings $settings;$null=Set-AtaraxiaModelParameterEditorPreset $script:modelParameterEditorState ([string]$preset.id);Build-AtaraxiaModelParameterControls
}
function Rename-AtaraxiaCurrentModelParameterPreset {
    if($script:modelParameterEditorState.dirty){Save-AtaraxiaModelParameters}
    $config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text $script:guiJsonStore;$settings=$config.koboldcpp_base_settings;$id=[string]$settings.active_parameter_preset_id;$current=Get-AtaraxiaModelParameterPreset $settings $id
    $name=Show-AtaraxiaInputDialog (Get-AppText 'gui_parameter_preset_name_title') ([string]$current.name) (Get-AppText 'gui_parameter_preset_name_message');if($null -eq $name){return}
    Rename-AtaraxiaModelParameterPreset $settings $id ([string]$name)|Out-Null;Save-AtaraxiaModelParameterPresetSettings $settings;Build-AtaraxiaModelParameterControls
}
function Remove-AtaraxiaCurrentModelParameterPreset {
    if($script:modelParameterEditorState.dirty){Save-AtaraxiaModelParameters}
    $config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text $script:guiJsonStore;$settings=$config.koboldcpp_base_settings;$id=[string]$settings.active_parameter_preset_id;$preset=Get-AtaraxiaModelParameterPreset $settings $id
    if([string]$preset.origin -ne 'builtin' -and @($settings.parameter_presets|Where-Object{[string]$_.origin -eq 'user'}).Count -le 1 -and @($settings.parameter_presets|Where-Object{[string]$_.origin -eq 'builtin'}).Count -eq 0){$null=Show-AtaraxiaMessageDialog (Get-AppText 'gui_parameter_preset_last_error') (Get-AppText 'gui_parameter_preset_delete_title') 'warning';return}
    $confirmTitle=if([string]$preset.origin -eq 'builtin'){Get-AppText 'gui_parameter_preset_reset_title'}else{Get-AppText 'gui_parameter_preset_delete_title'};$confirmKey=if([string]$preset.origin -eq 'builtin'){'gui_parameter_preset_reset_confirm'}else{'gui_parameter_preset_delete_confirm'};$confirm=Show-AtaraxiaMessageDialog (Get-AppText $confirmKey @([string]$preset.name)) $confirmTitle 'question' $true (Get-AppText 'gui_yes') (Get-AppText 'gui_no');if(-not $confirm){return}
    Remove-AtaraxiaModelParameterPreset $settings $id|Out-Null;Save-AtaraxiaModelParameterPresetSettings $settings;$null=Set-AtaraxiaModelParameterEditorPreset $script:modelParameterEditorState ([string]$settings.active_parameter_preset_id);Build-AtaraxiaModelParameterControls
}
Register-AtaraxiaGuiViewAction $script:guiViewPort 'parameter_presets' 'selection_change' {if(-not(Test-AtaraxiaModelParameterEditorChangeAllowed $script:modelParameterEditorState) -or [string]::IsNullOrWhiteSpace([string]$ParameterPresetSelector.SelectedValue) -or [string]$ParameterPresetSelector.SelectedValue -ceq [string]$script:modelParameterEditorState.active_preset_id){return};try{if($script:modelParameterEditorState.dirty){Save-AtaraxiaModelParameters};$config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text $script:guiJsonStore;$settings=$config.koboldcpp_base_settings;Select-AtaraxiaModelParameterPreset $settings ([string]$ParameterPresetSelector.SelectedValue)|Out-Null;Save-AtaraxiaModelParameterPresetSettings $settings;$null=Set-AtaraxiaModelParameterEditorPreset $script:modelParameterEditorState ([string]$settings.active_parameter_preset_id);Build-AtaraxiaModelParameterControls}catch{Report-AtaraxiaGuiError $_ 'select_parameter_preset';try{$config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text $script:guiJsonStore;Sync-AtaraxiaModelParameterPresetSelector $config.koboldcpp_base_settings}catch{}}}
Register-AtaraxiaGuiViewAction $script:guiViewPort 'save_parameter_preset' 'activate' {try{Save-AtaraxiaModelParameters;Set-AtaraxiaGuiStatusText (Get-AppText 'gui_parameter_preset_saved')}catch{Report-AtaraxiaGuiError $_ 'save_parameter_preset'}}
Register-AtaraxiaGuiViewAction $script:guiViewPort 'save_as_parameter_preset' 'activate' {try{Save-AtaraxiaModelParameterPresetAs}catch{Report-AtaraxiaGuiError $_ 'create_parameter_preset'}}
Register-AtaraxiaGuiViewAction $script:guiViewPort 'rename_parameter_preset' 'activate' {try{Rename-AtaraxiaCurrentModelParameterPreset}catch{Report-AtaraxiaGuiError $_ 'rename_parameter_preset'}}
Register-AtaraxiaGuiViewAction $script:guiViewPort 'delete_parameter_preset' 'activate' {try{Remove-AtaraxiaCurrentModelParameterPreset}catch{Report-AtaraxiaGuiError $_ 'delete_parameter_preset'}}
function Get-ProjectsRoot { Join-Path $projectRoot 'projects' }
function Get-TaskDirectory { $settings=Get-AtaraxiaConfig; Join-Path (Get-ProjectsRoot) ([string]$settings.project_name) }
function Get-ActiveProjectPath { Join-Path (Get-ProjectsRoot) ([string](Get-AtaraxiaConfig).project_name) }
function Reset-LoadedTask {
    $script:guiScreenState=Reset-AtaraxiaGuiScreenTask $script:guiScreenState;$TaskName.Text='';$Workspace.Text='';$Goal.Text='';$Conversation.ItemsSource=@()
    Invoke-AtaraxiaGuiViewOperation $script:guiViewPort scroll_to_top 'conversation_scroll';Update-AtaraxiaScrollToLatestButton
}
function Assert-ProjectManagerIdle {
    if($script:guiProcessState.phase -eq 'running' -or $null -ne $script:process){throw (Get-AppText 'gui_project_busy')}
}
function Show-ProjectNameDialog([string]$Title,[string]$InitialValue='') {
    $value=Show-AtaraxiaProjectNameDialog $Title $InitialValue
    if($null -eq $value){return ''};return ([string]$value).Trim()
}
function Show-CommonPromptDialog([string]$Title,[string]$InitialValue) { return Show-AtaraxiaCommonPromptDialog $Title $InitialValue }
function Load-AtaraxiaTask([string]$Path) {
    if(-not(Test-AtaraxiaStoreFile $Path $script:guiJsonFileStore)){throw "Task file was not found: $Path"}
    $task=Read-AtaraxiaGuiJsonFile $Path
    if($null -eq $task.PSObject.Properties['workflow'] -or $null -eq $task.PSObject.Properties['roles']){throw 'The selected file is not an Ataraxia task.'}
    $null=Set-AtaraxiaGuiScreenTask $script:guiScreenState $Path
    $TaskName.Text=[string]$task.name;$Workspace.Text=[string]$task.working_directory;$Goal.Text=[string]$task.goal
    $SessionSelector.SelectedItem=$null
    $sessionPath=Split-Path -Parent $script:guiScreenState.task_path;$sessionMeta=Join-Path $sessionPath 'session.json'
    if(Test-AtaraxiaStoreFile $sessionMeta $script:guiJsonFileStore){$metadata=Read-AtaraxiaGuiJsonFile $sessionMeta;$match=@($SessionSelector.Items|Where-Object{$_.id -ceq [string]$metadata.id}|Select-Object -First 1);if($match.Count -gt 0){$transition=Set-AtaraxiaGuiSessionSelectionSynchronization $script:sessionSelectionState $true;$script:sessionSelectionState=$transition.state;try{$SessionSelector.SelectedItem=$match[0]}finally{$transition=Set-AtaraxiaGuiSessionSelectionSynchronization $script:sessionSelectionState $false;$script:sessionSelectionState=$transition.state}}}
    Refresh-AtaraxiaConversation
    $RunTask.IsEnabled=$true;$EditLast.IsEnabled=$true;$hasSessionMeta=Test-AtaraxiaStoreFile $sessionMeta $script:guiJsonFileStore;Set-AtaraxiaGuiViewValue $script:guiViewPort 'rename_session_menu' $hasSessionMeta;$SessionPromptButton.IsEnabled=$hasSessionMeta
    Set-AtaraxiaGuiStatusText (Get-AppText 'gui_ready')
}

function Save-AtaraxiaTask {
    if([string]::IsNullOrWhiteSpace($script:guiScreenState.task_path)){throw 'No session task is loaded.'}
    $task=Read-AtaraxiaGuiJsonFile $script:guiScreenState.task_path
    $task.goal=[string]$Goal.Text;$task.working_directory=[string]$Workspace.Text
    Write-AtaraxiaJsonStoreFile $script:guiScreenState.task_path $task $script:guiJsonStore 100
}

function Refresh-AtaraxiaConversation {
    if([string]::IsNullOrWhiteSpace($script:guiScreenState.task_path)){$Conversation.ItemsSource=@();Update-AtaraxiaScrollToLatestButton;return}
    $taskDirectory=Split-Path -Parent $script:guiScreenState.task_path;$conversationPath=Join-Path $taskDirectory 'conversation.json';$statePath=Join-Path $taskDirectory 'state.json'
    $conversation=Get-AtaraxiaConversation $conversationPath
    $state=if(Test-AtaraxiaStoreFile $statePath $script:guiJsonFileStore){Read-AtaraxiaGuiJsonFile $statePath 2097152}else{[pscustomobject]@{history=@()}}
    if($null -eq $state.PSObject.Properties['history']){$state|Add-Member -NotePropertyName history -NotePropertyValue @() -Force}
    $view=ConvertTo-AtaraxiaConversationView $conversation $state (Get-AtaraxiaRoleIconGeometry (Join-Path $projectRoot 'assets/role-icons'))
    Wire-AtaraxiaRequestCopyMenus
    Set-AtaraxiaGuiViewItems $script:guiViewPort 'conversation' $view
    Schedule-AtaraxiaGuiViewCallback $script:guiViewPort 'normal' { Register-AtaraxiaWpfSmoothExpanders $Conversation $script:guiViewPort $script:wpfSmoothExpanderRegistry; Invoke-AtaraxiaGuiViewOperation $script:guiViewPort scroll_to_end 'conversation_scroll';Update-AtaraxiaScrollToLatestButton }
}

function Update-AtaraxiaScrollToLatestButton {
    if($null -eq $ConversationScrollViewer -or $null -eq $ScrollToLatest){return}
    Invoke-AtaraxiaGuiViewOperation $script:guiViewPort sync_scroll_to_latest_visibility 'scroll_latest' 'conversation_scroll'
}

function Wire-AtaraxiaRequestCopyMenus {
    Schedule-AtaraxiaGuiViewCallback $script:guiViewPort 'normal' { Register-AtaraxiaWpfConversationCopyMenus $Conversation $script:guiViewPort $script:guiLocalizedPresentation.menu_labels.copy_request }
}

function Refresh-ProjectSessionTree {
    if($null -eq $ProjectTreePanel){return}
    $config=Get-AtaraxiaConfig;$active=[string]$config.project_name;$maximum=5
    $guiProperty=$config.PSObject.Properties['gui']
    if($null -ne $guiProperty -and $null -ne $guiProperty.Value.PSObject.Properties['recent_sessions_max']){$maximum=[int]$guiProperty.Value.recent_sessions_max}
    if($maximum -lt 0){$maximum=0}
    $viewModel=Get-AtaraxiaGuiProjectSessionOverview (New-AtaraxiaGuiProjectSessionAdapters) (Get-ProjectsRoot) $active $maximum
    $getText={param($Key)Get-AppText $Key}.GetNewClosure()
    $setIcon={param($Path,$IconName)if(-not [string]::IsNullOrWhiteSpace([string]$IconName)){Set-AtaraxiaWpfPathIcon $Path $projectRoot $IconName};Set-AtaraxiaWpfPathForeground $Path}.GetNewClosure()
    $onAction={
        param($Action,$Value)
        try {
            switch([string]$Action){
                'select_project'{Select-AtaraxiaDrawerProject ([string]$Value)}
                'new_session'{Begin-AtaraxiaNewSessionScreen ([string]$Value)}
                'rename_project'{Rename-AtaraxiaProjectFromGui ([string]$Value)}
                'select_session'{Select-AtaraxiaDrawerSession ([string]$Value.project_name) $Value.session}
                default{throw "Unknown project drawer action: $Action"}
            }
        } catch {Report-AtaraxiaGuiError $_ 'project_drawer_action'}
    }.GetNewClosure()
    Set-AtaraxiaWpfProjectDrawer -Owner $window -ViewModel $viewModel -ExpandedState $script:guiScreenState.project_tree_expanded -RecentSessionsExpanded $script:guiScreenState.recent_sessions_expanded -ActiveProjectName $active -Port $script:guiViewPort -GetText $getText -SetIcon $setIcon -OnAction $onAction -SmoothExpanderRegistry $script:wpfSmoothExpanderRegistry -ProjectTreePanel $ProjectTreePanel -RecentSessionsPanel $RecentSessionsPanel -RecentSessionsExpander $RecentSessionsExpander -ProjectGroupTitle $ProjectGroupTitle -RecentSessionsTitle $RecentSessionsTitle
}
function New-AtaraxiaGuiSession([string]$ProjectName) {
    $config=Get-AtaraxiaConfig;$contracts=Import-RoleContracts $config $RuntimeConfig.Text;$dependencies=New-AtaraxiaGuiProjectSessionAdapters
    return New-AtaraxiaGuiSessionForProject $dependencies (Get-ProjectsRoot) $ProjectName ([string]$config.project_name) $contracts 'New session'
}

function Materialize-AtaraxiaPendingSession([string]$FirstPrompt) {
    if([string]::IsNullOrWhiteSpace($script:guiScreenState.pending_session_project)){return $null}
    $created=New-AtaraxiaGuiSession $script:guiScreenState.pending_session_project;$script:guiScreenState.pending_session_project=''
    $session=$created.session;Load-AtaraxiaTask $created.task_path
    return $session
}

function Refresh-AtaraxiaSessionSelector {
    $projectName=[string](Get-AtaraxiaConfig).project_name;$projectPath=Get-AtaraxiaProjectPath (Get-ProjectsRoot) $projectName
    $sessions=Get-AtaraxiaGuiSessions (New-AtaraxiaGuiProjectSessionAdapters) $projectPath;$transition=Set-AtaraxiaGuiSessionSelectionSynchronization $script:sessionSelectionState $true;$script:sessionSelectionState=$transition.state
    try{Set-AtaraxiaGuiViewItems $script:guiViewPort 'sessions' $sessions;if(-not [string]::IsNullOrWhiteSpace($script:guiScreenState.task_path)){$taskDirectory=Split-Path -Parent $script:guiScreenState.task_path;$match=@($sessions|Where-Object{$_.path -ieq $taskDirectory}|Select-Object -First 1);if($match.Count -gt 0){$SessionSelector.SelectedItem=$match[0]}else{$SessionSelector.SelectedItem=$null}}else{$SessionSelector.SelectedItem=$null}}finally{$transition=Set-AtaraxiaGuiSessionSelectionSynchronization $script:sessionSelectionState $false;$script:sessionSelectionState=$transition.state}
}

function Select-AtaraxiaDrawerProject([string]$ProjectName) {
    Assert-ProjectManagerIdle;$null=Prepare-AtaraxiaGuiProject (New-AtaraxiaGuiProjectSessionAdapters) (Get-ProjectsRoot) $ProjectName ([string](Get-AtaraxiaConfig).project_name)
    Reset-LoadedTask;$TaskName.Text=$ProjectName;Set-AtaraxiaGuiStatusText (Get-AppText 'gui_ready');Refresh-AtaraxiaSessionSelector;Refresh-ProjectSessionTree
}

function Select-AtaraxiaDrawerSession([string]$ProjectName,[object]$Session) {
    Assert-ProjectManagerIdle;$projectPath=Get-AtaraxiaProjectPath (Get-ProjectsRoot) $ProjectName
    $configPath=[IO.Path]::GetFullPath($RuntimeConfig.Text);$projectsRoot=Get-ProjectsRoot
    $readMetadata={param($Path)Read-AtaraxiaGuiJsonFile $Path}.GetNewClosure()
    $activateProject={param($Name)$null=Set-AtaraxiaActiveProject $configPath $projectsRoot $Name $script:guiSessionStore}.GetNewClosure()
    $selection=Open-AtaraxiaGuiProjectSession $projectPath ([string]$Session.path) ([string](Get-AtaraxiaConfig).project_name) $readMetadata $activateProject
    Load-AtaraxiaTask $selection.task_path;Refresh-AtaraxiaSessionSelector;Refresh-ProjectSessionTree
}

function Begin-AtaraxiaNewSessionScreen([string]$ProjectName) {
    Assert-ProjectManagerIdle;$config=Get-AtaraxiaConfig;$null=Prepare-AtaraxiaGuiProject (New-AtaraxiaGuiProjectSessionAdapters) (Get-ProjectsRoot) $ProjectName ([string]$config.project_name)
    Reset-LoadedTask;$script:guiScreenState.pending_session_project=$ProjectName;$TaskName.Text=$ProjectName;Invoke-AtaraxiaGuiViewOperation $script:guiViewPort focus 'goal';$RunTask.IsEnabled=$true
    Refresh-AtaraxiaSessionSelector;Refresh-ProjectSessionTree;Set-AtaraxiaGuiStatusText (Get-AppText 'gui_new_session_for_project')
}

function New-AtaraxiaSessionFromCurrentProject { Begin-AtaraxiaNewSessionScreen ([string](Get-AtaraxiaConfig).project_name) }

function Invoke-AtaraxiaGuiSessionRename {
    $session=$SessionSelector.SelectedItem;if($null -eq $session){return}
    $title=Show-ProjectNameDialog (Get-AppText 'gui_rename_session') ([string]$session.title);if([string]::IsNullOrWhiteSpace($title)){return}
    $null=Rename-AtaraxiaGuiSession (New-AtaraxiaGuiProjectSessionAdapters) ([string]$session.path) $title 'user';Refresh-AtaraxiaSessionSelector;Refresh-ProjectSessionTree
}

function Stop-AtaraxiaRun {
    if($script:guiProcessState.phase -ne 'running' -or $null -eq $script:process){return}
    try{$null=Stop-AtaraxiaGuiChildProcess $script:process 5000}catch{}
    $script:process=$null
    $script:guiProcessState=Stop-AtaraxiaGuiProcessState $script:guiProcessState
    $outputPaths=New-AtaraxiaGuiProcessOutputPaths;$hostPath=(Get-Process -Id $PID).Path;$runner=Join-Path $PSScriptRoot 'Invoke-Agent.ps1';$rollbackRequest=New-AtaraxiaGuiRollbackLaunchRequest $hostPath $runner $script:guiScreenState.task_path ([IO.Path]::GetFullPath($RuntimeConfig.Text)) $projectRoot $outputPaths.stdout ($outputPaths.stdout+'.err')
    if($rollbackRequest.required){
        try{$rollback=Invoke-AtaraxiaGuiChildProcess $rollbackRequest;if($rollback.exit_code -eq 0){Set-AtaraxiaGuiStatusText (Get-AppText 'gui_stop_restored')}else{$message=(Read-AtaraxiaGuiProcessOutput $rollbackRequest.stdout_path $rollbackRequest.stderr_path 0).error_text;if([string]::IsNullOrWhiteSpace($message)){$message='Rollback failed.'};Set-AtaraxiaGuiStatusText $message}}finally{Remove-AtaraxiaGuiProcessOutputFiles $rollbackRequest.stdout_path $rollbackRequest.stderr_path}
    }
    $Progress.IsIndeterminate=$false;Set-RunTaskIcon $false;$RunTask.IsEnabled=$true
    Remove-AtaraxiaGuiProcessOutputFiles $script:processStdout $script:processStderr
    if(-not [string]::IsNullOrWhiteSpace($script:guiScreenState.task_path)){Refresh-AtaraxiaConversation}
}

function Finish-AtaraxiaProcess {
    if($script:guiProcessState.phase -ne 'running' -or $null -eq $script:process){return};$processStatus=Get-AtaraxiaGuiChildProcessStatus $script:process;if(-not $processStatus.has_exited){return}
    $exitCode=$processStatus.exit_code;$completion=Complete-AtaraxiaGuiProcess $script:guiProcessState $exitCode $script:guiScreenState.task_path;$script:guiProcessState=$completion.state;Close-AtaraxiaGuiChildProcess $script:process;$script:process=$null;$Progress.IsIndeterminate=$false;Set-RunTaskIcon $false
    Remove-AtaraxiaGuiProcessOutputFiles $script:processStdout $script:processStderr
    $message=if($completion.presentation.kind -eq 'ready'){Get-AppText 'gui_ready'}else{$completion.presentation.text};Set-AtaraxiaGuiStatusText $message
    if($completion.refresh_session){try{Refresh-AtaraxiaSessionSelector;Refresh-ProjectSessionTree;Refresh-AtaraxiaConversation}catch{Report-AtaraxiaGuiError $_ 'refresh_session'}}
    $RunTask.IsEnabled=$true;$EditLast.IsEnabled=$true
}

function Start-AtaraxiaProcess {
    param([string]$Request,[switch]$ReplaceLatest)
    if($script:guiProcessState.phase -eq 'running' -or $null -ne $script:process){return};$cleanRequest=$Request.Trim();if([string]::IsNullOrWhiteSpace($cleanRequest) -or [string]::IsNullOrWhiteSpace($Goal.Text)){return}
    Assert-AgentPlainText $cleanRequest 'User query' -MaximumLength 100000 -AllowMultiline
    if(-not [string]::IsNullOrWhiteSpace($script:guiScreenState.pending_session_project)){$null=Materialize-AtaraxiaPendingSession $cleanRequest}
    if([string]::IsNullOrWhiteSpace($script:guiScreenState.task_path)){throw 'Select or create a session before sending a query.'}
    $conversationPath=Join-Path (Split-Path -Parent $script:guiScreenState.task_path) 'conversation.json';if($ReplaceLatest){$null=Add-AtaraxiaRequest $conversationPath $cleanRequest -ReplaceLatest}else{$null=Add-AtaraxiaRequest $conversationPath $cleanRequest}
    $task=Read-AtaraxiaGuiJsonFile $script:guiScreenState.task_path;$task.goal=$cleanRequest;Write-AtaraxiaJsonStoreFile $script:guiScreenState.task_path $task $script:guiJsonStore 100
    Touch-AtaraxiaSession (Split-Path -Parent $script:guiScreenState.task_path);$script:guiScreenState.editing=$false;$Goal.Clear();Refresh-AtaraxiaConversation;Refresh-AtaraxiaSessionSelector;Refresh-ProjectSessionTree
    $runner=Join-Path $PSScriptRoot 'Invoke-Agent.ps1';$hostPath=(Get-Process -Id $PID).Path;$outputPaths=New-AtaraxiaGuiProcessOutputPaths;$script:processStdout=$outputPaths.stdout;$script:processStderr=$outputPaths.stderr
    $launchRequest=New-AtaraxiaGuiAgentLaunchRequest $hostPath $runner $script:guiScreenState.task_path ([IO.Path]::GetFullPath($RuntimeConfig.Text)) $projectRoot $script:processStdout $script:processStderr
    $script:process=Start-AtaraxiaGuiChildProcess $launchRequest
    $script:guiProcessState=Start-AtaraxiaGuiProcessState $script:guiProcessState
    Set-AtaraxiaGuiStatusText (Get-AppText 'gui_running_workflow');$Progress.IsIndeterminate=$true;Set-RunTaskIcon $true;$RunTask.IsEnabled=$true;$EditLast.IsEnabled=$false
}

function Receive-AtaraxiaProcessOutput {
    if($script:guiProcessState.phase -ne 'running' -or $null -eq $script:process){return}
    $reader={param($Stdout,$Stderr,$StartIndex)Read-AtaraxiaGuiProcessOutput $Stdout $Stderr $StartIndex}.GetNewClosure();$poll=Invoke-AtaraxiaGuiProcessPoll $script:guiProcessState $script:processStdout $script:processStderr $reader;$script:guiProcessState=$poll.state
    if($poll.presentation.kind -eq 'role'){Set-AtaraxiaGuiStatusText (Get-AppText 'gui_running_role' @((Get-AtaraxiaRoleLabel $poll.presentation.role)))}elseif($poll.presentation.kind -eq 'error'){Set-AtaraxiaGuiStatusText $poll.presentation.text}
    Finish-AtaraxiaProcess
}

function Select-AtaraxiaSessionFromSelector {
    if($script:sessionSelectionState.is_synchronizing -or $null -eq $SessionSelector.SelectedItem){return}
    Select-AtaraxiaDrawerSession ([string](Get-AtaraxiaConfig).project_name) $SessionSelector.SelectedItem
}

function Set-AtaraxiaCommonPromptForCurrentScope([ValidateSet('project','session')][string]$Scope) {
    $initial='';$title=Get-AppText $(if($Scope -eq 'project'){'gui_project_prompt'}else{'gui_session_prompt'})
    if($Scope -eq 'project'){$path=Get-ActiveProjectPath;$metadata=Join-Path $path 'project.json';if(Test-AtaraxiaStoreFile $metadata $script:guiJsonFileStore){$value=(Read-AtaraxiaGuiJsonFile $metadata).PSObject.Properties['common_prompt'];if($null -ne $value){$initial=[string]$value.Value}}}
    else{if([string]::IsNullOrWhiteSpace($script:guiScreenState.task_path)){return};$path=Split-Path -Parent $script:guiScreenState.task_path;$metadata=Join-Path $path 'session.json';if(Test-AtaraxiaStoreFile $metadata $script:guiJsonFileStore){$value=(Read-AtaraxiaGuiJsonFile $metadata).PSObject.Properties['common_prompt'];if($null -ne $value){$initial=[string]$value.Value}}}
    $text=Show-CommonPromptDialog $title $initial;if($null -eq $text){return}
    Save-AtaraxiaCommonPrompt $Scope $path $text
}

function Save-AtaraxiaCommonPrompt([ValidateSet('project','session')][string]$Scope,[string]$Path,[string]$Text) {
    if($Scope -eq 'project'){Set-AtaraxiaProjectCommonPrompt $Path $Text $script:guiSessionStore}else{Set-AtaraxiaSessionCommonPrompt $Path $Text $script:guiSessionStore}
}

function New-AtaraxiaProjectFromGui {
    Assert-ProjectManagerIdle;$name=Show-ProjectNameDialog (Get-AppText 'gui_new_project') '';if([string]::IsNullOrWhiteSpace($name)){return}
    $null=Prepare-AtaraxiaGuiProject (New-AtaraxiaGuiProjectSessionAdapters) (Get-ProjectsRoot) $name ([string](Get-AtaraxiaConfig).project_name);Reset-LoadedTask;Refresh-AtaraxiaSessionSelector;Refresh-ProjectSessionTree
}
function Rename-AtaraxiaProjectFromGui([string]$ProjectName) {
    Assert-ProjectManagerIdle;$old=$ProjectName;if([string]::IsNullOrWhiteSpace($old)){return};$name=Show-ProjectNameDialog (Get-AppText 'gui_rename_project') $old;if([string]::IsNullOrWhiteSpace($name) -or $name -ceq $old){return}
    $config=Get-AtaraxiaConfig;$result=Rename-AtaraxiaGuiProject (New-AtaraxiaGuiProjectSessionAdapters) (Get-ProjectsRoot) $old $name ([string]$config.project_name);if($result.active_project_changed){Reset-LoadedTask;Refresh-AtaraxiaSessionSelector};Refresh-ProjectSessionTree
}

function Wire-AtaraxiaEvents {
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'recent_sessions_header' 'activate' {Invoke-AtaraxiaGuiViewOperation $script:guiViewPort toggle_expanded 'recent_sessions_group'}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'recent_sessions_group' 'expanded_change' {param($expanded)$script:guiScreenState.recent_sessions_expanded=[bool]$expanded}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'new_project' 'activate' {try{New-AtaraxiaProjectFromGui}catch{Report-AtaraxiaGuiError $_ 'new_project'}}
    $SettingsToggle.ToolTip=Get-AppText 'gui_task_settings';$CloseSettings.ToolTip=Get-AppText 'gui_close_settings';$SettingsTitle.Text=Get-AppText 'gui_task_settings'
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'settings_toggle' 'activate' {Invoke-AtaraxiaGuiNavigation 'open_settings';if(-not $script:modelParameterEditorState.initialized){$null=Set-AtaraxiaModelParameterEditorLoading $script:modelParameterEditorState $true;try{Refresh-AtaraxiaModelSelector}finally{$null=Set-AtaraxiaModelParameterEditorLoading $script:modelParameterEditorState $false};Initialize-AtaraxiaModelParameterEditor;$null=Set-AtaraxiaModelParameterEditorInitialized $script:modelParameterEditorState $true}}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'close_settings' 'activate' {Invoke-AtaraxiaGuiNavigation 'close_settings'}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'new_session' 'activate' {try{New-AtaraxiaSessionFromCurrentProject}catch{Report-AtaraxiaGuiError $_ 'new_session'}}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'rename_session_menu' 'activate' {try{Invoke-AtaraxiaGuiSessionRename}catch{Report-AtaraxiaGuiError $_ 'rename_session'}}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'session_selector' 'selection_change' {try{Select-AtaraxiaSessionFromSelector}catch{Report-AtaraxiaGuiError $_ 'select_session'}}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'project_prompt' 'activate' {try{Set-AtaraxiaCommonPromptForCurrentScope 'project'}catch{Report-AtaraxiaGuiError $_ 'edit_project_prompt'}}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'session_prompt_button' 'activate' {try{Set-AtaraxiaCommonPromptForCurrentScope 'session'}catch{Report-AtaraxiaGuiError $_ 'edit_session_prompt'}}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'other_session' 'activate' {Invoke-AtaraxiaGuiViewOperation $script:guiViewPort open_context_menu 'other_session'}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'session_prompt_menu' 'activate' {try{Set-AtaraxiaCommonPromptForCurrentScope 'session'}catch{Report-AtaraxiaGuiError $_ 'edit_session_prompt'}}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'copy_session_id_menu' 'activate' {$session=$SessionSelector.SelectedItem;if($null -ne $session){Set-AtaraxiaGuiClipboardText $script:guiViewPort ([string]$session.id)}}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'create_task' 'activate' {try{New-AtaraxiaSessionFromCurrentProject;Invoke-AtaraxiaGuiViewOperation $script:guiViewPort focus 'goal'}catch{Report-AtaraxiaGuiError $_ 'create_task'}}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'edit_last' 'activate' {$conversation=Get-AtaraxiaConversation (Join-Path (Split-Path -Parent $script:guiScreenState.task_path) 'conversation.json');$last=@($conversation.entries|Where-Object{$_.kind -eq 'user_query'}|Select-Object -Last 1);if($last.Count -gt 0){Invoke-AtaraxiaGuiViewOperation $script:guiViewPort set_text_focus_end 'goal' ([string]$last[0].body);$script:guiScreenState.editing=$true}}
    $runTaskAction={try{if($script:guiProcessState.phase -eq 'running'){Stop-AtaraxiaRun}else{$replace=$script:guiScreenState.editing;Start-AtaraxiaProcess ([string]$Goal.Text) -ReplaceLatest:$replace}}catch{Report-AtaraxiaGuiError $_ 'run_task'}}.GetNewClosure()
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'run_task' 'activate' $runTaskAction
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'goal' 'submit' {& $runTaskAction}.GetNewClosure()
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'scroll_latest' 'activate' {Invoke-AtaraxiaGuiViewOperation $script:guiViewPort scroll_to_end 'conversation_scroll'}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'conversation_scroll' 'scroll' {Update-AtaraxiaScrollToLatestButton}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'browse_config' 'activate' {$picked=Show-AtaraxiaPathPicker -Owner $window -Kind file -Title (Get-AppText 'gui_runtime_config') -InitialDirectory (Split-Path -Parent $RuntimeConfig.Text) -Patterns @('*.json');if($picked){$RuntimeConfig.Text=[IO.Path]::GetFullPath($picked);Load-AtaraxiaThemePreference;Refresh-AtaraxiaModelSelector;Refresh-ProjectSessionTree}}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'browse_task' 'activate' {$picked=Show-AtaraxiaPathPicker -Owner $window -Kind file -Title (Get-AppText 'gui_open_task') -InitialDirectory (Get-TaskDirectory) -Patterns @('*.task.json');if($picked){try{Load-AtaraxiaTask $picked}catch{Report-AtaraxiaGuiError $_ 'open_task'}}}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'browse_workspace' 'activate' {$picked=Show-AtaraxiaPathPicker -Owner $window -Kind folder -Title (Get-AppText 'gui_browse_folder') -InitialDirectory $Workspace.Text;if($picked){$Workspace.Text=$picked}}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'kobold_toggle' 'activate' {Toggle-KoboldCppFromGui};Register-AtaraxiaGuiViewAction $script:guiViewPort 'kobold_restart' 'activate' {Restart-KoboldCppFromGui}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'main_window' 'close' {if($script:modelParameterEditorState.dirty){try{Save-AtaraxiaModelParameters}catch{Report-AtaraxiaGuiError $_ 'save_settings_on_close'}};if($null -ne $script:process){Stop-AtaraxiaRun}}
    $pollState=[pscustomobject]@{last_poll=[DateTime]::MinValue};$guiInstanceForPolling=$script:guiInstance;$guiViewPortForPolling=$script:guiViewPort
    $pollTick={try{if(Test-AtaraxiaGuiActivationRequested $guiInstanceForPolling){Invoke-AtaraxiaGuiViewOperation $guiViewPortForPolling activate_window 'main_window'};Receive-AtaraxiaProcessOutput;Complete-KoboldCppAcquisitionIfFinished;$now=[DateTime]::UtcNow;if(Test-AtaraxiaGuiPollingIntervalElapsed $now $pollState.last_poll 2000){$pollState.last_poll=$now;Update-KoboldConnectionIndicator}}catch{Report-AtaraxiaGuiError $_ 'gui_timer_tick'}}.GetNewClosure()
    $script:uiTimer=Start-AtaraxiaGuiViewTimer $script:guiViewPort 250 $pollTick
}

$minimumSplashMilliseconds=1100
if($null -ne $script:splashWindow){$remaining=[Math]::Max(0,$minimumSplashMilliseconds-[int]$script:splashShownAt.ElapsedMilliseconds);Wait-AtaraxiaGuiViewDelay $script:guiViewPort $remaining;$script:splashWindow.Close();$script:splashWindow=$null}
try {
    Set-AtaraxiaLanguage ([string](Get-AtaraxiaConfig).interface_language)
    Load-AtaraxiaThemePreference
    Refresh-AtaraxiaSessionSelector
    Refresh-ProjectSessionTree
    Wire-AtaraxiaEvents
    if(-not [string]::IsNullOrWhiteSpace([string](Get-AtaraxiaConfig).project_name)){$activeProject=Get-AtaraxiaProjectPath (Get-ProjectsRoot) ([string](Get-AtaraxiaConfig).project_name);if(Test-AtaraxiaStorePath $activeProject 'Container' $script:guiJsonFileStore){$script:guiScreenState.pending_session_project=''}}
    try{Start-KoboldCppAcquisitionIfMissing}catch{Report-AtaraxiaGuiError $_ 'start_kobold_acquisition'}
    Register-AtaraxiaGuiViewAction $script:guiViewPort 'main_window' 'content_ready' { Register-AtaraxiaWpfSmoothExpanders $window $script:guiViewPort $script:wpfSmoothExpanderRegistry }.GetNewClosure()
    $null=$window.ShowDialog()
} catch {
    if($null -ne $script:splashWindow){$script:splashWindow.Close()}
    $startupError=$_;$startupLog=Write-AtaraxiaGuiErrorLog $startupError 'startup'
    if($startupLog.written){[Console]::Error.WriteLine('Ataraxia GUI error log: '+$startupLog.path)}else{[Console]::Error.WriteLine('Ataraxia GUI error log could not be written: '+$startupLog.error)}
    throw
} finally {
    if($null -ne $script:uiTimer){Stop-AtaraxiaGuiViewTimer $script:guiViewPort $script:uiTimer}
    if($null -ne $script:process){$null=Stop-AtaraxiaGuiChildProcess $script:process 3000}
    if($null -ne $script:koboldSetupProcess){$null=Stop-AtaraxiaGuiChildProcess $script:koboldSetupProcess 3000}
    if($null -ne $script:guiInstance){Exit-AtaraxiaGuiInstance $script:guiInstance}
}
