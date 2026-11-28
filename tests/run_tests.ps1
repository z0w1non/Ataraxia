[CmdletBinding()]
param([switch]$GuiIntegration)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$guiThemeDefinitions=Get-Content -LiteralPath (Join-Path $projectRoot 'configs/gui-themes.json') -Raw -Encoding UTF8|ConvertFrom-Json
$previousUserDataDirectory=$env:ATARAXIA_USER_DATA_DIRECTORY
$testUserDataDirectory=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-test-user-data-'+[guid]::NewGuid().ToString('N'))
$env:ATARAXIA_USER_DATA_DIRECTORY=$testUserDataDirectory
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

Test-Case 'Model discovery uses an injectable filesystem adapter and skips reparse points' {
    . (Join-Path $projectRoot 'scripts/adapters/ModelFileSystemAdapter.ps1')
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-model-files-'+[guid]::NewGuid().ToString('N'))
    $nested=Join-Path $root 'nested'
    New-Item -ItemType Directory -Path $nested -Force|Out-Null
    try {
        [IO.File]::WriteAllText((Join-Path $root 'z.GGUF'),'')
        [IO.File]::WriteAllText((Join-Path $root 'ignore.txt'),'')
        [IO.File]::WriteAllText((Join-Path $nested 'a.gguf'),'')
        $calls=[System.Collections.Generic.List[string]]::new()
        $list={param($Path)$calls.Add($Path);@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)}.GetNewClosure()
        $models=@(Get-AtaraxiaModelFiles $root (New-AtaraxiaModelFileSystemDependencies $list))
        Assert-True ($models.Count -eq 2 -and $models[0].name -eq ('nested'+[IO.Path]::DirectorySeparatorChar+'a.gguf') -and $models[1].name -eq 'z.GGUF') 'Model adapter did not return sorted, nested GGUF paths.'
        Assert-True ($calls.Count -eq 2) 'Model adapter did not enumerate each directory through its injected dependency.'
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
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
    Assert-True ($launcherSource -match 'CreateErrorLogPath\(' -and $launcherSource -match 'WriteErrorLog\(' -and $launcherSource -match 'StandardOutput' -and $launcherSource -match 'StandardError' -and $launcherSource -match 'LocalApplicationData' -and $launcherSource -notmatch 'ShowErrorDialog|MessageBox\.Show') 'GUI launcher does not persist startup failures without opening an error dialog.'
    $buildCommand=Get-Content -LiteralPath (Join-Path $projectRoot 'tools/Build-Ataraxia.ps1') -Raw -Encoding UTF8
    Assert-True ($buildCommand -match 'ataraxia-app-icon\.ico' -and $buildCommand -match '/win32icon:') 'Launcher build command does not embed the project lettermark icon.'
}

if ($GuiIntegration) {
Test-Case 'Optional GUI integration: repeated launch reuses the window for the same config' {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    $tempDirectory=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-launch-smoke-'+[Guid]::NewGuid().ToString('N'))
    $previousErrorLogPath=$env:ATARAXIA_ERROR_LOG_PATH
    New-Item -ItemType Directory -Path $tempDirectory -Force|Out-Null
    $launcher=$null;$secondLauncher=$null;$childIds=@();$secondChildIds=@()
    try {
        $config=Read-Json (Join-Path $projectRoot 'configs/config.example.json')
        $settings=Read-Json (Join-Path $projectRoot 'configs/koboldcpp-settings.json')
        $settings.paths.executable=(Get-Process -Id $PID).Path
        $settings.paths.model_directory=$tempDirectory
        $settings.paths.install_directory=$tempDirectory
        $settingsPath=Join-Path $tempDirectory 'koboldcpp-settings.json'
        $logRoot=Join-Path $tempDirectory 'diagnostic-logs';$null=New-Item -ItemType Directory -Path $logRoot -Force;$env:ATARAXIA_ERROR_LOG_PATH=Join-Path $logRoot 'gui-startup.log'
        $configPath=Join-Path $tempDirectory 'gui-smoke-config.json'
        $config.koboldcpp_settings_path=$settingsPath
        $config.role_contracts_path=Join-Path $projectRoot 'configs/role-contracts.json'
        $config.agent_harness_path=Join-Path $projectRoot 'configs/agent-harness.json'
        $config.project_name='GuiStartupSmoke'
        [IO.File]::WriteAllText($settingsPath,($settings|ConvertTo-Json -Depth 60),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($configPath,($config|ConvertTo-Json -Depth 60),[Text.UTF8Encoding]::new($false))
        $launcher=Start-Process -FilePath (Join-Path $projectRoot 'Ataraxia.exe') -ArgumentList @('-NoSplash','-ConfigPath',$configPath) -WorkingDirectory $projectRoot -PassThru
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
public static class AtaraxiaGuiWindowProbe {
    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)] private struct PROCESSENTRY32 {
        public uint dwSize; public uint cntUsage; public uint th32ProcessID; public IntPtr th32DefaultHeapID;
        public uint th32ModuleID; public uint cntThreads; public uint th32ParentProcessID;
        public int pcPriClassBase; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string szExeFile;
    }
    private delegate bool EnumWindowsProc(IntPtr handle, IntPtr state);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", CharSet=CharSet.Auto)] private static extern bool Process32First(IntPtr snapshot, ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll", CharSet=CharSet.Auto)] private static extern bool Process32Next(IntPtr snapshot, ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr handle);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr handle);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr handle, int command);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr handle, out RECT rect);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr handle, StringBuilder text, int maxLength);
    public static int[] GetChildProcessIds(int expectedParentId) {
        var result = new List<int>();
        IntPtr snapshot = CreateToolhelp32Snapshot(0x00000002, 0);
        if (snapshot == IntPtr.Zero || snapshot == new IntPtr(-1)) return result.ToArray();
        try {
            var entry = new PROCESSENTRY32(); entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
            if (Process32First(snapshot, ref entry)) do {
                if (entry.th32ParentProcessID == (uint)expectedParentId) result.Add((int)entry.th32ProcessID);
                entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
            } while (Process32Next(snapshot, ref entry));
        } finally { CloseHandle(snapshot); }
        return result.ToArray();
    }
    public static bool HasMainWindow(int expectedProcessId) {
        bool found = false;
        EnumWindows(delegate(IntPtr handle, IntPtr state) {
            uint processId; GetWindowThreadProcessId(handle, out processId);
            if (processId != (uint)expectedProcessId || !IsWindowVisible(handle)) return true;
            RECT rect; if (!GetWindowRect(handle, out rect)) return true;
            if (rect.Right - rect.Left >= 700 && rect.Bottom - rect.Top >= 500) { found = true; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static IntPtr GetMainWindowHandle(int expectedProcessId) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr handle, IntPtr state) {
            uint processId; GetWindowThreadProcessId(handle, out processId);
            if (processId != (uint)expectedProcessId || !IsWindowVisible(handle)) return true;
            RECT rect; if (!GetWindowRect(handle, out rect)) return true;
            if (rect.Right - rect.Left >= 700 && rect.Bottom - rect.Top >= 500) { found = handle; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static bool MinimizeWindow(IntPtr handle) { return ShowWindow(handle, 6); }
    public static bool IsWindowMinimized(IntPtr handle) { return IsIconic(handle); }
    public static string DescribeWindows(int expectedProcessId) {
        var result = new StringBuilder();
        EnumWindows(delegate(IntPtr handle, IntPtr state) {
            uint processId; GetWindowThreadProcessId(handle, out processId);
            if (processId != (uint)expectedProcessId) return true;
            RECT rect; if (!GetWindowRect(handle, out rect)) return true;
            var title = new StringBuilder(256); GetWindowText(handle, title, title.Capacity);
            result.AppendFormat("visible={0}, size={1}x{2}, title='{3}'; ", IsWindowVisible(handle), rect.Right-rect.Left, rect.Bottom-rect.Top, title);
            return true;
        }, IntPtr.Zero);
        return result.ToString();
    }
    public static string DescribeWindowText(int expectedProcessId) {
        var result = new StringBuilder();
        EnumWindows(delegate(IntPtr handle, IntPtr state) {
            uint processId; GetWindowThreadProcessId(handle, out processId);
            if (processId != (uint)expectedProcessId) return true;
            EnumChildWindows(handle, delegate(IntPtr child, IntPtr childState) {
                var text = new StringBuilder(1024); GetWindowText(child, text, text.Capacity);
                if (text.Length > 0) result.Append(text).Append(" | ");
                return true;
            }, IntPtr.Zero);
            return true;
        }, IntPtr.Zero);
        return result.ToString();
    }
    public static IntPtr[] GetVisibleWindows(int expectedProcessId) {
        var result = new List<IntPtr>();
        EnumWindows(delegate(IntPtr handle, IntPtr state) {
            uint processId; GetWindowThreadProcessId(handle, out processId);
            if (processId == (uint)expectedProcessId && IsWindowVisible(handle)) result.Add(handle);
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }
}
'@
        Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
        $deadline=[DateTime]::UtcNow.AddSeconds(12);$mainWindowSeen=$false
        do {
            $childIds=@([AtaraxiaGuiWindowProbe]::GetChildProcessIds($launcher.Id))
            foreach($childId in $childIds){if([AtaraxiaGuiWindowProbe]::HasMainWindow($childId)){$mainWindowSeen=$true;break}}
            if($mainWindowSeen){break}
            $launcher.Refresh();if($launcher.HasExited){break}
            Start-Sleep -Milliseconds 200
        } while([DateTime]::UtcNow -lt $deadline)
        if($mainWindowSeen){
            Start-Sleep -Milliseconds 2500
            $launcher.Refresh()
            $childIds=@([AtaraxiaGuiWindowProbe]::GetChildProcessIds($launcher.Id))
            $mainWindowSeen=$false
            foreach($childId in $childIds){if([AtaraxiaGuiWindowProbe]::HasMainWindow($childId)){$mainWindowSeen=$true;break}}
        }
        $launcher.Refresh();$windowDetails=@($childIds|ForEach-Object{"PID ${_}: $([AtaraxiaGuiWindowProbe]::DescribeWindows($_))"}) -join ' '
        $launcherText=[AtaraxiaGuiWindowProbe]::DescribeWindowText($launcher.Id)
        $childWindowText=@($childIds|ForEach-Object{
            $processId=[int]$_;$descriptions=[System.Collections.Generic.List[string]]::new()
            foreach($handle in [AtaraxiaGuiWindowProbe]::GetVisibleWindows($processId)){
                try{$element=[Windows.Automation.AutomationElement]::FromHandle($handle);$descendants=$element.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition);for($i=0;$i -lt $descendants.Count;$i++){$name=[string]$descendants[$i].Current.Name;if(-not[string]::IsNullOrWhiteSpace($name)){$descriptions.Add($name)}}}catch{}
            }
            "PID ${processId}: $($descriptions -join ' | ')"
        }) -join ' '
        Assert-True $mainWindowSeen ("Ataraxia.exe did not create its main GUI window. LauncherExited=$($launcher.HasExited); ChildPids=$($childIds -join ','); Windows=$windowDetails; ChildMessage=$childWindowText; LauncherWindows=$([AtaraxiaGuiWindowProbe]::DescribeWindows($launcher.Id)); Message=$launcherText")
        $mainGuiProcessId=@($childIds|Where-Object{[AtaraxiaGuiWindowProbe]::HasMainWindow([int]$_)}|Select-Object -First 1)
        $mainWindowHandle=[AtaraxiaGuiWindowProbe]::GetMainWindowHandle([int]$mainGuiProcessId[0])
        Assert-True ($mainWindowHandle -ne [IntPtr]::Zero) 'Main GUI window handle could not be found for activation verification.'
        $null=[AtaraxiaGuiWindowProbe]::MinimizeWindow($mainWindowHandle)
        Start-Sleep -Milliseconds 150
        Assert-True ([AtaraxiaGuiWindowProbe]::IsWindowMinimized($mainWindowHandle)) 'GUI window could not be minimized for the repeated-launch check.'
        $secondLauncher=Start-Process -FilePath (Join-Path $projectRoot 'Ataraxia.exe') -ArgumentList @('-NoSplash','-ConfigPath',$configPath) -WorkingDirectory $projectRoot -PassThru
        $secondDeadline=[DateTime]::UtcNow.AddSeconds(8);$secondMainWindowSeen=$false;$existingWindowRestored=$false
        do {
            $secondChildIds=@([AtaraxiaGuiWindowProbe]::GetChildProcessIds($secondLauncher.Id))
            foreach($childId in $secondChildIds){if([AtaraxiaGuiWindowProbe]::HasMainWindow($childId)){$secondMainWindowSeen=$true;break}}
            $secondLauncher.Refresh();$existingWindowRestored=(-not [AtaraxiaGuiWindowProbe]::IsWindowMinimized($mainWindowHandle))
            if($secondLauncher.HasExited -and $existingWindowRestored){break}
            Start-Sleep -Milliseconds 100
        } while([DateTime]::UtcNow -lt $secondDeadline)
        $secondLauncher.Refresh();$childIds=@([AtaraxiaGuiWindowProbe]::GetChildProcessIds($launcher.Id))
        $mainWindowSeen=@($childIds|Where-Object{[AtaraxiaGuiWindowProbe]::HasMainWindow([int]$_)}).Count -gt 0
        Assert-True ($secondLauncher.HasExited -and $secondLauncher.ExitCode -eq 0 -and -not $secondMainWindowSeen -and $mainWindowSeen -and $existingWindowRestored) 'Launching the same config created another GUI, failed cleanly, or did not restore the existing window.'
    } finally {
        foreach($childId in $secondChildIds){Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue}
        if($null -ne $secondLauncher){Stop-Process -Id $secondLauncher.Id -Force -ErrorAction SilentlyContinue}
        foreach($childId in $childIds){Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue}
        if($null -ne $launcher){Stop-Process -Id $launcher.Id -Force -ErrorAction SilentlyContinue}
        $logPath=Join-Path $tempDirectory 'diagnostic-logs/gui-startup.log'
        if(Test-Path $logPath){Write-Output ('GUI_STARTUP_LOG '+$logPath);Get-Content -LiteralPath $logPath -Raw}
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
        $env:ATARAXIA_ERROR_LOG_PATH=$previousErrorLogPath
    }
}
Test-Case 'Optional GUI integration: input text stays within visible text bounds' {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
    . (Join-Path $projectRoot 'scripts/GuiInputLayout.ps1')
    [xml]$view=[IO.File]::ReadAllText((Join-Path $projectRoot 'scripts/presentation/AtaraxiaWindow.xaml'))
    $window=[Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($view))
    try {
        $window.ShowInTaskbar=$false;$window.ShowActivated=$false;$window.Opacity=0
        $window.FindName('SettingsPanel').Visibility=[Windows.Visibility]::Visible
        $window.Show()
        foreach($buttonNode in $view.SelectNodes('//*[local-name()="Button"][.//*[local-name()="Path"]]')){$name=$buttonNode.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml');if([string]::IsNullOrWhiteSpace($name)){continue};$button=$window.FindName($name);Assert-True ([Windows.Automation.AutomationProperties]::GetName($button) -eq [string]$button.ToolTip) "Icon button $name does not expose its tooltip as the UI Automation name."}
        foreach($name in @('RuntimeConfig','TaskName','Workspace','Goal')){
            $input=$window.FindName($name)
            Assert-True ($null -ne $input) "Input control '$name' was not found in the WPF view."
            $input.Text=if($name -eq 'Goal'){"Agjpqy 日本語入力`nAgjpqy 日本語入力"}else{'Agjpqy 日本語入力'}
            if($name -eq 'Goal'){
                $lineCount=2
                $input.Height=Get-AtaraxiaGuiInputHeight $lineCount $input.FontSize ($input.Padding.Top+$input.Padding.Bottom) $input.MinHeight $input.MaxHeight
            }
            $input.UpdateLayout();$input.ApplyTemplate()
            Assert-True ($input.ActualWidth -gt 0 -and $input.ActualHeight -gt 0) "Input control '$name' has no rendered size."
            $contentHost=$input.Template.FindName('PART_ContentHost',$input)
            Assert-True ($null -ne $contentHost -and $contentHost.ViewportHeight -gt 0) "Input control '$name' has no visible text viewport."
            for($index=0;$index -lt $input.Text.Length;$index++){
                if($input.Text[$index] -eq "`r" -or $input.Text[$index] -eq "`n"){continue}
                $glyph=$input.GetRectFromCharacterIndex($index)
                $visibleBottom=$input.ActualHeight-$input.Padding.Bottom-$input.BorderThickness.Bottom
                Assert-True ($glyph.Height -gt 0 -and $glyph.Top -ge 0 -and $glyph.Bottom -le $visibleBottom) "Input control '$name' clips character at index $index (top=$($glyph.Top), bottom=$($glyph.Bottom), visibleBottom=$visibleBottom)."
            }
        }
    } finally { if($null -ne $window){$window.Close()} }
}
Test-Case 'Optional GUI integration: theme changes update input and control colors' {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    . (Join-Path $projectRoot 'scripts/GuiTheme.ps1');. (Join-Path $projectRoot 'scripts/adapters/WpfThemeAdapter.ps1')
    [xml]$view=[IO.File]::ReadAllText((Join-Path $projectRoot 'scripts/presentation/AtaraxiaWindow.xaml'))
    $window=[Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($view))
    try {
        $window.ShowInTaskbar=$false;$window.ShowActivated=$false;$window.Opacity=0
        $window.FindName('SettingsPanel').Visibility=[Windows.Visibility]::Visible;$window.Show()
        $createBrush={param($Hex)([Windows.Media.BrushConverter]::new()).ConvertFromString($Hex)}
        Set-AtaraxiaWpfThemeResources $window.Resources (Get-AtaraxiaThemePalette $guiThemeDefinitions 'dark') $createBrush
        $window.UpdateLayout();$runtimeInput=$window.FindName('RuntimeConfig');$modelInput=$window.FindName('ModelFileSelector')
        $brushColor={param($Brush)'#'+$Brush.Color.ToString().Substring(3)}
        Assert-True ((& $brushColor $runtimeInput.Background) -eq (Get-AtaraxiaThemePalette $guiThemeDefinitions 'dark').surface -and (& $brushColor $runtimeInput.Foreground) -eq (Get-AtaraxiaThemePalette $guiThemeDefinitions 'dark').primary_text -and (& $brushColor $modelInput.Background) -eq (Get-AtaraxiaThemePalette $guiThemeDefinitions 'dark').surface) 'Dark theme did not apply readable surface and text colors to the main text and selection controls.'
        $darkBorder=$runtimeInput.BorderBrush.Color.ToString();$darkTrack=$window.Resources['BorderBrush'].Color.ToString()
        Set-AtaraxiaWpfThemeResources $window.Resources (Get-AtaraxiaThemePalette $guiThemeDefinitions 'light') $createBrush;$window.UpdateLayout()
        Assert-True ((& $brushColor $runtimeInput.Background) -eq (Get-AtaraxiaThemePalette $guiThemeDefinitions 'light').surface -and (& $brushColor $runtimeInput.Foreground) -eq (Get-AtaraxiaThemePalette $guiThemeDefinitions 'light').primary_text -and $darkBorder -ne $runtimeInput.BorderBrush.Color.ToString() -and $darkTrack -ne $window.Resources['BorderBrush'].Color.ToString()) 'Input controls or shared component resources retained stale colors after a theme change.'
    } finally { if($null -ne $window){$window.Close()} }
}
Test-Case 'Optional GUI integration: closing a preset name input cancels without closing the owner' {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
    . (Join-Path $projectRoot 'scripts/GuiConversationModel.ps1');. (Join-Path $projectRoot 'scripts/GuiDialogContracts.ps1');. (Join-Path $projectRoot 'scripts/adapters/WpfIconAssetAdapter.ps1');. (Join-Path $projectRoot 'scripts/adapters/WpfDialogAdapter.ps1')
    $owner=[Windows.Window]::new();$owner.Width=320;$owner.Height=180;$owner.ShowInTaskbar=$false;$owner.ShowActivated=$false;$owner.Opacity=0
    foreach($entry in @(@{key='SurfaceBrush';color='#FFFFFF'},@{key='BorderBrush';color='#CCCCCC'},@{key='PrimaryTextBrush';color='#111111'},@{key='AccentBrush';color='#4059C7'},@{key='AccentTextBrush';color='#FFFFFF'},@{key='IconBrush';color='#333333'})){$owner.Resources[$entry.key]=[Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($entry.color))}
    $definition=Read-Json (Join-Path $projectRoot 'configs/gui-dialog-contracts.json')
    $contract=New-AtaraxiaDialogContract $definition input 'Rename preset' 'Enter a preset name.' 'Original name' 'dialog-input' 'Confirm' 'Cancel'
    $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(300);$timerObserved=[pscustomobject]@{value=$false}
    $timer.Add_Tick({$timerObserved.value=$true;$timer.Stop();$modalHandle=[IntPtr]::Zero;foreach($handle in [AtaraxiaGuiWindowProbe]::GetVisibleWindows($PID)){$candidate=[Windows.Automation.AutomationElement]::FromHandle($handle);if($candidate.Current.Name -eq 'Rename preset'){$modalHandle=$handle;break}};if($modalHandle -eq [IntPtr]::Zero){throw 'Preset name dialog did not open.'};$modalElement=[Windows.Automation.AutomationElement]::FromHandle($modalHandle);$buttonCondition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Button);$buttons=$modalElement.FindAll([Windows.Automation.TreeScope]::Descendants,$buttonCondition);if($buttons.Count -eq 0 -or $buttons[0].Current.Name -ne 'Close'){throw 'Preset name dialog close icon has no accessible name.'};$invoke=$buttons[0].GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern);$invoke.Invoke()}.GetNewClosure())
    try{$owner.Show();$timer.Start();try{$result=Render-AtaraxiaWpfDialog $contract $owner}catch{throw ('TimerObserved='+$timerObserved.value+[Environment]::NewLine+$_.Exception.ToString()+[Environment]::NewLine+[string]$_.ScriptStackTrace)};Assert-True ($null -eq $result -and $owner.IsVisible) 'Closing a preset name dialog did not cancel cleanly or also closed its owner.'}
    finally{$timer.Stop();if($owner.IsVisible){$owner.Close()}}
}
Test-Case 'Optional GUI integration: model parameter spinner updates numeric inputs' {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    . (Join-Path $projectRoot 'scripts/GuiPresentationPort.ps1');. (Join-Path $projectRoot 'scripts/GuiInputLayout.ps1');. (Join-Path $projectRoot 'scripts/GuiModelParameters.ps1');. (Join-Path $projectRoot 'scripts/GuiModelParameterEditorState.ps1');. (Join-Path $projectRoot 'scripts/adapters/WpfGuiViewAdapter.ps1');. (Join-Path $projectRoot 'scripts/adapters/WpfIconAssetAdapter.ps1');. (Join-Path $projectRoot 'scripts/adapters/WpfModelParameterAdapter.ps1');. (Join-Path $projectRoot 'scripts/GuiTheme.ps1');. (Join-Path $projectRoot 'scripts/adapters/WpfThemeAdapter.ps1')
    [xml]$view=[IO.File]::ReadAllText((Join-Path $projectRoot 'scripts/presentation/AtaraxiaWindow.xaml'))
    $window=[Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($view))
    try {
        $window.ShowInTaskbar=$false;$window.ShowActivated=$false;$window.Opacity=0
        $window.FindName('SettingsPanel').Visibility=[Windows.Visibility]::Visible;$window.Show()
        $panel=$window.FindName('ParameterPanel');$state=New-AtaraxiaModelParameterEditorState;$saveCalls=[pscustomobject]@{count=0};$save={$saveCalls.count++}.GetNewClosure();$handlers=New-AtaraxiaModelParameterEditorHandlers $state $save
        $port=New-AtaraxiaWpfGuiViewPort @{parameter_panel=$panel;dispatcher=$window.Dispatcher} @{} {param($Text)} ${function:Get-AtaraxiaGuiInputHeight}
        $values=[pscustomobject]@{max_tokens=1024;temperature=0.70;top_p=0.90;top_k=40;presence_penalty=0.0;frequency_penalty=0.0;repetition_penalty=1.0;seed=-1;stop=@()}
        $controls=New-AtaraxiaWpfModelParameterControls $panel @(Get-AtaraxiaModelParameterDefinitions) $values $port $window {param($Key)$Key} $handlers.on_dirty $handlers.on_save ${function:Get-AtaraxiaModelParameterInputResult} ${function:Get-AtaraxiaModelParameterStepValue}
        $panel.UpdateLayout()
        $createBrush={param($Hex)([Windows.Media.BrushConverter]::new()).ConvertFromString($Hex)}
        Set-AtaraxiaWpfThemeResources $window.Resources (Get-AtaraxiaThemePalette $guiThemeDefinitions 'dark') $createBrush;$panel.UpdateLayout()
        $stopInput=$controls.stop;$darkPalette=Get-AtaraxiaThemePalette $guiThemeDefinitions 'dark'
        $brushColor={param($Brush)'#'+$Brush.Color.ToString().Substring(3)}
        Assert-True ((& $brushColor $stopInput.Background) -eq $darkPalette.surface -and (& $brushColor $stopInput.Foreground) -eq $darkPalette.primary_text -and (& $brushColor $stopInput.BorderBrush) -eq $darkPalette.border) 'Stop parameter input colors do not match the active dark palette.'
        Set-AtaraxiaWpfThemeResources $window.Resources (Get-AtaraxiaThemePalette $guiThemeDefinitions 'light') $createBrush;$panel.UpdateLayout();$lightPalette=Get-AtaraxiaThemePalette $guiThemeDefinitions 'light'
        Assert-True ((& $brushColor $stopInput.Background) -eq $lightPalette.surface -and (& $brushColor $stopInput.Foreground) -eq $lightPalette.primary_text -and (& $brushColor $stopInput.BorderBrush) -eq $lightPalette.border) 'Stop parameter input did not follow a later theme switch.'
        $temperature=$controls.temperature;$temperatureSlider=$temperature.Tag;$temperatureUp=$temperatureSlider.Tag.increase_button;$temperatureDown=$temperatureSlider.Tag.decrease_button
        Assert-True ([Windows.Automation.AutomationProperties]::GetName($temperatureUp) -eq [string]$temperatureUp.ToolTip -and [Windows.Automation.AutomationProperties]::GetName($temperatureDown) -eq [string]$temperatureDown.ToolTip) 'Model parameter spinner icons do not expose their localized tooltip as the UI Automation name.'
        Assert-True ($panel.Children.Count -eq 9 -and @($panel.Children|Where-Object{$_.Children[0].Children.Count -eq 1 -and $_.Children[0].Children[0] -is [Windows.Controls.TextBlock]}).Count -eq 9) 'Model parameter help buttons should be removed and labels should remain.'
        foreach($definition in Get-AtaraxiaModelParameterDefinitions){$row=@($panel.Children|Where-Object{$_.Children[0].Children[0].Text -eq $definition.key})[0];$label=$row.Children[0].Children[0];Assert-True ($null -ne $row -and $label.ToolTip -eq $definition.help_key -and [Windows.Controls.ToolTipService]::GetPlacement($label) -eq [Windows.Controls.Primitives.PlacementMode]::Mouse -and [Windows.Controls.ToolTipService]::GetInitialShowDelay($label) -eq 300) "Parameter $($definition.key) does not show its help at the mouse position."}
        Assert-True ($temperatureUp -is [Windows.Controls.Button] -and $temperatureDown -is [Windows.Controls.Button]) 'Numeric parameter input does not expose up and down buttons.'
        Assert-True ($temperatureSlider.SmallChange -eq 0.1 -and $temperatureSlider.LargeChange -eq 0.1 -and $temperatureSlider.IsSnapToTickEnabled) 'Temperature slider is not configured for coarse 0.1 steps.'
        $contextSlider=$controls.max_tokens.Tag;Assert-True ($contextSlider.SmallChange -eq 256 -and $contextSlider.LargeChange -eq 256 -and $contextSlider.IsSnapToTickEnabled) 'Context-size slider is not configured for 256-token steps.'
        $seedInput=$controls.seed;Assert-True ($seedInput.Tag.definition.key -eq 'seed' -and $null -eq $seedInput.Tag.increase_button.Tag.slider -and $seedInput.MinWidth -ge 100 -and $seedInput.Width -ge 100) 'Seed should have no slider and its input must fit the full signed 32-bit value.'
        $inputRightEdges=@(foreach($key in @('max_tokens','temperature','top_p','top_k','presence_penalty','frequency_penalty','repetition_penalty','seed')){$parameterInput=$controls[$key];$position=$parameterInput.TransformToAncestor($panel).Transform([Windows.Point]::new(0,0));$position.X+$parameterInput.ActualWidth});Assert-True ((($inputRightEdges|Measure-Object -Maximum).Maximum-($inputRightEdges|Measure-Object -Minimum).Minimum) -lt 1.0) 'Numeric input right edges are not aligned across parameter rows.'
        $seedInput.Text='2147483647';Assert-True ($seedInput.Text -eq '2147483647') 'Seed input did not retain its maximum value.'
        $seedInput.Tag.increase_button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent));Assert-True ($seedInput.Text -eq '2147483647') 'Seed increment exceeded its maximum.'
        $temperatureUp.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-True ($temperature.Text -eq '0.71' -and [math]::Abs($temperatureSlider.Value-0.71) -lt 0.000001 -and $state.dirty) 'Temperature spinner did not increase by 0.01 and synchronize the slider.'
        $temperatureDown.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-True ($temperature.Text -eq '0.70' -and [math]::Abs($temperatureSlider.Value-0.70) -lt 0.000001) 'Temperature spinner did not decrease by 0.01.'
        $temperature.Text='0.73';Assert-True ([math]::Abs($temperatureSlider.Value-0.73) -lt 0.000001) 'Direct numeric entry was rounded to the coarse slider step.'
        $topK=$controls.top_k;$topK.Tag.Tag.increase_button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-True ($topK.Text -eq '41') 'Integer parameter spinner did not increase by one.'
        $temperatureSlider.Value=$temperatureSlider.Maximum;$temperatureSlider.Tag.input.Text=([double]$temperatureSlider.Value).ToString('0.00',[Globalization.CultureInfo]::InvariantCulture)
        $temperatureUp.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-True ($temperatureSlider.Value -eq $temperatureSlider.Maximum -and $temperature.Text -eq '2.00') 'Spinner crossed the configured maximum or failed to normalize the displayed value.'
    } finally { if($null -ne $window){$window.Close()} }
}
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

Test-Case 'Phase input projection preserves latest effects and compressed context' {
    . (Join-Path $projectRoot 'scripts/AgentCore.ps1')
    $task=[pscustomobject]@{goal='Complete the task';context='Task context';constraints=@('Keep changes small')}
    $latest=[pscustomobject]@{phase='Execute';result=[pscustomobject]@{summary='Done'};cycle=2;commands_run=@('build');files_changed=@('readme.md')}
    $state=[pscustomobject]@{cycle=2;history=@($latest);results=[pscustomobject]@{execute=$latest.result};context_summary=[pscustomobject]@{compressed_context='Short summary';retained_facts=@('Fact');open_items=@('Review')}}
    $input=Agent-GetPhaseInput $task $state 'Review'
    Assert-True ($input.goal -eq $task.goal -and $input.context -eq $task.context -and $input.phase -eq 'Review' -and $input.latest_stage -eq 'Execute') 'Phase input projection lost task or latest-stage fields.'
    Assert-True ($input.phase_data.result.summary -eq 'Done' -and [string]$input.phase_data.commands_run -eq 'build' -and [string]$input.phase_data.files_changed -eq 'readme.md') 'Phase input projection did not preserve prior execution effects.'
    Assert-True ($input.results.compressed_context -eq 'Short summary' -and [string]$input.context_summary.open_items -eq 'Review') 'Phase input projection did not prefer the compressed context summary.'
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

Test-Case 'Workspace root and target checks use injected path security ports' {
    . (Join-Path $projectRoot 'scripts/AgentHarness.ps1')
    $calls=[System.Collections.Generic.List[string]]::new();$root=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'ataraxia-virtual-workspace'))
    $test={param($Path,$Type)$calls.Add("test:$Type");return $true}.GetNewClosure()
    $resolve={param($Path)$calls.Add('resolve');[IO.Path]::GetFullPath($Path)}.GetNewClosure()
    $info={param($Path)$calls.Add('info');[pscustomobject]@{is_directory=$true;is_reparse_point=$false}}.GetNewClosure()
    $pathPort=New-AgentWorkspacePathDependencies $test $resolve $info
    $reader=[pscustomobject]@{path_dependencies=$pathPort}
    $resolved=Resolve-AgentWorkspaceDirectory 'work' $root $reader
    Assert-True ($resolved -eq [IO.Path]::GetFullPath((Join-Path $root 'work')) -and $calls -contains 'resolve' -and $calls -contains 'test:Container' -and $calls -contains 'info') 'Workspace root validation bypassed the path security port.'
    $reparseInfo={param($Path)[pscustomobject]@{is_directory=$true;is_reparse_point=$true}}.GetNewClosure();$reparsePort=New-AgentWorkspacePathDependencies $test $resolve $reparseInfo;$reader.path_dependencies=$reparsePort
    $rejected=$false;try{$null=Resolve-AgentWorkspaceDirectory 'work' $root $reader}catch{$rejected=$true}
    Assert-True $rejected 'A workspace root marked as a reparse point was accepted through an injected port.'
}

Test-Case 'Agent JSON parsing and formatting cover fences and configured widths' {
    . (Join-Path $projectRoot 'scripts/AgentCore.ps1')
    $parsed=Agent-ConvertModelJson ('```json'+"`n"+'{"answer":"ok"}'+"`n"+'```')
    Assert-True ($parsed.answer -eq 'ok') 'A complete JSON code fence was not parsed.'
    foreach($invalid in @('', ('```json'+"`n"+'{"answer":"ok"}'+"`n"), 'prefix {"answer":"ok"}', '{broken')){
        $rejected=$false;try{$null=Agent-ConvertModelJson $invalid}catch{$rejected=$true};Assert-True $rejected "Invalid model JSON was accepted: $invalid"
    }
    $value=[pscustomobject][ordered]@{answer='ok';count=2}
    $pretty=Agent-FormatJson $value ([pscustomobject]@{json_pretty=$true;json_indent=4})
    $compact=Agent-FormatJson $value ([pscustomobject]@{json_pretty=$false;json_indent=2})
    Assert-True ($pretty -match '(?m)^    "answer"' -and ($pretty|ConvertFrom-Json).count -eq 2) 'Configured JSON indentation was not applied or changed the serialized data.'
    Assert-True ($compact -eq '{"answer":"ok","count":2}') 'Compact JSON output was not compact or stable.'
    $rejected=$false;try{$null=Agent-FormatJson $value ([pscustomobject]@{json_indent=9})}catch{$rejected=$true};Assert-True $rejected 'An unsupported JSON indent width was accepted.'
}

Test-Case 'User JSON repair preserves recoverable properties and applies only after approval' {
    . (Join-Path $projectRoot 'scripts/StructuredData.ps1')
    $repairFile=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-repair-'+[guid]::NewGuid().ToString('N')+'-conversation.json')
    $original="{`n  `"schema_version`": 1,`n  `"artifact_type`": `"conversation`",`n  `"entries`": [`n    {`"kind`":`"user_query`",`"body`":`"keep this`",`"timestamp`":`"2026-01-01T00:00:00Z`"}`n  ],`n  `"extension_data`": {`"keep`": true},`n  `"broken`": [1,`n  `"tail`": `"recover me`"`n}"
    [IO.File]::WriteAllText($repairFile,$original,[Text.UTF8Encoding]::new($false))
    try {
        $bytes=[IO.File]::ReadAllBytes($repairFile);$proposal=New-AgentJsonRepairProposal $repairFile $bytes 4194304
        Assert-True ($proposal.repairable -and $proposal.kind -eq 'conversation' -and $proposal.value.artifact_type -eq 'conversation' -and $proposal.value.entries.Count -eq 1 -and $proposal.value.entries[0].body -eq 'keep this' -and $proposal.value.extension_data.keep -and $proposal.value.tail -eq 'recover me') 'JSON repair did not salvage intact top-level fields and valid collection items.'
        $journalPath=Join-Path (Split-Path -Parent $repairFile) 'run-changes.json';$journal=New-AgentJsonRepairProposal $journalPath $bytes 4194304
        Assert-True (-not $journal.repairable -and [string]::IsNullOrEmpty($journal.backup_path)) 'Unsafe run journals must not receive a guessed automatic repair proposal.'
        $resourcePath=Join-Path ([IO.Path]::GetTempPath()) 'config.example.json';$resource=New-AgentJsonRepairProposal $resourcePath $bytes 4194304
        Assert-True ($resource.kind -eq 'resource' -and -not $resource.repairable) 'Bundled JSON resources must use their resource recovery path instead of user-data repair.'
        [IO.File]::WriteAllText($repairFile,($original+' '),[Text.UTF8Encoding]::new($false));$conflict=$false;try{$null=Invoke-AgentJsonRepairProposal $proposal $repairFile {return $true}}catch{$conflict=$true};Assert-True ($conflict -and [IO.File]::ReadAllText($repairFile) -ceq ($original+' ')) 'JSON repair overwrote a file that changed after proposal generation.'
        [IO.File]::WriteAllText($repairFile,$original,[Text.UTF8Encoding]::new($false))
        $stagedWrite={param($Path,$Bytes)[IO.File]::WriteAllBytes($Path,$Bytes);if($Path -like '*.tmp'){[IO.File]::WriteAllText($repairFile,$original+' external update',[Text.UTF8Encoding]::new($false))}}.GetNewClosure()
        $fileSystem=New-AgentJsonFileSystemPort -WriteBytes $stagedWrite
        $lateConflict=$false;try{$null=Invoke-AgentJsonRepairProposal $proposal $repairFile {return $true} $fileSystem}catch{$lateConflict=$true}
        Assert-True ($lateConflict -and [IO.File]::ReadAllText($repairFile) -ceq ($original+' external update')) 'Repair replaced an external update made after backup staging.'
        [IO.File]::WriteAllText($repairFile,$original,[Text.UTF8Encoding]::new($false))
        $script:testJsonRepairApproval=$false
        $repairHandler={param($candidate)Invoke-AgentJsonRepairProposal $candidate $candidate.path {return $script:testJsonRepairApproval}}
        $declined=$false;try{$null=Read-AgentJsonFile $repairFile 4194304 $repairHandler}catch{$declined=$true};Assert-True ($declined -and [IO.File]::ReadAllText($repairFile) -ceq $original) 'Declining JSON repair modified the original file.'
        $script:testJsonRepairApproval=$true
        $repaired=Read-AgentJsonFile $repairFile 4194304 $repairHandler
        $backup=Get-ChildItem -LiteralPath (Split-Path -Parent $repairFile) -Filter ((Split-Path -Leaf $repairFile)+'.corrupt.*.bak')|Select-Object -First 1
        Assert-True ($repaired.entries.Count -eq 1 -and $repaired.extension_data.keep -and $repaired.tail -eq 'recover me' -and $null -ne $backup -and [IO.File]::ReadAllText($backup.FullName) -ceq $original) 'Approved JSON repair did not atomically apply a validated file while preserving an exact original backup.'
    } finally {Remove-Variable testJsonRepairApproval -Scope Script -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $repairFile -Force -ErrorAction SilentlyContinue;Get-ChildItem -LiteralPath (Split-Path -Parent $repairFile) -Filter ((Split-Path -Leaf $repairFile)+'.corrupt.*.bak') -ErrorAction SilentlyContinue|Remove-Item -Force -ErrorAction SilentlyContinue}
}

Test-Case 'Personal preset JSON repair restores schema and keeps valid presets' {
    . (Join-Path $projectRoot 'scripts/StructuredData.ps1')
    $path=Join-Path ([IO.Path]::GetTempPath()) 'model-parameter-presets.json';Register-AgentJsonRepairKind $path 'model_parameter_presets'
    $text='{"schema_version":"bad","active_preset_id":7,"presets":[{"id":"keep","name":"Keep","request_parameters":{"temperature":0.5}},{"id":"drop","name":7,"request_parameters":[]}],"overrides":"broken","pending_shared_settings":{"schema_version":1,"request_parameters":{"temperature":0.8}}}'
    $proposal=New-AgentJsonRepairProposal $path ([Text.UTF8Encoding]::new($false).GetBytes($text))
    Assert-True ($proposal.repairable -and $proposal.value.schema_version -eq 1 -and $proposal.value.presets.Count -eq 1 -and $proposal.value.presets[0].id -eq 'keep' -and $proposal.value.overrides.Count -eq 0 -and $proposal.value.pending_shared_settings.request_parameters.temperature -eq 0.8) 'Personal preset repair did not restore its expected shape while retaining valid entries and the recovery journal.'
}

Test-Case 'JSON metadata writes use an atomic store adapter and preserve existing values on failure' {
    . (Join-Path $projectRoot 'scripts/JsonFileStore.ps1')
    $storeSource=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/JsonFileStore.ps1') -Raw -Encoding UTF8
    Assert-True ($storeSource -match '\[IO\.File\]::Replace\(\$temporary,\$Path,\$backup\)' -and $storeSource -notmatch '\[IO\.File\]::Move\(\$temporary,\$Path,\$true\)') 'Atomic JSON replacement uses an overload unavailable to Windows PowerShell 5.1.'
    $path=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-store-'+[guid]::NewGuid().ToString('N')+'.json')
    $original=[pscustomobject]@{value='before'};$replacement=[pscustomobject]@{value='after'}
    try{
        Write-AtaraxiaJsonStoreFile $path $original $null 10
        Write-AtaraxiaJsonStoreFile $path $replacement $null 10
        $saved=Read-AgentJsonFile $path
        Assert-True ($saved.value -eq 'after' -and @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter ((Split-Path -Leaf $path)+'.*.tmp')).Count -eq 0) 'Atomic JSON store did not replace the document cleanly or left a temporary file.'
        $failure=New-AtaraxiaJsonFileStoreDependencies -WriteJson {param($Target,$Value,$Depth)throw 'simulated storage failure'}
        $rejected=$false;try{Write-AtaraxiaJsonStoreFile $path ([pscustomobject]@{value='lost'}) $failure 10}catch{$rejected=$true}
        $preserved=Read-AgentJsonFile $path
        Assert-True ($rejected -and $preserved.value -eq 'after') 'A failed storage adapter changed the previous JSON value.'
    }finally{Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}
}

Test-Case 'Project and session stores route directory operations through injected file ports' {
    . (Join-Path $projectRoot 'scripts/ProjectStore.ps1')
    . (Join-Path $projectRoot 'scripts/SessionStore.ps1')
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-port-'+[guid]::NewGuid().ToString('N'))
    $calls=[System.Collections.Generic.List[string]]::new()
    $testPath={param($Path,$Type)$calls.Add('test');Test-Path -LiteralPath $Path -PathType $Type}.GetNewClosure()
    $listDirectories={param($Path)$calls.Add('list');@(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue)}.GetNewClosure()
    $createDirectory={param($Path)$calls.Add('create');New-Item -ItemType Directory -Force -Path $Path|Out-Null}.GetNewClosure()
    $movePath={param($Source,$Destination,$Force)$calls.Add('move');Move-Item -LiteralPath $Source -Destination $Destination -Force:$Force}.GetNewClosure()
    $fileStore=New-AtaraxiaJsonFileStoreDependencies -TestPath $testPath -ListDirectories $listDirectories -EnsureDirectory $createDirectory -MovePath $movePath
    try{
        $null=New-AtaraxiaProject $root 'Research' $fileStore
        $null=Get-AtaraxiaProjectNames $root $fileStore
        $null=Rename-AtaraxiaProject $root 'Research' 'Studio' $fileStore
        Assert-True ($calls -contains 'create' -and $calls -contains 'list' -and $calls -contains 'move') 'Project store bypassed an injected directory operation.'
        $projectPath=Get-AtaraxiaProjectPath $root 'Studio';$null=New-AtaraxiaSessionDirectory $projectPath $null -Force
        $sessionDeps=New-AtaraxiaSessionStoreDependencies -FileStore $fileStore
        $sessionsRoot=Get-AtaraxiaSessionsRoot $projectPath;$null=New-AtaraxiaSessionDirectory $sessionsRoot $sessionDeps -Force
        $null=Get-AtaraxiaSessions $projectPath $sessionDeps
        Assert-True ($calls -contains 'test' -and $calls -contains 'list') 'Session store bypassed injected existence or enumeration operations.'
    }finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}

Test-Case 'Workflow transitions cover matched fallback and invalid routes' {
    . (Join-Path $projectRoot 'scripts/AgentCore.ps1')
    $coreSource=Get-Content -Raw (Join-Path $projectRoot 'scripts/AgentCore.ps1')
    $workflowPath=Join-Path $projectRoot 'scripts/AgentWorkflow.ps1'
    Assert-True ((Test-Path -LiteralPath $workflowPath -PathType Leaf) -and $coreSource -match 'AgentWorkflow\.ps1' -and $coreSource -notmatch 'function Agent-ResolveTransition') 'Workflow transition rules are still owned by the execution core.'
    $workflow=[pscustomobject]@{terminal_state='Complete';waiting_state='AwaitUser';replan_state='ReplanCore';stages=@([pscustomobject]@{id='Review';role_id='reviewer';result_key='review';allowed_next_stages=@('Complete','Repair');transitions=@();default_next='Repair'},[pscustomobject]@{id='Repair';role_id='executor';result_key='repair';transitions=@();default_next='Complete'})}
    $review=[pscustomobject]@{id='Review';transitions=@([pscustomobject]@{field='approved';equals=$true;next='Complete'},[pscustomobject]@{next='Repair'});default_next='Repair'}
    Assert-True ((Agent-ResolveTransition $workflow $review ([pscustomobject]@{approved=$true})) -eq 'Complete' -and (Agent-ResolveTransition $workflow $review ([pscustomobject]@{approved=$false})) -eq 'Repair') 'Conditional transitions did not select their matching and fallback routes.'
    $dynamic=[pscustomobject]@{id='Route';dynamic_transition_field='next_stage';allowed_next_stages=@('Repair','Complete')}
    Assert-True ((Agent-ResolveTransition $workflow $dynamic ([pscustomobject]@{next_stage='Repair'})) -eq 'Repair') 'A valid dynamic route was rejected.'
    foreach($bad in @('', 'Unknown', 'AwaitUser')){$rejected=$false;try{$null=Agent-ResolveTransition $workflow $dynamic ([pscustomobject]@{next_stage=$bad})}catch{$rejected=$true};Assert-True $rejected "A disallowed dynamic route was accepted: '$bad'"}
    $state=[pscustomobject]@{cycle=0;phase='Review';results=[pscustomobject]@{}}
    $stage=[pscustomobject]@{id='Review';result_key='review';increment_cycle=$true;transitions=@([pscustomobject]@{next='Complete'})}
    $next=Agent-NextState $state $workflow $stage ([pscustomobject]@{approved=$true})
    Assert-True ($next.cycle -eq 1 -and $next.phase -eq 'Complete' -and $next.results.review.approved) 'State transition failed to increment cycle and store the result.'
}

Test-Case 'Workspace diff operations round-trip and reject inconsistent bases' {
    . (Join-Path $projectRoot 'scripts/AgentHarness.ps1')
    . (Join-Path $projectRoot 'scripts/FileSystemWorkspaceStore.ps1')
    $operations=@([pscustomobject]@{op='retain';count=1;lines=@()},[pscustomobject]@{op='delete';count=0;lines=@('remove')},[pscustomobject]@{op='insert';count=0;lines=@('inserted')},[pscustomobject]@{op='retain';count=1;lines=@()})
    $after=Convert-AgentOperationsToText "keep`r`nremove`r`nend" $operations
    Assert-True ($after -eq "keep`r`ninserted`r`nend") 'Workspace diff operations produced the wrong text.'
    $patch=New-TextPatch "keep`r`nremove`r`nend" $after
    Assert-True ((Apply-TextPatch "keep`r`nremove`r`nend" $patch) -eq $after) 'Generated text patch did not round-trip.'
    $tampered=$patch|ConvertTo-Json -Depth 20|ConvertFrom-Json;$tampered.base_hash='0'*64
    $rejected=$false;try{$null=Apply-TextPatch "keep`r`nremove`r`nend" $tampered}catch{$rejected=$true};Assert-True $rejected 'Text patch accepted a mismatched base hash.'
    foreach($badOperations in @(@([pscustomobject]@{op='delete';count=0;lines=@('wrong')}),@([pscustomobject]@{op='retain';count=1;lines=@()}))){$rejected=$false;try{$null=Convert-AgentOperationsToText "keep`r`nremove`r`nend" $badOperations}catch{$rejected=$true};Assert-True $rejected 'Workspace diff accepted mismatched or incomplete base coverage.'}
}

Test-Case 'Workspace change batch rejects before applying any valid prefix' {
    . (Join-Path $projectRoot 'scripts/AgentHarness.ps1')
    . (Join-Path $projectRoot 'scripts/FileSystemWorkspaceStore.ps1')
    $workspaceFileStore=New-AgentWorkspaceFileStoreDependencies
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-atomic-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $root -Force|Out-Null
    try{
        $firstPath=Join-Path $root 'first.txt';[IO.File]::WriteAllText($firstPath,'before',[Text.UTF8Encoding]::new($false))
        $outsideName='outside-'+(Split-Path -Leaf $root)+'.txt'
        $patch=New-TextPatch 'before' 'after'
        $changes=@([pscustomobject]@{path='first.txt';action='modify';base_hash=(Get-AgentWorkspaceHash 'before');operations=$patch.operations},[pscustomobject]@{path="../$outsideName";action='create';base_hash=(Get-AgentWorkspaceHash '');operations=@([pscustomobject]@{op='insert';count=0;lines=@('outside')})})
        $rejected=$false;try{$null=Apply-AgentWorkspaceChanges $root $changes '' $workspaceFileStore}catch{$rejected=$true}
        Assert-True ($rejected -and [IO.File]::ReadAllText($firstPath) -eq 'before' -and -not(Test-Path (Join-Path (Split-Path -Parent $root) $outsideName))) 'A rejected batch partially applied an earlier valid change or wrote outside the workspace.'
    }finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}

Test-Case 'Multimodal message conversion maps supported media types' {
    . (Join-Path $projectRoot 'scripts/AgentHarness.ps1')
    $media=@([pscustomobject]@{mime_type='image/png';data_base64='aW1hZ2U='},[pscustomobject]@{mime_type='audio/wav';data_base64='d2F2'},[pscustomobject]@{mime_type='audio/mpeg';data_base64='bXAz'},[pscustomobject]@{mime_type='application/pdf';data_base64='cGRm'})
    $parts=ConvertTo-AgentMessageContent 'Inspect these files.' $media
    Assert-True ($parts.Count -eq 4 -and $parts[0].type -eq 'text' -and $parts[1].image_url.url -eq 'data:image/png;base64,aW1hZ2U=') 'Text or image content was not mapped to the chat message structure.'
    Assert-True ($parts[2].type -eq 'input_audio' -and $parts[2].input_audio.format -eq 'wav' -and $parts[3].input_audio.format -eq 'mp3') 'Audio formats were not normalized for multimodal chat input.'
}

Test-Case 'Prompt boundaries use token counts instead of character thresholds' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'AgentCore.ps1')
    function Get-KoboldCppTokenCount([object]$Config,[object]$Value) { $text=if($Value -is [string]){$Value}else{(@($Value|ForEach-Object{[string]$_.content}) -join ' ')};return [regex]::Matches($text,'\S+').Count }
    $text='one supercalifragilisticexpialidocious three four';$split=Get-AgentTokenBalancedSplit ([pscustomobject]@{override=[pscustomobject]@{context_size=8192}}) $text
    Assert-True ($split.left -eq 'one supercalifragilisticexpialidocious' -and $split.right -eq ' three four' -and $split.left_tokens -eq 2) 'Oversized prompt splitting followed character length instead of measured token balance.'
    $source=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/AgentRoleExecution.ps1') -Raw -Encoding UTF8
    Assert-True ($source -notmatch 'Task goal.?\x27 262144|Task context.?\x27 262144|Combined common prompt.?\x27 262144' -and $source -match 'Get-AgentTokenBalancedSplit') 'Prompt character thresholds remain in the execution core.'
}

Test-Case 'Agent role and token behavior use injectable dependencies' {
    . (Join-Path $projectRoot 'scripts/AgentCore.ps1')
    $fake=[pscustomobject]@{completion_calls=0;token_calls=0;requests=[System.Collections.Generic.List[object]]::new()}
    $countTokens={param($Config,$Value)$fake.token_calls++;if($Value -is [string]){return [Math]::Max(1,[regex]::Matches($Value,'\S+').Count)};return [Math]::Max(1,[regex]::Matches(($Value|ConvertTo-Json -Depth 20 -Compress),'\S+').Count)}.GetNewClosure()
    $sendCompletion={param($Config,$Request)$fake.completion_calls++;$fake.requests.Add($Request);if($fake.completion_calls -eq 1){return [pscustomobject]@{choices=@([pscustomobject]@{message=[pscustomobject]@{content='not json'}})}};return [pscustomobject]@{choices=@([pscustomobject]@{message=[pscustomobject]@{content='{"answer":"done"}'}})}}.GetNewClosure()
    $dependencies=New-AgentDependencies -CountTokens $countTokens -SendCompletion $sendCompletion
    $config=[pscustomobject]@{json_retry_limit=1;override=$null}
    $messages=@([pscustomobject]@{role='system';content='test role'},[pscustomobject]@{role='user';content='return an answer'})
    $schema=[pscustomobject]@{type='object';required=@('answer');properties=[pscustomobject]@{answer=[pscustomobject]@{type='string'}};additionalProperties=$false}
    $result=Agent-InvokeRole $config $messages ([pscustomobject]@{type='json_object'}) $schema -Dependencies $dependencies
    Assert-True ($result.answer -eq 'done' -and $fake.completion_calls -eq 2 -and $fake.requests[1].messages[-1].content -match 'Retry Instructions') 'Injected completion did not preserve the JSON retry path and return the validated result.'
    $failureFake=[pscustomobject]@{completion_calls=0}
    $failureCompletion={param($Config,$Request)$failureFake.completion_calls++;throw 'synthetic transport failure'}.GetNewClosure()
    $failureDependencies=New-AgentDependencies -CountTokens $countTokens -SendCompletion $failureCompletion
    $failureConfig=[pscustomobject]@{json_retry_limit=3;override=$null}
    $failureRejected=$false;try{$null=Agent-InvokeRole $failureConfig $messages ([pscustomobject]@{type='json_object'}) $schema -Dependencies $failureDependencies}catch{$failureRejected=$_.Exception.Message -eq 'synthetic transport failure'}
    Assert-True ($failureRejected -and $failureFake.completion_calls -eq 1) 'A transport failure was retried as if it were invalid model JSON.'
    $retryFake=[pscustomobject]@{completion_calls=0}
    $retryCompletion={param($Config,$Request)$retryFake.completion_calls++;if($retryFake.completion_calls -lt 3){return [pscustomobject]@{choices=@([pscustomobject]@{message=[pscustomobject]@{content='invalid'}})}};return [pscustomobject]@{choices=@([pscustomobject]@{message=[pscustomobject]@{content='{"answer":"done"}'}})}}.GetNewClosure()
    $retryDependencies=New-AgentDependencies -CountTokens $countTokens -SendCompletion $retryCompletion
    $retryResult=Agent-InvokeRole ([pscustomobject]@{json_retry_limit=2;override=$null}) $messages ([pscustomobject]@{type='json_object'}) $schema -Dependencies $retryDependencies
    Assert-True ($retryResult.answer -eq 'done' -and $retryFake.completion_calls -eq 3) 'json_retry_limit did not allow the configured number of model-output retries.'
    $split=Get-AgentTokenBalancedSplit ([pscustomobject]@{override=[pscustomobject]@{context_size=8192}}) 'one two three four' -Dependencies $dependencies
    Assert-True ($split.left_tokens -eq 2 -and $fake.token_calls -gt 0) 'Injected token counter was not used to choose a balanced prompt split.'
}

Test-Case 'Context compression stops when a summary does not reduce tokens' {
    . (Join-Path $projectRoot 'scripts/AgentCore.ps1')
    . (Join-Path $projectRoot 'scripts/Logging.ps1')
    $contracts=Import-RoleContracts ([pscustomobject]@{});$task=Agent-NewTaskTemplate 'compression-test' $contracts
    $compressor=@($task.roles|Where-Object{$_.id -eq 'context_compressor'})[0]
    $probe=[pscustomobject]@{calls=0}
    $counter={param($Config,$Value)if($Value -is [string]){return [Math]::Max(1,[regex]::Matches($Value,'\S+').Count)};$json=$Value|ConvertTo-Json -Depth 20 -Compress;if($json -match 'oversized-marker' -and $json -notmatch 'Compress the input for role'){return 9000};return 20}.GetNewClosure()
    $completion={param($Config,$Request)$probe.calls++;return [pscustomobject]@{choices=@([pscustomobject]@{message=[pscustomobject]@{content='{"compressed_context":"oversized-marker one two","retained_facts":[],"open_items":[]}'}})}}.GetNewClosure()
    $dependencies=New-AgentDependencies -CountTokens $counter -SendCompletion $completion
    $config=[pscustomobject]@{override=[pscustomobject]@{context_size=8192;max_tokens=256};user_output_language='Japanese';resources_root='';resources_user='default-user';llm_input_format='json';json_pretty=$false;agent_common_prompt=''}
    $messages=@([pscustomobject]@{role='system';content='system'},[pscustomobject]@{role='user';content='oversized-marker one two'})
    $rejected=$false;try{$null=Agent-EnsureMessagesFit $config $messages 'planner' $compressor $dependencies}catch{$rejected=$_.Exception.Message -match '短縮できませんでした'}
    Assert-True ($rejected -and $probe.calls -eq 1) 'A non-reducing summary triggered repeated compressor calls instead of stopping with a diagnostic.'
}

Test-Case 'Configurable workflow, context compression, and command harness' {
    $core=Get-Content -LiteralPath (Join-Path (Join-Path $projectRoot 'scripts') 'AgentCore.ps1') -Raw -Encoding UTF8
    $roleExecution=Get-Content -LiteralPath (Join-Path (Join-Path $projectRoot 'scripts') 'AgentRoleExecution.ps1') -Raw -Encoding UTF8
    $stateModule=Get-Content -LiteralPath (Join-Path (Join-Path $projectRoot 'scripts') 'AgentState.ps1') -Raw -Encoding UTF8
    $workflow=Get-Content -LiteralPath (Join-Path (Join-Path $projectRoot 'scripts') 'AgentWorkflow.ps1') -Raw -Encoding UTF8
    $validation=Get-Content -LiteralPath (Join-Path (Join-Path $projectRoot 'scripts') 'AgentValidation.ps1') -Raw -Encoding UTF8
    $harness=Get-Content -LiteralPath (Join-Path (Join-Path $projectRoot 'scripts') 'AgentHarness.ps1') -Raw -Encoding UTF8
    $rules=Read-Json (Join-Path $projectRoot 'configs/agent-harness.json')
    Assert-True ($workflow -match 'Agent-ResolveTransition' -and $core -match 'AgentWorkflow\.ps1' -and $core -match 'AgentRoleExecution\.ps1' -and $core -match 'AgentState\.ps1' -and $core -match 'AgentValidation\.ps1' -and $roleExecution -match 'Agent-CompressContext' -and $stateModule -match 'Agent-ValidateState' -and $validation -match 'Agent-ValidateExecutionConfig') 'Workflow, role execution, state, or configuration validation rules are absent from their designated modules.'
    Assert-True ($harness -match 'Apply-AgentWorkspaceChanges' -and $harness -match 'arguments_regex' -and $rules.allowed_commands.Count -gt 0) 'Workspace diff or allowlisted command rules are missing.'
}

Test-Case 'Execution configuration rejects invalid values before workflow work' {
    . (Join-Path $projectRoot 'scripts/AgentCore.ps1')
    $valid=[pscustomobject]@{llm_input_format='json';json_indent=2;json_retry_limit=3;override=[pscustomobject]@{context_size=8192;max_tokens=512};context_compression=[pscustomobject]@{enabled=$true;trigger_tokens=5000;target_tokens=512;role_id='context_compressor'}}
    Agent-ValidateExecutionConfig $valid
    $badValues=@(
        [pscustomobject]@{llm_input_format='yaml';json_indent=2;json_retry_limit=3;override=$valid.override},
        [pscustomobject]@{llm_input_format='json';json_indent=9;json_retry_limit=3;override=$valid.override},
        [pscustomobject]@{llm_input_format='json';json_indent=2;json_retry_limit=-2;override=$valid.override},
        [pscustomobject]@{llm_input_format='json';json_indent=2;json_retry_limit=3;override=[pscustomobject]@{context_size=8192;max_tokens=0}}
    )
    foreach($bad in $badValues){$rejected=$false;try{Agent-ValidateExecutionConfig $bad}catch{$rejected=$true};Assert-True $rejected 'Invalid execution configuration was not rejected at the configuration boundary.'}
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

Test-Case 'KoboldCpp model sidecars do not override shared parameter settings' {
    . (Join-Path $projectRoot 'scripts/KoboldCppSettings.ps1')
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-no-sidecar-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    $modelPath=Join-Path $root 'Model With Spaces.gguf';$sidecarPath=[IO.Path]::ChangeExtension($modelPath,'.json')
    try{
        $settings=Read-Json (Join-Path $projectRoot 'configs/koboldcpp-settings.json')
        [IO.File]::WriteAllText($sidecarPath,'{"startup_parameters":[{"name":"threads","value":8},{"name":"usemlock","value":true}],"request_parameters":{"temperature":0.8,"max_tokens":512}}',[Text.UTF8Encoding]::new($false))
        $storeCalls=[System.Collections.Generic.List[string]]::new();$readJson={param($Path,$MaximumBytes)$storeCalls.Add('read');[IO.File]::ReadAllText($Path)|ConvertFrom-Json}.GetNewClosure();$writeJson={param($Path,$Value,$Depth)$storeCalls.Add('write');[IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Value -Depth $Depth),[Text.UTF8Encoding]::new($false))}.GetNewClosure();$store=New-AtaraxiaJsonFileStoreDependencies -ReadJson $readJson -WriteJson $writeJson
        $settings.request_parameters.temperature=0.55;$effective=Get-KoboldCppEffectiveSettings $settings
        Assert-True ($effective.request_parameters.temperature -eq 0.55 -and $effective.startup_parameters.Count -eq $settings.startup_parameters.Count -and $storeCalls.Count -eq 0) 'The same-stem JSON sidecar was read or changed global model settings.'
        $arguments=Get-KoboldCppLaunchArguments $effective $modelPath
        Assert-True ($arguments -contains '--contextsize' -and $arguments -contains '8192' -and ($arguments -join ' ') -match '"[^"]*Model With Spaces\.gguf"') 'Launch argument generation lost shared context size or quoted model path.'
        $savedPath=Join-Path $root 'settings.json';Save-KoboldCppSettings $savedPath $settings $store;$saved=Read-AtaraxiaJsonStoreFile $savedPath $store
        Assert-True ($saved.request_parameters.context_size -eq 8192 -and $storeCalls -contains 'write') 'KoboldCpp settings saving bypassed the injected JSON store.'
    }finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}

Test-Case 'Model parameter presets migrate and support isolated CRUD and switching' {
    . (Join-Path $projectRoot 'scripts/GuiModelParameters.ps1');. (Join-Path $projectRoot 'scripts/ModelParameterPresets.ps1')
    $settings=[pscustomobject]@{request_parameters=[pscustomobject]@{context_size=8192;temperature=0.7;max_tokens=512;stop=@('END')}}
    Initialize-AtaraxiaModelParameterPresets $settings|Out-Null
    Assert-True ($settings.parameter_presets.Count -eq 1 -and $settings.active_parameter_preset_id -eq 'default' -and $settings.parameter_presets[0].request_parameters.temperature -eq 0.7 -and $settings.request_parameters.context_size -eq 8192) 'Initial preset migration lost existing shared parameter values.'
    New-AtaraxiaModelParameterPreset $settings 'Creative' 'preset-creative'|Out-Null
    Assert-True ($settings.active_parameter_preset_id -eq 'preset-creative' -and $settings.parameter_presets.Count -eq 2 -and $settings.request_parameters.temperature -eq 0.7) 'Creating a preset did not select it or copy the current values.'
    $duplicateRejected=$false;try{New-AtaraxiaModelParameterPreset $settings 'creative' 'preset-duplicate'|Out-Null}catch{$duplicateRejected=$true};Assert-True $duplicateRejected 'Preset names were not enforced as unique.'
    Save-AtaraxiaModelParameterPresetValues $settings 'preset-creative' ([ordered]@{temperature=1.25;max_tokens=768;top_p=0.9;top_k=40;presence_penalty=0.0;frequency_penalty=0.0;repetition_penalty=1.0;seed=-1;stop=@('STOP')})|Out-Null
    Assert-True ($settings.request_parameters.temperature -eq 1.25 -and $settings.parameter_presets[1].request_parameters.temperature -eq 1.25 -and $settings.request_parameters.context_size -eq 8192) 'Saving preset values did not update the active request or preserve hidden shared values.'
    $beforeInvalidSave=ConvertTo-Json -InputObject $settings -Depth 60 -Compress;$invalidPresetSaveRejected=$false
    try{Save-AtaraxiaModelParameterPresetValues $settings 'preset-creative' ([ordered]@{temperature=1.5;top_p=1.5})|Out-Null}catch{$invalidPresetSaveRejected=$true}
    Assert-True ($invalidPresetSaveRejected -and (ConvertTo-Json -InputObject $settings -Depth 60 -Compress) -ceq $beforeInvalidSave) 'A preset value validation failure partially changed the active or stored preset.'
    Rename-AtaraxiaModelParameterPreset $settings 'preset-creative' 'Creative v2'|Out-Null
    Select-AtaraxiaModelParameterPreset $settings 'default'|Out-Null
    Assert-True ($settings.request_parameters.temperature -eq 0.7 -and $settings.active_parameter_preset_id -eq 'default') 'Selecting a preset did not restore its saved values.'
    Remove-AtaraxiaModelParameterPreset $settings 'default'|Out-Null
    Assert-True ($settings.active_parameter_preset_id -eq 'preset-creative' -and $settings.request_parameters.temperature -eq 1.25 -and $settings.parameter_presets.Count -eq 1) 'Deleting the active preset did not select and apply the remaining preset.'
    $lastRejected=$false;try{Remove-AtaraxiaModelParameterPreset $settings 'preset-creative'|Out-Null}catch{$lastRejected=$true};Assert-True $lastRejected 'The final preset was deleted.'
}

Test-Case 'Model parameter presets reject malformed and duplicate structures' {
    . (Join-Path $projectRoot 'scripts/GuiModelParameters.ps1');. (Join-Path $projectRoot 'scripts/ModelParameterPresets.ps1');. (Join-Path $projectRoot 'scripts/JsonFileStore.ps1')
    $base=[pscustomobject]@{request_parameters=[pscustomobject]@{temperature=0.7}}
    $cases=@(
        [pscustomobject]@{parameter_presets=@([pscustomobject]@{id='x';name='One';request_parameters=[pscustomobject]@{temperature=0.5}},[pscustomobject]@{id='x';name='Two';request_parameters=[pscustomobject]@{temperature=0.6}})},
        [pscustomobject]@{parameter_presets=@([pscustomobject]@{id='x';name='One';request_parameters=[pscustomobject]@{temperature=0.5}},[pscustomobject]@{id='y';name='one';request_parameters=[pscustomobject]@{temperature=0.6}})},
        [pscustomobject]@{parameter_presets=@([pscustomobject]@{id='x';name='One';request_parameters='invalid'})},
        [pscustomobject]@{parameter_presets=@([pscustomobject]@{id='x';name="Bad`nName";request_parameters=[pscustomobject]@{temperature=0.5}})}
    )
    foreach($presetData in $cases){$settings=[pscustomobject]@{request_parameters=[pscustomobject]@{temperature=0.7};parameter_presets=$presetData.parameter_presets;active_parameter_preset_id='x'};$rejected=$false;try{Initialize-AtaraxiaModelParameterPresets $settings|Out-Null}catch{$rejected=$true};Assert-True $rejected 'Malformed or duplicate preset data was accepted.'}
    $missing=[pscustomobject]@{request_parameters='invalid'};$rejected=$false;try{Initialize-AtaraxiaModelParameterPresets $missing|Out-Null}catch{$rejected=$true};Assert-True $rejected 'Non-object request_parameters was accepted during migration.'
    $settings=[pscustomobject]@{request_parameters=[pscustomobject]@{temperature=0.7}};Initialize-AtaraxiaModelParameterPresets $settings|Out-Null;$before=ConvertTo-Json -InputObject $settings -Depth 60 -Compress;$writes=[pscustomobject]@{count=0};$failedWriter={param($Path,$Value,$Depth)$writes.count++;throw 'preset store unavailable'}.GetNewClosure();$store=New-AtaraxiaJsonFileStoreDependencies -WriteJson $failedWriter;$saveFailed=$false
    try{$null=Save-AtaraxiaUserModelParameterPresetData 'unused.json' $settings $store}catch{$saveFailed=$true}
    Assert-True ($saveFailed -and $writes.count -eq 1 -and (ConvertTo-Json -InputObject $settings -Depth 60 -Compress) -ceq $before) 'A failed user preset write changed model settings or appeared successful.'
}

Test-Case 'Built-in model preset catalog is Git-managed and personal presets stay separate' {
    . (Join-Path $projectRoot 'scripts/GuiModelParameters.ps1');. (Join-Path $projectRoot 'scripts/ModelParameterPresets.ps1')
    $catalogPath=Join-Path $projectRoot 'configs/model-parameter-presets.json'
    Assert-True (Test-Path -LiteralPath $catalogPath -PathType Leaf) 'Git-managed built-in model preset catalog is missing.'
    $catalog=Read-Json $catalogPath
    foreach($family in @('Qwen','Llama','Gemma','Mistral','DeepSeek')){Assert-True (@($catalog.presets|Where-Object{[string]$_.family -eq $family}).Count -gt 0) "The built-in catalog has no $family preset."}
    $requiredParameters=@('context_size','max_tokens','temperature','top_p','top_k','presence_penalty','frequency_penalty','repetition_penalty','seed','stop')
    foreach($preset in $catalog.presets){$uri=$null;Assert-True (-not [string]::IsNullOrWhiteSpace([string]$preset.name_en) -and -not [string]::IsNullOrWhiteSpace([string]$preset.purpose) -and @($preset.model_examples).Count -gt 0 -and [uri]::TryCreate([string]$preset.source_url,[UriKind]::Absolute,[ref]$uri) -and $uri.Scheme -eq 'https') "Built-in preset $($preset.id) is missing its bilingual description or official source.";foreach($key in $requiredParameters){Assert-True ($null -ne $preset.request_parameters.PSObject.Properties[$key]) "Built-in preset $($preset.id) is missing $key."};Assert-True ($preset.request_parameters.context_size -eq 8192 -and $preset.request_parameters.max_tokens -eq 2048) "Built-in preset $($preset.id) must use the documented conservative context/token baseline."}
    $settings=[pscustomobject]@{request_parameters=[pscustomobject]@{context_size=8192;max_tokens=1024;temperature=0.7;top_p=0.9;top_k=40;presence_penalty=0;frequency_penalty=0;repetition_penalty=1;seed=-1;stop=@()}}
    $userData=[pscustomobject]@{schema_version=1;active_preset_id='qwen3_5_instruct_general';presets=@([pscustomobject]@{id='user-private';name='My Preset';request_parameters=[pscustomobject]@{temperature=0.4;top_p=0.85;top_k=30;presence_penalty=0;frequency_penalty=0;repetition_penalty=1;seed=-1;stop=@()}});overrides=@()}
    Initialize-AtaraxiaModelParameterPresetCatalog $settings $catalog.presets $userData|Out-Null
    Assert-True (@($settings.parameter_presets|Where-Object{[string]$_.id -eq 'user-private' -and $_.origin -eq 'user'}).Count -eq 1) 'User preset was not merged as a user-owned preset.'
    Assert-True (@($settings.parameter_presets|Where-Object{[string]$_.id -eq 'qwen3_5_instruct_general' -and $_.origin -eq 'builtin'}).Count -eq 1) 'Built-in preset was not marked as Git-managed.'
    $builtinBefore=ConvertTo-Json -InputObject $settings -Depth 60 -Compress;$builtinSaveRejected=$false;try{Save-AtaraxiaModelParameterPresetValues $settings 'qwen3_5_instruct_general' ([ordered]@{temperature=0.5})|Out-Null}catch{$builtinSaveRejected=$true}
    $builtinDeleteRejected=$false;try{Remove-AtaraxiaModelParameterPreset $settings 'qwen3_5_instruct_general'|Out-Null}catch{$builtinDeleteRejected=$true}
    $builtinActions=Get-AtaraxiaModelParameterPresetCapabilities (Get-AtaraxiaModelParameterPreset $settings 'qwen3_5_instruct_general');$userActions=Get-AtaraxiaModelParameterPresetCapabilities (Get-AtaraxiaModelParameterPreset $settings 'user-private')
    Assert-True ($builtinSaveRejected -and $builtinDeleteRejected -and (ConvertTo-Json -InputObject $settings -Depth 60 -Compress) -ceq $builtinBefore -and -not $builtinActions.can_overwrite -and -not $builtinActions.can_delete -and $builtinActions.can_save_as -and $userActions.can_overwrite -and $userActions.can_delete) 'Built-in presets allowed overwrite/deletion, changed state after rejection, or did not expose the expected action capabilities.'
    Rename-AtaraxiaModelParameterPreset $settings 'user-private' 'Updated private'|Out-Null
    Remove-AtaraxiaModelParameterPreset $settings 'user-private'|Out-Null
    Assert-True (@($settings.parameter_presets|Where-Object{$_.origin -eq 'builtin'}).Count -eq @($catalog.presets).Count) 'Mutating user presets modified or removed built-in presets.'
    $path=Get-AtaraxiaUserModelParameterPresetPath (Join-Path ([IO.Path]::GetTempPath()) 'ataraxia-profile')
    Assert-True ($path -match 'ataraxia-profile' -and $path -match 'model-parameter-presets\.json') 'User presets are not routed to a separate user data directory.'
}

Test-Case 'KoboldCpp import migrates presets to user storage and keeps settings clean' {
    . (Join-Path $projectRoot 'scripts/KoboldCppSettings.ps1')
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-preset-migration-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $root -Force|Out-Null
    $settingsPath=Join-Path $root 'kobold-settings.json';$configPath=Join-Path $root 'config.json';$oldDataDirectory=$env:ATARAXIA_USER_DATA_DIRECTORY;$env:ATARAXIA_USER_DATA_DIRECTORY=Join-Path $root 'user'
    try{
        $currentParameters=[pscustomobject]@{context_size=8192;max_tokens=1024;temperature=0.3;top_p=0.9;top_k=40;presence_penalty=0;frequency_penalty=0;repetition_penalty=1;seed=-1;stop=@()}
        $settings=[pscustomobject][ordered]@{server=[pscustomobject]@{host='127.0.0.1';port=5001;generate_path='/v1/chat/completions'};paths=[pscustomobject]@{install_directory='runtime';model_directory='models';model_file='';executable='koboldcpp.exe'};startup_parameters=@();request_parameters=$currentParameters;parameter_presets=@([pscustomobject]@{id='old-creative';name='Old Creative';request_parameters=$currentParameters});active_parameter_preset_id='old-creative';release_tag='';sha256=''}
        [IO.File]::WriteAllText($settingsPath,(ConvertTo-Json -InputObject $settings -Depth 60),[Text.UTF8Encoding]::new($false))
        $config=[pscustomobject]@{koboldcpp_settings_path=$settingsPath};$loaded=Import-KoboldCppSettings $config $configPath
        Assert-True ($loaded.parameter_presets.Count -ge 8 -and $loaded.parameter_presets[0].origin -eq 'builtin') 'Git-managed defaults and the migrated current-value preset were not combined.'
        $userPath=Get-AtaraxiaUserModelParameterPresetPath;Assert-True (Test-Path -LiteralPath $userPath -PathType Leaf) 'Legacy values were not migrated to user storage.'
        $migrated=Read-Json $userPath;Assert-True (@($migrated.presets|Where-Object{$_.name -eq 'Old Creative' -and $_.request_parameters.temperature -eq 0.3}).Count -eq 1) 'A legacy user-created preset was not migrated to user storage.'
        $preset=New-AtaraxiaModelParameterPreset $loaded 'Personal only' 'personal-only';Save-AtaraxiaUserModelParameterPresetData $userPath $loaded|Out-Null;Save-KoboldCppSettings $settingsPath $loaded
        $savedSettings=Read-Json $settingsPath;$savedUserData=Read-Json $userPath
        Assert-True ($null -eq $savedSettings.PSObject.Properties['parameter_presets'] -and $null -eq $savedSettings.PSObject.Properties['user_preset_data']) 'Personal presets leaked back into the Git-managed shared settings file.'
        Assert-True (@($savedUserData.presets|Where-Object{$_.id -eq 'personal-only'}).Count -eq 1) 'A user-created preset was not saved to the user-data JSON.'
        $activeId=[string]$loaded.active_parameter_preset_id;Save-AtaraxiaModelParameterPresetValues $loaded $activeId ([ordered]@{temperature=0.45})|Out-Null
        $loaded.user_preset_data|Add-Member -NotePropertyName pending_shared_settings -NotePropertyValue ([pscustomobject]@{schema_version=1;request_parameters=(Copy-AtaraxiaModelParameterPresetValue $loaded.request_parameters)}) -Force
        Save-AtaraxiaUserModelParameterPresetData $userPath $loaded|Out-Null
        $loaded.request_parameters.temperature=0.3;Save-KoboldCppSettings $settingsPath $loaded
        $reloaded=Import-KoboldCppSettings ([pscustomobject]@{koboldcpp_settings_path=$settingsPath}) $configPath
        $afterRecovery=Read-Json $settingsPath;$afterRecoveryUser=Read-Json $userPath
        Assert-True ($reloaded.request_parameters.temperature -eq 0.45 -and $afterRecovery.request_parameters.temperature -eq 0.45 -and $null -eq $afterRecoveryUser.PSObject.Properties['pending_shared_settings']) 'KoboldCpp import did not replay and clear the persisted shared-settings recovery journal.'
    }finally{if([string]::IsNullOrWhiteSpace($oldDataDirectory)){Remove-Item Env:ATARAXIA_USER_DATA_DIRECTORY -ErrorAction SilentlyContinue}else{$env:ATARAXIA_USER_DATA_DIRECTORY=$oldDataDirectory};Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}

Test-Case 'KoboldCpp automatic build choice uses injected GPU names and falls back on probe errors' {
    . (Join-Path $projectRoot 'scripts/KoboldCppSettings.ps1')
    . (Join-Path $projectRoot 'scripts/adapters/WindowsHardwareInfoAdapter.ps1')
    $readNames={@('NVIDIA GeForce RTX')};$hardware=New-AtaraxiaWindowsHardwareInfoDependencies $readNames
    $cuda=Get-KoboldCppBuildSelection 'auto' $hardware.get_video_controller_names
    Assert-True ($cuda.build -eq 'cuda' -and $cuda.detection_succeeded -and $cuda.video_controller_names[0] -eq 'NVIDIA GeForce RTX') 'Injected NVIDIA hardware did not select the CUDA build.'
    $failingHardware=New-AtaraxiaWindowsHardwareInfoDependencies {throw 'simulated CIM failure'}
    $fallback=Get-KoboldCppBuildSelection 'auto' $failingHardware.get_video_controller_names
    Assert-True ($fallback.build -eq 'nocuda' -and -not $fallback.detection_succeeded -and $fallback.video_controller_names.Count -eq 0) 'Unavailable hardware information did not select the no-CUDA fallback.'
    $notCalled=[System.Collections.Generic.List[string]]::new();$explicitReader={ $notCalled.Add('called');throw 'must not query for explicit build' }.GetNewClosure();$explicit=Get-KoboldCppBuildSelection 'oldpc' $explicitReader
    Assert-True ($explicit.build -eq 'oldpc' -and $explicit.detection_succeeded -and $notCalled.Count -eq 0) 'An explicit build override queried hardware or changed its selected build.'
}

Test-Case 'KoboldCpp installer verifies release downloads and always removes failed staging files' {
    . (Join-Path $projectRoot 'scripts/Localization.ps1')
    . (Join-Path $projectRoot 'scripts/KoboldCppInstaller.ps1')
    $bytes=[Text.Encoding]::UTF8.GetBytes('verified executable bytes');$sha=[Security.Cryptography.SHA256]::HashData($bytes);$hash=[BitConverter]::ToString($sha).Replace('-','').ToLowerInvariant()
    $staged=@{};$calls=[System.Collections.Generic.List[string]]::new()
    $getRelease={param($Uri)$calls.Add('release');[pscustomobject]@{tag_name='v-test';assets=@([pscustomobject]@{name='koboldcpp-nocuda.exe';browser_download_url='https://example.test/asset';digest="sha256:$hash"})}}.GetNewClosure()
    $download={param($Uri,$Path)$calls.Add('download');$staged[$Path]=$bytes}.GetNewClosure()
    $ensure={param($Path)$calls.Add('ensure')}.GetNewClosure();$test={param($Path)$staged.ContainsKey($Path)}.GetNewClosure();$getHash={param($Path)[BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([byte[]]$staged[$Path])).Replace('-','').ToLowerInvariant()}.GetNewClosure();$delete={param($Path)$calls.Add('delete');$staged.Remove($Path)|Out-Null}.GetNewClosure();$move={param($Source,$Destination)$calls.Add('move');$staged[$Destination]=$staged[$Source];$staged.Remove($Source)|Out-Null}.GetNewClosure()
    $dependencies=New-KoboldCppInstallerDependencies $getRelease $download $ensure $test $getHash $delete $move
    $release=Get-KoboldCppRelease $dependencies 'https://example.test/releases/latest';$asset=Get-KoboldCppReleaseAsset $release 'nocuda';$destination=Join-Path ([IO.Path]::GetTempPath()) 'koboldcpp-test.exe'
    $installed=Install-KoboldCppReleaseAsset $asset $destination $dependencies
    Assert-True ($installed -eq $hash -and $test.Invoke($destination) -and -not $test.Invoke($destination+'.download') -and $calls -contains 'move') 'A verified release asset was not placed or temporary download remained.'
    $badAsset=[pscustomobject]@{browser_download_url='https://example.test/bad';digest=('sha256:'+('0'*64))};$bad=$false;try{$null=Install-KoboldCppReleaseAsset $badAsset $destination $dependencies}catch{$bad=$true}
    Assert-True ($bad -and -not $test.Invoke($destination+'.download') -and $calls[$calls.Count-1] -eq 'delete') 'Digest mismatch did not reject and clean up the staged file.'
    $partialDownload={param($Uri,$Path)$staged[$Path]=[byte[]]@(1,2,3);throw 'simulated interrupted download'}.GetNewClosure();$partialDependencies=New-KoboldCppInstallerDependencies $getRelease $partialDownload $ensure $test $getHash $delete $move;$interrupted=$false;try{$null=Install-KoboldCppReleaseAsset $asset $destination $partialDependencies}catch{$interrupted=$true}
    Assert-True ($interrupted -and -not $test.Invoke($destination+'.download')) 'Interrupted download left a partial staging file behind.'
}

Test-Case 'KoboldCpp startup uses injected process endpoint clock and sleep adapters' {
    . (Join-Path $projectRoot 'scripts/Localization.ps1')
    . (Join-Path $projectRoot 'scripts/KoboldCppInstaller.ps1')
    $clock=[pscustomobject]@{now=[DateTime]::SpecifyKind([DateTime]::new(2026,1,1),[DateTimeKind]::Utc);probes=0;sleeps=0;ready_after=2;exited=$false;starts=0}
    $start={param($Executable,$Arguments,$Directory)$clock.starts++;[pscustomobject]@{id='fake-kobold'}}.GetNewClosure()
    $state={param($Process)[pscustomobject]@{has_exited=[bool]$clock.exited;exit_code=17}}.GetNewClosure()
    $endpoint={param($HostName,$Port,$Timeout)$clock.probes++;return ($clock.probes -ge $clock.ready_after)}.GetNewClosure()
    $sleep={param($Seconds)$clock.sleeps++;$clock.now=$clock.now.AddSeconds($Seconds)}.GetNewClosure()
    $now={return $clock.now}.GetNewClosure()
    $dependencies=New-KoboldCppInstallerDependencies -StartProcess $start -GetProcessState $state -TestEndpoint $endpoint -Sleep $sleep -UtcNow $now
    $result=Start-KoboldCppAndWait 'kobold.exe' '--model model.gguf' 'C:\kobold' ([uri]'http://127.0.0.1:5001') $dependencies 5 500 1
    Assert-True ($result.ready -and $result.process.id -eq 'fake-kobold' -and $clock.starts -eq 1 -and $clock.sleeps -eq 1) 'KoboldCpp startup did not start once, probe, and wait through injected adapters.'
    $clock.probes=0;$clock.sleeps=0;$clock.ready_after=99;$timeout=$false;try{$null=Start-KoboldCppAndWait 'kobold.exe' '--model model.gguf' 'C:\kobold' ([uri]'http://127.0.0.1:5001') $dependencies 2 500 1}catch{$timeout=$_.Exception.Message -match 'timed out|timeout|起動|接続'}
    Assert-True ($timeout -and $clock.sleeps -eq 2) 'KoboldCpp startup timeout did not use the injected clock and sleep.'
    $clock.probes=0;$clock.sleeps=0;$clock.exited=$true;$exitRejected=$false;try{$null=Start-KoboldCppAndWait 'kobold.exe' '--model model.gguf' 'C:\kobold' ([uri]'http://127.0.0.1:5001') $dependencies 5 500 1}catch{$exitRejected=$_.Exception.Message -match '17'}
    Assert-True ($exitRejected -and $clock.sleeps -eq 0) 'An exited process was not reported before waiting again.'
}

Test-Case 'GUI themes provide modern portable light and dark palettes' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'GuiTheme.ps1')
    . (Join-Path (Join-Path $projectRoot 'scripts') 'GuiThemeApplication.ps1')
    $themeSource=Get-Content (Join-Path $projectRoot 'scripts/GuiTheme.ps1') -Raw
    Assert-True ($themeSource -notmatch 'HKCU:|Get-ItemProperty') 'GUI theme application model reads the Windows registry directly.'
    Assert-True ($themeSource -notmatch '#[0-9A-Fa-f]{6}') 'GUI theme color values remain hard-coded in the theme model instead of the JSON palette.'
    $themeJson=Read-Json (Join-Path $projectRoot 'configs/gui-themes.json')
    Assert-True ([int]$themeJson.schema_version -eq 1 -and ((@($themeJson.themes.PSObject.Properties.Name|Sort-Object)) -join ',') -ceq 'dark,light') 'Theme palette JSON does not contain the versioned light/dark structure.'
    $invalidThemeJson=Read-Json (Join-Path $projectRoot 'configs/gui-themes.json');$invalidThemeJson.themes.light.surface='white';$invalidThemeRejected=$false
    try{$null=Get-AtaraxiaThemePalette $invalidThemeJson 'light'}catch{$invalidThemeRejected=$true}
    Assert-True $invalidThemeRejected 'A malformed JSON theme color was accepted.'
    $unexpectedThemeJson=Read-Json (Join-Path $projectRoot 'configs/gui-themes.json');Add-Member -InputObject $unexpectedThemeJson -MemberType NoteProperty -Name unexpected -Value $true;$unexpectedThemeRejected=$false
    try{$null=Get-AtaraxiaThemePalette $unexpectedThemeJson 'dark'}catch{$unexpectedThemeRejected=$true}
    Assert-True $unexpectedThemeRejected 'An unknown root property in the theme JSON was accepted.'
    . (Join-Path $projectRoot 'scripts/adapters/WindowsSystemThemeAdapter.ps1')
    $readPreference={0};Assert-True ((Get-AtaraxiaWindowsSystemTheme $readPreference) -eq 'dark') 'Windows system theme adapter did not map the dark preference.'
    $readPreference={1};Assert-True ((Get-AtaraxiaWindowsSystemTheme $readPreference) -eq 'light') 'Windows system theme adapter did not map the light preference.'
    $readPreference={2};Assert-True ((Get-AtaraxiaWindowsSystemTheme $readPreference) -eq 'light') 'Windows system theme adapter did not fall back safely for an unknown preference.'
    $readPreference={throw 'Registry unavailable'};Assert-True ((Get-AtaraxiaWindowsSystemTheme $readPreference) -eq 'light') 'Windows system theme adapter did not fall back when the system preference could not be read.'
    $config=Read-Json (Join-Path $projectRoot 'configs/config.example.json')
    Assert-True ($config.gui_theme -eq 'system') 'System theme is not the default preference.'
    foreach($mode in @('light','dark')){
        $palette=Get-AtaraxiaThemePalette $guiThemeDefinitions $mode
        foreach($property in $palette.PSObject.Properties){$rgb=[string]$property.Value;if($rgb -notmatch '^#[0-9A-Fa-f]{6}$'){throw "Theme color is not a portable hex color: $mode/$($property.Name)=$rgb"}}
        foreach($property in $palette.PSObject.Properties){$color=[string]$property.Value;Assert-True ($color.Substring(1,2) -eq $color.Substring(3,2) -and $color.Substring(3,2) -eq $color.Substring(5,2)) "Theme color is not achromatic: $mode/$($property.Name)=$color"}
        $contrast=Get-AtaraxiaContrastRatio $palette.primary_text $palette.app_background
        Assert-True ($contrast -ge 7) "Theme text contrast is too low: $mode/$contrast"
        $surfaceContrast=Get-AtaraxiaContrastRatio $palette.primary_text $palette.surface
        $secondaryContrast=Get-AtaraxiaContrastRatio $palette.secondary_text $palette.surface
        Assert-True ($surfaceContrast -ge 7 -and $secondaryContrast -ge 4.5) "Theme input text contrast is too low: $mode/$surfaceContrast/$secondaryContrast"
        foreach($key in @('icon','accent_text')){$color=[string]$palette.$key;Assert-True ($color.Substring(1,2) -eq $color.Substring(3,2) -and $color.Substring(3,2) -eq $color.Substring(5,2)) "Theme $key brush is not achromatic: $mode/$color"}
        $accent=[string]$palette.accent
        Assert-True ($accent.Substring(1,2) -eq $accent.Substring(3,2) -and $accent.Substring(3,2) -eq $accent.Substring(5,2)) "Theme accent is not achromatic: $mode/$accent"
    }
    Assert-True ((Resolve-AtaraxiaThemeMode 'system' 'dark') -eq 'dark' -and (Resolve-AtaraxiaThemeMode 'light' 'dark') -eq 'light') 'Theme preference does not resolve system and explicit modes.'
    $initial=New-AtaraxiaGuiThemeState
    Assert-True ($initial.preference -eq 'system' -and $initial.effective -eq '') 'GUI theme state did not initialize with a system preference and no applied theme.'
    $loaded=Set-AtaraxiaGuiThemeState $initial 'dark' 'light'
    Assert-True ($loaded.state.preference -eq 'dark' -and $loaded.state.effective -eq 'dark' -and $loaded.apply_theme) 'Explicit theme preference was not resolved into a state transition.'
    $systemChange=Set-AtaraxiaGuiThemeState $loaded.state 'system' 'light'
    Assert-True ($systemChange.state.effective -eq 'light' -and $systemChange.apply_theme -and $systemChange.sync_selector) 'System theme transition did not request UI updates.'
    $same=Set-AtaraxiaGuiThemeState $systemChange.state 'light' 'dark'
    Assert-True (-not $same.apply_theme -and $same.sync_selector -and $same.state.effective -eq 'light') 'Preference change with the same effective theme requested unnecessary palette application.'
    $invalid=Set-AtaraxiaGuiThemeState $same.state 'neon' 'dark'
    Assert-True (-not $invalid.accepted -and $invalid.state.preference -eq 'light' -and $invalid.state.effective -eq 'light') 'Invalid theme preference mutated GUI theme state.'
    $persisted=[System.Collections.Generic.List[string]]::new();$persist={param($Preference)$persisted.Add($Preference)}.GetNewClosure()
    $savedTransition=Invoke-AtaraxiaGuiThemePreferenceSave $same.state 'dark' 'light' $persist
    Assert-True ($savedTransition.state.preference -eq 'dark' -and $persisted.Count -eq 1 -and $persisted[0] -eq 'dark' -and $same.state.preference -eq 'light') 'Theme preference state was not committed after the injected persistence succeeded.'
    $failedPersist={param($Preference)throw 'disk full'};$saveRejected=$false
    try{$null=Invoke-AtaraxiaGuiThemePreferenceSave $same.state 'dark' 'light' $failedPersist}catch{$saveRejected=$_.Exception.Message -match 'disk full'}
    Assert-True ($saveRejected -and $same.state.preference -eq 'light' -and $same.state.effective -eq 'light') 'A failed theme persistence changed the committed theme state or hid the storage error.'
    . (Join-Path $projectRoot 'scripts/adapters/WpfThemeAdapter.ps1');$resources=@{};$brushFactory={param($Color)[pscustomobject]@{color=$Color}};Set-AtaraxiaWpfThemeResources $resources (Get-AtaraxiaThemePalette $guiThemeDefinitions 'dark') $brushFactory
    Assert-True ($resources.AppBackgroundBrush.color -eq (Get-AtaraxiaThemePalette $guiThemeDefinitions 'dark').app_background -and $resources.PrimaryTextBrush.color -eq (Get-AtaraxiaThemePalette $guiThemeDefinitions 'dark').primary_text -and $resources.IconBrush.color -eq (Get-AtaraxiaThemePalette $guiThemeDefinitions 'dark').icon -and $resources.Count -eq 10) 'Theme adapter did not map the pure palette to all UI resource keys.'
    $missingPaletteRejected=$false;try{Set-AtaraxiaWpfThemeResources @{} ([pscustomobject]@{surface='#FFFFFF'}) $brushFactory}catch{$missingPaletteRejected=$true};Assert-True $missingPaletteRejected 'WPF theme adapter accepted an incomplete palette.'
    $modelAdapter=Get-Content (Join-Path $projectRoot 'scripts/adapters/WpfModelParameterAdapter.ps1') -Raw
    $dialogAdapter=Get-Content (Join-Path $projectRoot 'scripts/adapters/WpfDialogAdapter.ps1') -Raw
    $drawerAdapter=Get-Content (Join-Path $projectRoot 'scripts/adapters/WpfProjectDrawerAdapter.ps1') -Raw
    Assert-True ($modelAdapter -match "SetResourceReference\(\[Windows\.Controls\.Control\]::BackgroundProperty,'SurfaceBrush'\)" -and $modelAdapter -match "SetResourceReference\(\[Windows\.Controls\.Control\]::ForegroundProperty,'PrimaryTextBrush'\)" -and $modelAdapter -match "SetResourceReference\(\[Windows\.Controls\.Control\]::BorderBrushProperty,'BorderBrush'\)" -and $modelAdapter -notmatch '\$input\.Background=\$Owner\.Resources') 'Model parameter text fields capture stale theme brushes instead of tracking the active palette.'
    Assert-True ($dialogAdapter -match "SetResourceReference\(\[Windows\.Controls\.Control\]::BackgroundProperty,'SurfaceBrush'\)" -and $dialogAdapter -match "SetResourceReference\(\[Windows\.Controls\.Control\]::ForegroundProperty,'PrimaryTextBrush'\)" -and $dialogAdapter -notmatch '\$input\.Background=\$Owner\.Resources') 'Dialog inputs capture stale theme brushes instead of tracking the active palette.'
    Assert-True ($drawerAdapter -match "SetResourceReference\(\[Windows\.Controls\.Control\]::BackgroundProperty,'PanelBrush'\)" -and $drawerAdapter -match "SetResourceReference\(\[Windows\.Controls\.Control\]::ForegroundProperty,'PrimaryTextBrush'\)") 'Project and session drawer controls do not track theme resources dynamically.'
}

Test-Case 'GUI model parameter definitions enforce editable valid ranges' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'GuiModelParameters.ps1')
    $definitions=Get-AtaraxiaModelParameterDefinitions
    Assert-True (@($definitions|Where-Object{$_.key -eq 'max_tokens'}).Count -eq 1) 'Maximum response tokens have no editable definition.'
    Assert-True (@($definitions|Where-Object{$_.key -eq 'temperature'}).Count -eq 1) 'Temperature has no editable definition.'
    foreach($d in $definitions|Where-Object{$_.kind -eq 'number'}){Assert-True ($d.min -lt $d.max -and $d.step -gt 0) "Invalid control range for $($d.key)."}
    foreach($case in @(@{key='temperature';value=-0.1},@{key='max_tokens';value=0},@{key='top_p';value=1.1})){try{Assert-AtaraxiaModelParameterValue $case.key $case.value;throw "Invalid value accepted for $($case.key)."}catch{if($_.Exception.Message -like 'Invalid value accepted*'){throw}}}
    Assert-True ((Assert-AtaraxiaModelParameterValue 'temperature' 0.7) -eq 0.7) 'Valid temperature was rejected.'
    foreach($d in $definitions){Assert-True (-not [string]::IsNullOrWhiteSpace([string]$d.help_key)) "Parameter $($d.key) has no help text key."}
    foreach($d in $definitions){Assert-True ($null -eq $d.PSObject.Properties['label_key']) "GUI label for $($d.key) must use its API key directly."}
    $expectedSliderSteps=@{max_tokens=256.0;temperature=0.1;top_p=0.05;top_k=10.0;presence_penalty=0.2;frequency_penalty=0.2;repetition_penalty=0.1}
    foreach($d in $definitions|Where-Object{$_.kind -eq 'number' -and $_.key -ne 'seed'}){Assert-True ($d.slider_step -eq $expectedSliderSteps[$d.key] -and $d.slider_step -ge $d.step) "Invalid coarse slider step for $($d.key)."}
    $seedDefinition=@($definitions|Where-Object{$_.key -eq 'seed'})[0];Assert-True ($null -eq $seedDefinition.slider_step -and $seedDefinition.input_width -ge 100) 'Seed must omit its slider and reserve room for all digits.'
    $stepRejected=$false;try{Assert-AtaraxiaModelParameterValue 'temperature' 0.705|Out-Null}catch{$stepRejected=$true};Assert-True $stepRejected 'Temperature step restriction was not enforced.'
}

Test-Case 'GUI model parameter spin values respect each step and limit' {
    . (Join-Path $projectRoot 'scripts/GuiModelParameters.ps1')
    foreach($definition in Get-AtaraxiaModelParameterDefinitions|Where-Object{$_.kind -eq 'number'}){
        $up=Get-AtaraxiaModelParameterStepValue $definition.key $definition.min 1
        $down=Get-AtaraxiaModelParameterStepValue $definition.key $definition.max -1
        $minimum=Get-AtaraxiaModelParameterStepValue $definition.key $definition.min -1
        $maximum=Get-AtaraxiaModelParameterStepValue $definition.key $definition.max 1
        Assert-True ([math]::Abs($up-($definition.min+$definition.step)) -lt 0.000001) "Spin-up used an incorrect step for $($definition.key)."
        Assert-True ([math]::Abs($down-($definition.max-$definition.step)) -lt 0.000001) "Spin-down used an incorrect step for $($definition.key)."
        Assert-True ($minimum -eq $definition.min -and $maximum -eq $definition.max) "Spinner exceeded the configured bounds for $($definition.key)."
        $null=Assert-AtaraxiaModelParameterValue $definition.key $up;$null=Assert-AtaraxiaModelParameterValue $definition.key $down
    }
    $directionRejected=$false;try{$null=Get-AtaraxiaModelParameterStepValue 'temperature' 0.5 0}catch{$directionRejected=$true};Assert-True $directionRejected 'Spinner accepted a direction other than one step up or down.'
}

Test-Case 'Model selection paths and slider properties support Windows PowerShell 5.1' {
    . (Join-Path $projectRoot 'scripts/GuiModelParameters.ps1')
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-model-relative-'+[guid]::NewGuid().ToString('N'))
    $selected=Join-Path (Join-Path $root 'nested') 'model.gguf'
    $relative=Get-AtaraxiaModelRelativePath $root $selected
    Assert-True ($relative -eq (Join-Path 'nested' 'model.gguf')) 'Model selection did not produce the configured relative model path.'
    $outsideRejected=$false;try{$null=Get-AtaraxiaModelRelativePath $root ($root+'-outside.gguf')}catch{$outsideRejected=$true}
    Assert-True $outsideRejected 'Model selection accepted a path outside the configured model directory.'
    $guiSource=Get-Content -Raw (Join-Path $projectRoot 'scripts/Start-AtaraxiaGui.ps1')
    $wpfAdapter=Get-Content -Raw (Join-Path $projectRoot 'scripts/adapters/WpfModelParameterAdapter.ps1')
    Assert-True ($guiSource -match 'Get-AtaraxiaModelRelativePath' -and $guiSource -notmatch '\[IO\.Path\]::GetRelativePath' -and $wpfAdapter -match '\$slider\.IsSnapToTickEnabled=' -and $wpfAdapter -notmatch '\$slider\.IsSnapToTick=') 'Model selection or slider setup uses APIs unavailable in Windows PowerShell 5.1/.NET Framework.'
}

Test-Case 'GUI model parameter editor state tracks loading dirty and save transitions' {
    . (Join-Path $projectRoot 'scripts/GuiModelParameterEditorState.ps1')
    $state=New-AtaraxiaModelParameterEditorState
    Assert-True (-not $state.initialized -and -not $state.dirty -and -not $state.loading -and $state.active_preset_id -eq '' -and $state.active_preset_origin -eq '') 'Model parameter editor state did not initialize cleanly.'
    $state=Set-AtaraxiaModelParameterEditorLoading $state $true
    Assert-True ($state.loading -and -not (Test-AtaraxiaModelParameterEditorChangeAllowed $state)) 'Model selector changes were not suppressed during programmatic loading.'
    $state=Set-AtaraxiaModelParameterEditorLoading $state $false
    Assert-True (Test-AtaraxiaModelParameterEditorChangeAllowed $state) 'Model selector changes remained suppressed after loading.'
    $state=Set-AtaraxiaModelParameterEditorPreset $state 'default' 'builtin';Assert-True ($state.active_preset_id -eq 'default' -and $state.active_preset_origin -eq 'builtin' -and -not (Test-AtaraxiaModelParameterEditorOverwriteAllowed $state)) 'Active built-in preset ownership was not tracked or still allows overwrite.'
    $state=Set-AtaraxiaModelParameterEditorPreset $state 'personal' 'user';Assert-True ((Test-AtaraxiaModelParameterEditorOverwriteAllowed $state) -and $state.active_preset_origin -eq 'user') 'A user preset did not allow overwrite after selection.'
    $state=Set-AtaraxiaModelParameterEditorDirty $state $true;$state=Set-AtaraxiaModelParameterEditorInitialized $state $true
    Assert-True ($state.dirty -and $state.initialized) 'Editor changes or initialization were not recorded.'
    $state=Set-AtaraxiaModelParameterEditorDirty $state $false
    Assert-True (-not $state.dirty -and $state.initialized) 'Successful save did not clear dirty state while retaining initialization.'
    $rejected=$false;try{$null=Set-AtaraxiaModelParameterEditorDirty $null $true}catch{$rejected=$true};Assert-True $rejected 'Model parameter editor state accepted a missing state object.'
}

Test-Case 'GUI model parameter callbacks retain state through PowerShell closures' {
    . (Join-Path $projectRoot 'scripts/GuiModelParameterEditorState.ps1')
    $state=New-AtaraxiaModelParameterEditorState;$saveCalls=[pscustomobject]@{count=0}
    $save={ $saveCalls.count++ }.GetNewClosure()
    $handlers=New-AtaraxiaModelParameterEditorHandlers $state $save
    & $handlers.on_dirty
    Assert-True $state.dirty 'Dirty callback lost its editor state in the captured event scope.'
    & $handlers.on_save
    Assert-True ($saveCalls.count -eq 1) 'Save callback did not retain the editor state and save action.'
    $state=Set-AtaraxiaModelParameterEditorDirty $state $false
    & $handlers.on_save
    Assert-True ($saveCalls.count -eq 1) 'Save callback ran while the editor was clean.'
    $guiSource=Get-Content -Raw (Join-Path $projectRoot 'scripts/Start-AtaraxiaGui.ps1')
    Assert-True ($guiSource -match 'New-AtaraxiaModelParameterEditorHandlers \$script:modelParameterEditorState \$onSaveAction' -and $guiSource -notmatch '\$onDirty=\{[^\r\n]*\$script:modelParameterEditorState') 'GUI parameter events bypass the state-capturing handler factory.'
}

Test-Case 'GUI KoboldCpp launch plan resolves paths and delegates sidecar and argument policies' {
    . (Join-Path $projectRoot 'scripts/GuiApplication.ps1')
    $root=Join-Path ([IO.Path]::GetTempPath()) 'ataraxia-gui-kobold-plan'
    $settings=[pscustomobject]@{paths=[pscustomobject]@{install_directory='runtime/kobold';executable='runtime/kobold/koboldcpp.exe';model_directory='models';model_file='local/model.gguf'};request_parameters=[pscustomobject]@{temperature=0.7}}
    $checked=[System.Collections.Generic.List[string]]::new();$exists={param($Path)$checked.Add($Path);return $true}.GetNewClosure()
    $effective={param($Settings)[pscustomobject]@{shared_parameters=$Settings.request_parameters}};$arguments={param($Effective,$ModelPath)@('--model',$ModelPath)}
    $plan=New-AtaraxiaGuiKoboldLaunchPlan $settings $root $exists $effective $arguments
    $expectedModel=[IO.Path]::GetFullPath((Join-Path (Join-Path $root 'models') 'local/model.gguf'))
    Assert-True ($plan.ready -and $plan.model_path -eq $expectedModel -and $plan.executable -eq [IO.Path]::GetFullPath((Join-Path $root 'runtime/kobold/koboldcpp.exe')) -and $plan.working_directory -eq [IO.Path]::GetFullPath((Join-Path $root 'runtime/kobold')) -and $plan.arguments.Count -eq 2 -and $plan.arguments[1] -eq $expectedModel -and $checked.Count -eq 2) 'GUI KoboldCpp launch plan did not resolve configured paths or delegate shared preset settings and arguments.'
    $settings.paths.model_file='';$missingModel=New-AtaraxiaGuiKoboldLaunchPlan $settings $root $exists $effective $arguments
    Assert-True (-not $missingModel.ready -and $missingModel.reason -eq 'model_required') 'GUI KoboldCpp launch plan did not report a missing model configuration.'
    $settings.paths.model_file='local/model.gguf';$modelOnlyMissing={param($Path)($Path -notlike '*model.gguf')};$missingModelFile=New-AtaraxiaGuiKoboldLaunchPlan $settings $root $modelOnlyMissing $effective $arguments
    Assert-True (-not $missingModelFile.ready -and $missingModelFile.reason -eq 'missing_model' -and $missingModelFile.model_path -eq $expectedModel) 'GUI KoboldCpp launch plan did not report the resolved missing model path.'
    $settings.paths.model_file='local/model.gguf';$missing={param($Path)$false};$missingExecutable=New-AtaraxiaGuiKoboldLaunchPlan $settings $root $missing $effective $arguments
    Assert-True (-not $missingExecutable.ready -and $missingExecutable.reason -eq 'missing_executable') 'GUI KoboldCpp launch plan did not report a missing executable before model validation.'
}

Test-Case 'GUI model parameters round-trip values and reject non-finite input' {
    . (Join-Path $projectRoot 'scripts/GuiModelParameters.ps1')
    $settings=Read-Json (Join-Path $projectRoot 'configs/koboldcpp-settings.json')
    $values=[ordered]@{temperature='1.25';max_tokens='2048';stop=[string[]]@('END','STOP')}
    $null=Set-AtaraxiaModelParameterValues $settings $values
    $actual=Get-AtaraxiaModelParameterValues $settings
    Assert-True ($actual.temperature -eq 1.25 -and $actual.max_tokens -eq 2048 -and $actual.stop.Count -eq 2 -and $actual.stop[1] -eq 'STOP') 'GUI model parameters did not round-trip normalized numeric and string values.'
    foreach($bad in @('NaN','Infinity','-Infinity','2.01')){$rejected=$false;try{$null=Assert-AtaraxiaModelParameterValue 'temperature' $bad}catch{$rejected=$true};Assert-True $rejected "Invalid floating parameter was accepted: $bad"}
    $validInput=Get-AtaraxiaModelParameterInputResult 'temperature' '1.25';$invalidInput=Get-AtaraxiaModelParameterInputResult 'temperature' '1.255';Assert-True ($validInput.valid -and $validInput.value -eq 1.25 -and -not $invalidInput.valid -and -not [string]::IsNullOrWhiteSpace($invalidInput.error)) 'GUI model parameter input did not return normalized acceptance and validation feedback.'
    $rejected=$false;try{$null=Assert-AtaraxiaModelParameterValue 'stop' @('valid',4)}catch{$rejected=$true};Assert-True $rejected 'Non-text stop entries were accepted.'
    $rejected=$false;try{$null=Set-AtaraxiaModelParameterValues $settings ([ordered]@{unknown=1})}catch{$rejected=$true};Assert-True $rejected 'Unknown model parameters were silently accepted.'
    $guiSource=Get-Content -Raw (Join-Path $projectRoot 'scripts/Start-AtaraxiaGui.ps1')
    Assert-True ($guiSource -notmatch '=;\.Add_Click|\{\.IsExpanded') 'Model parameter control builder contains invalid event wiring.'
}

Test-Case 'GUI model parameter persistence validates ports and stops after a failed store write' {
    . (Join-Path $projectRoot 'scripts/ModelParameterPresets.ps1');. (Join-Path $projectRoot 'scripts/GuiModelParameterApplication.ps1')
    $settings=[pscustomobject]@{request_parameters=[pscustomobject]@{temperature=0.7};user_preset_data=[pscustomobject]@{schema_version=1;active_preset_id='p';presets=@();overrides=@()}};$events=[System.Collections.Generic.List[string]]::new()
    $saveUser={param($Value)$events.Add('user')|Out-Null}.GetNewClosure();$saveShared={param($Value)$events.Add('shared')|Out-Null}.GetNewClosure()
    $saved=Save-AtaraxiaGuiModelParameterSettings $settings $saveUser $saveShared
    Assert-True ($saved -eq $settings -and ($events -join ',') -eq 'user,shared') 'GUI model settings were not persisted in user-preset then shared-settings order.'
    $events.Clear();$userFailureMessage='';$failedUser={param($Value)$events.Add('user')|Out-Null;throw 'user store failed'}.GetNewClosure()
    try{$null=Save-AtaraxiaGuiModelParameterSettings $settings $failedUser $saveShared}catch{$userFailureMessage=$_.Exception.Message}
    Assert-True ($userFailureMessage -match 'user store failed' -and ($events -join ',') -eq 'user') 'Shared settings were written after user-preset persistence failed or the failure detail was lost.'
    $events.Clear();$sharedFailureMessage='';$failedShared={param($Value)$events.Add('shared')|Out-Null;throw 'settings store failed'}.GetNewClosure()
    try{$null=Save-AtaraxiaGuiModelParameterSettings $settings $saveUser $failedShared}catch{$sharedFailureMessage=$_.Exception.Message}
    Assert-True ($sharedFailureMessage -match 'presets were saved' -and $sharedFailureMessage -match 'settings store failed' -and ($events -join ',') -eq 'user,shared,user') 'The GUI model settings operation lost partial-save context or did not persist its recovery journal after the second store failed.'
    Assert-True ($settings.user_preset_data.pending_shared_settings.request_parameters.temperature -eq 0.7) 'A failed shared-settings save did not leave a recoverable user-side journal.'
    $events.Clear();$invalidAdapterRejected=$false
    try{$null=Save-AtaraxiaGuiModelParameterSettings $settings $null $saveShared}catch{$invalidAdapterRejected=$true}
    Assert-True ($invalidAdapterRejected -and $events.Count -eq 0) 'Invalid persistence adapters were accepted or effects ran before adapter validation.'
    $events.Clear();$recovered=Resolve-AtaraxiaPendingSharedModelParameterSettings $settings $saveShared $saveUser
    Assert-True ($recovered.recovered -and $events -join ',' -eq 'shared,user' -and $null -eq $settings.user_preset_data.PSObject.Properties['pending_shared_settings']) 'A pending shared-settings journal was not replayed and cleared after successful persistence.'
    $null=Set-AtaraxiaPendingSharedModelParameterSettings $settings $saveUser;$failingRecovery={param($Value)$events.Add('shared-failed')|Out-Null;throw 'offline'}.GetNewClosure();$failedRecovery=$false
    try{$null=Resolve-AtaraxiaPendingSharedModelParameterSettings $settings $failingRecovery $saveUser}catch{$failedRecovery=$true}
    Assert-True ($failedRecovery -and $null -ne $settings.user_preset_data.PSObject.Properties['pending_shared_settings']) 'A failed recovery discarded its journal.'
}

Test-Case 'Generic conversation GUI supports reports and editing the last request' {
    $guiScript=Get-Content -LiteralPath (Join-Path (Join-Path $projectRoot 'scripts') 'Start-AtaraxiaGui.ps1') -Raw -Encoding UTF8
    $guiView=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/presentation/AtaraxiaWindow.xaml') -Raw -Encoding UTF8
    $guiSplash=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/presentation/AtaraxiaSplash.xaml') -Raw -Encoding UTF8
    $drawerAdapterPath=Join-Path $projectRoot 'scripts/adapters/WpfProjectDrawerAdapter.ps1';$drawerAdapter=if(Test-Path $drawerAdapterPath){Get-Content $drawerAdapterPath -Raw -Encoding UTF8}else{''}
    $parameterAdapterPath=Join-Path $projectRoot 'scripts/adapters/WpfModelParameterAdapter.ps1';$parameterAdapter=if(Test-Path $parameterAdapterPath){Get-Content $parameterAdapterPath -Raw -Encoding UTF8}else{''}
    $contextMenuAdapterPath=Join-Path $projectRoot 'scripts/adapters/WpfContextMenuAdapter.ps1';$contextMenuAdapter=if(Test-Path $contextMenuAdapterPath){Get-Content $contextMenuAdapterPath -Raw -Encoding UTF8}else{''}
    $inputLayoutPath=Join-Path $projectRoot 'scripts/GuiInputLayout.ps1';$inputLayout=if(Test-Path $inputLayoutPath){Get-Content $inputLayoutPath -Raw -Encoding UTF8}else{''}
    $wpfViewAdapter=Get-Content -Raw (Join-Path $projectRoot 'scripts/adapters/WpfGuiViewAdapter.ps1')
    $localizedPresentation=Get-Content -Raw (Join-Path $projectRoot 'scripts/GuiLocalizedPresentation.ps1')
    $processApplication=Get-Content -Raw (Join-Path $projectRoot 'scripts/GuiProcessApplication.ps1')
    $processAdapter=Get-Content -Raw (Join-Path $projectRoot 'scripts/adapters/PowerShellGuiProcessAdapter.ps1')
    $navigationStateModel=Get-Content -Raw (Join-Path $projectRoot 'scripts/GuiNavigationState.ps1')
    $gui=$guiScript+"`n"+$guiView+"`n"+$guiSplash+"`n"+$drawerAdapter+"`n"+$parameterAdapter+"`n"+$contextMenuAdapter+"`n"+$inputLayout+"`n"+$wpfViewAdapter+"`n"+$localizedPresentation+"`n"+$processApplication+"`n"+$processAdapter+"`n"+$navigationStateModel
    $startProcessFunction=[regex]::Match($guiScript,'(?s)function Start-AtaraxiaProcess\s*\{.*?\n\}').Value
    $stopProcessFunction=[regex]::Match($guiScript,'(?s)function Stop-AtaraxiaRun\s*\{.*?\n\}').Value
    Assert-True ($startProcessFunction -match 'Start-AtaraxiaGuiChildProcess' -and $startProcessFunction -notmatch 'Start-Process' -and $stopProcessFunction -match 'Stop-AtaraxiaGuiChildProcess|Invoke-AtaraxiaGuiChildProcess' -and $stopProcessFunction -notmatch '\.Kill\(|\.WaitForExit|Start-Process') 'GUI composition root still starts, stops, or synchronously launches agent processes directly.'
    $refreshFunction=[regex]::Match($guiScript,'(?s)function Refresh-ProjectSessionTree\s*\{.*?\n\}').Value
    Assert-True ($guiScript -match 'Set-AtaraxiaWpfProjectDrawer' -and $refreshFunction -notmatch '\[Windows\.Controls\.' -and $drawerAdapter -match 'function Set-AtaraxiaWpfProjectDrawer' -and $drawerAdapter -match 'Register-AtaraxiaGuiViewAction') 'Project drawer composition still constructs WPF controls directly instead of delegating rendering to its adapter.'
    Assert-True ($contextMenuAdapter -match 'function New-AtaraxiaWpfSessionContextMenu' -and $contextMenuAdapter -match 'function Register-AtaraxiaWpfConversationCopyMenus' -and $contextMenuAdapter -match '\$Labels\.copy_session_id' -and $contextMenuAdapter -match '\$CopyLabel' -and $guiScript -match 'New-AtaraxiaWpfSessionContextMenu' -and $guiScript -match 'Register-AtaraxiaWpfConversationCopyMenus' -and $guiScript -notmatch '\$OtherSession\.ContextMenu\.Items\[|\[Windows\.Media\.VisualTreeHelper\]') 'Context menu construction, localized label application, or visual tree traversal remains in the GUI composition root.'
    $parameterBuilder=[regex]::Match($guiScript,'(?s)function Build-AtaraxiaModelParameterControls\s*\{.*?\n\}').Value
    Assert-True ($guiScript -match 'New-AtaraxiaWpfModelParameterControls' -and $parameterBuilder -notmatch '\[Windows\.Controls\.' -and $parameterAdapter -match 'function New-AtaraxiaWpfModelParameterControls' -and $parameterAdapter -match "'value_change'" -and $parameterAdapter -match "'lost_focus'") 'Model parameter composition still creates or wires WPF controls instead of delegating to its adapter.'
    try { [xml]$guiXaml=$guiView } catch { throw "GUI XAML is invalid: $($_.Exception.Message)" }
    $guiNamespaces=[System.Xml.XmlNamespaceManager]::new($guiXaml.NameTable);$guiNamespaces.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')
    Assert-True ($guiScript -match '\[switch\]\$NoSplash' -and $guiScript -match 'New-AtaraxiaGuiStartupPlan' -and $guiScript -match '(?s)New-AtaraxiaGuiStartupRelaunchRequest.*?Start-AtaraxiaGuiChildProcess' -and $guiScript -notmatch 'Start-Process' -and $guiScript -match 'if\(\$guiStartupPlan\.show_splash\)\{\$script:splashWindow=Show-AtaraxiaStartupSplash\}' -and $gui -match 'Width="560" Height="315" WindowStartupLocation="CenterScreen" WindowStyle="None"' -and $gui -match 'assets/splash/ataraxia-project-cover\.png' -and $gui -match 'minimumSplashMilliseconds=1100' -and $gui -match 'Wait-AtaraxiaGuiViewDelay \$script:guiViewPort') 'Splash cover is not displayed briefly or startup options do not use the application model.'
    Assert-True ($gui -match 'Expander' -and $gui -match 'Conversation' -and $gui -match 'EditLast' -and $gui -match 'state\.json') 'Conversation reports or edit/resend flow is missing.'
    Assert-True ($gui -match 'IsExpanded="\{Binding is_expanded, Mode=TwoWay\}"') 'Conversation report expansion state is not bound to the view model.'
    $animationAdapter=Get-Content -Raw (Join-Path $projectRoot 'scripts/adapters/WpfSmoothExpanderAdapter.ps1');Assert-True ($animationAdapter -match 'function Enable-AtaraxiaWpfSmoothExpander' -and $animationAdapter -match 'DoubleAnimation' -and $animationAdapter -match 'FindName\(''ExpandClip''' -and $animationAdapter -match 'Add_Expanded' -and $animationAdapter -match 'Add_Collapsed' -and $animationAdapter -match 'return ,\(' -and $gui -match 'Register-AtaraxiaWpfSmoothExpanders') 'WPF expander adapter does not animate clipped content, retain its empty registry object, or is not used by the GUI composition root.'
    Assert-True ($gui -match 'Path Data="\{Binding icon_geometry\}"' -and $gui -match 'StackPanel Orientation="Horizontal"') 'Role icon is not shown beside each report heading.'
    Assert-True ($gui -match 'TargetType="\{x:Type Button\}"' -and $gui -match 'TargetType="\{x:Type TextBox\}"' -and $gui -match 'TargetType="\{x:Type ComboBox\}"' -and $gui -match 'TargetType="\{x:Type Expander\}"' -and $gui -match 'TargetType="\{x:Type Slider\}"' -and $gui -match 'PART_ContentHost' -and $gui -match 'FocusVisualStyle" Value="\{x:Null\}') 'GUI controls still rely on default Windows chrome instead of custom vector templates.'
    Assert-True ($gui -match 'ThemeOptionTemplate.*Binding label' -and $gui -match '\$ThemeSelector\.ItemTemplate=\$window\.Resources\[''ThemeOptionTemplate''\]' -and $gui -notmatch '\$ThemeSelector\.DisplayMemberPath=''label''') 'Theme picker does not render the localized label from its option object.'
    Assert-True ($gui -match '<ToggleButton Grid.ColumnSpan="2" HorizontalAlignment="Stretch" Background="Transparent"( Foreground="\{DynamicResource PrimaryTextBrush\}")? IsChecked="\{Binding IsDropDownOpen') 'ComboBox clicks outside the arrow do not open the dropdown.'
    $iconAssetAdapter=Get-Content -Raw (Join-Path $projectRoot 'scripts/adapters/WpfIconAssetAdapter.ps1');Assert-True ($gui -match 'ExpanderChevronRightGeometry' -and $gui -match 'ExpanderChevronDownGeometry' -and $gui -notmatch 'RotateTransform Angle="90" CenterX="6" CenterY="10"' -and $iconAssetAdapter -match '\$Icon\.Width=16;\$Icon\.Height=16' -and $gui -match 'Set-AtaraxiaWpfPathIcon \$iconControl\.Content' -and $gui -match '\$iconControl\.Padding=\[Windows\.Thickness\]::new\(3\)') 'Expander chevrons or toolbar SVG icons are misaligned or clipped.'
    Assert-True ($gui -match 'IconButtonHover' -and $gui -match 'MouseOver' -and $gui -match 'ProjectGroupExpander' -and $gui -match 'gui_no_projects' -and $gui -match 'gui_projects') 'Icon hover feedback or the always-available project group is missing.'
    Assert-True ($gui -notmatch 'Text="Ataraxia"|ProjectManagerTitle|ToggleDrawer' -and $gui -match 'Title=""' -and $gui -match 'ataraxia-app-icon\.png' -and $gui -notmatch 'Content=\$\(Get-AppText ''gui_active_project''\)|Content=if\(\$projectName -ieq \$active\)\{Get-AppText ''gui_active_project''') 'GUI still shows the brand label, drawer toggle, or window title, or is missing its app icon.'
    Assert-True ($drawerAdapter -match 'Register-AtaraxiaGuiViewAction \$Port \$projectExpandTarget ''activate''' -and $drawerAdapter -match 'Register-AtaraxiaGuiViewAction \$Port \$projectSelectTarget ''activate''' -and $drawerAdapter -match 'Register-AtaraxiaGuiViewAction \$Port \$newSessionTarget ''activate''' -and $drawerAdapter -match 'Register-AtaraxiaGuiViewAction \$Port \$target ''activate''' -and $drawerAdapter -match 'recent-session:' -and $drawerAdapter -notmatch '\$projectText\.Add_Click|\$choose\.Add_Click|\$newSession\.Add_Click|\$button\.Add_Click' -and $gui -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''recent_sessions_header'' ''activate''' -and $gui -match 'RecentSessionsHeaderButton.*IconButtonHover') 'Dynamic project and session actions bypass the view port or the recent-session group does not toggle.'
    Assert-True ($drawerAdapter -match 'Register-AtaraxiaGuiViewAction \$Port \$treeTarget ''expanded_change''' -and $guiScript -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''recent_sessions_group'' ''expanded_change''' -and $drawerAdapter -notmatch '\$node\.Add_Expanded|\$node\.Add_Collapsed|\$RecentSessionsExpander\.Add_Expanded|\$RecentSessionsExpander\.Add_Collapsed') 'Drawer expansion state events bypass the GUI view port.'
    Assert-True ($gui -match 'RecentSessionsExpander' -and $gui -match 'RecentSessionsPanel' -and $gui -notmatch '\$ProjectTreePanel\.Children\.Add\(\$recentNode\)' -and $gui -match 'Background="\{DynamicResource AppBackgroundBrush\}" VerticalScrollBarVisibility="Auto" Padding="10"' -and $gui -match 'ConversationBubble.*Value="Transparent".*Value="\{DynamicResource PanelBrush\}"') 'Recent sessions are not a sibling group or conversation surfaces do not use transparent and tinted backgrounds.'
    $projectGroupNode=$guiXaml.SelectSingleNode("//*[@x:Name='ProjectGroupExpander']",$guiNamespaces);$recentGroupNode=$guiXaml.SelectSingleNode("//*[@x:Name='RecentSessionsExpander']",$guiNamespaces)
    Assert-True ($null -ne $projectGroupNode -and $null -ne $recentGroupNode -and [object]::ReferenceEquals($projectGroupNode.ParentNode,$recentGroupNode.ParentNode)) 'Recent sessions do not sit beside the project group in the drawer.'
    Assert-True ($gui -match 'project_group_title=@\(''Text'',''labels\.project_group''\)' -and $gui -notmatch '\$ProjectGroupExpander\.(Text|Header)\s*=' -and $guiXaml.SelectSingleNode("//*[@x:Name='GoalLabel']",$guiNamespaces) -eq $null -and $gui -notmatch '\$GoalLabel\.') 'Project header localization targets a nonexistent property or the removed request label has returned.'
    foreach($controlName in @('NewProject','ProjectPromptButton','ProjectTreeScroll')){Assert-True ($null -ne $guiXaml.SelectSingleNode("//*[@x:Name='"+$controlName+"']",$guiNamespaces) -and $null -ne $guiXaml.SelectSingleNode("//*[@x:Name='"+$controlName+"']",$guiNamespaces).SelectSingleNode('ancestor::*[@x:Name="ProjectGroupExpander"]',$guiNamespaces)) "Project group does not enclose $controlName within its open/close range."}
    $iconHoverStyle=[regex]::Match($gui,'(?s)<Style x:Key="IconButtonHover".*?</Style>').Value
    Assert-True ($iconHoverStyle -match 'HoverTint.*TemplateBinding Foreground.*Opacity="0"' -and $iconHoverStyle -match 'IsMouseOver" Value="True"><Setter TargetName="HoverTint" Property="Opacity" Value="0.12"' -and $iconHoverStyle -notmatch 'IsMouseOver" Value="True"><Setter TargetName="Chrome"') 'Hover treatment changes the button foreground or fails to tint its background toward that foreground.'
    $svgModel=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/GuiConversationModel.ps1') -Raw -Encoding UTF8
    Assert-True ($svgModel -notmatch 'assets/role-icons' -and $svgModel -notmatch 'Test-Path|ReadAllText|Get-ChildItem' -and $svgModel -match 'ConvertFrom-AtaraxiaSvgGeometry') 'Conversation model performs asset I/O instead of accepting prepared geometry.'
    foreach($iconName in @('new-project','project-prompt-button','rename-session','session-prompt-button','new-session','settings','browse-config','kobold-restart','browse-task','browse-workspace','refresh-models','scroll-to-latest','create-task','edit-last','send','stop','menu','more','kobold-start','kobold-stop','chevron-right','chevron-down','save','save-as','trash')){Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot ('assets/ui-icons/'+$iconName+'.svg')) -PathType Leaf) "Missing GUI SVG icon: $iconName"}
    $iconButtons=@($guiXaml.SelectNodes('//*[local-name()="Button"][.//*[local-name()="Path"]]'))
    foreach($button in $iconButtons){Assert-True ($button.HasAttribute('ToolTip') -and $button.HasAttribute('AutomationProperties.Name')) "Icon button '$($button.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml'))' lacks a tooltip or accessibility name."}
    foreach($button in $guiXaml.SelectNodes('//*[local-name()="Button"][@ToolTip]')){Assert-True $button.HasAttribute('AutomationProperties.Name') "Tooltip button '$($button.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml'))' lacks an accessibility name."}
    $iconToggles=@($guiXaml.SelectNodes('//*[local-name()="ToggleButton"][.//*[local-name()="Path"]]'))
    foreach($toggle in $iconToggles){Assert-True ($toggle.HasAttribute('ToolTip') -and $toggle.HasAttribute('AutomationProperties.Name')) 'Icon toggle button lacks a tooltip or accessibility name.'}
    foreach($buttonName in @('SaveParameterPreset','SaveAsParameterPreset','RenameParameterPreset','DeleteParameterPreset')){$button=$guiXaml.SelectSingleNode("//*[@x:Name='$buttonName']",$guiNamespaces);Assert-True ($null -ne $button -and $null -ne $button.SelectSingleNode("*[local-name()='Path']") -and -not $button.HasAttribute('Content')) "Preset action $buttonName is not an icon-only button."}
    Assert-True ($gui -match "@\('SaveParameterPreset','save'\)" -and $gui -match "@\('SaveAsParameterPreset','save-as'\)" -and $gui -match "@\('RenameParameterPreset','rename-session'\)" -and $gui -match "@\('DeleteParameterPreset','trash'\)") 'Preset management icons are not wired to the shared SVG icon adapter.'
    $iconAdapter=Get-Content -Raw (Join-Path $projectRoot 'scripts/adapters/WpfIconAssetAdapter.ps1');$wpfDialogSource=Get-Content -Raw (Join-Path $projectRoot 'scripts/adapters/WpfDialogAdapter.ps1')
    $otherSessionButton=$guiXaml.SelectSingleNode("//*[@x:Name='OtherSession']",$guiNamespaces)
    Assert-True ($iconAdapter -match 'function Set-AtaraxiaWpfAutomationName' -and $null -ne $otherSessionButton -and $otherSessionButton.HasAttribute('AutomationProperties.Name')) 'Static icon buttons or the additional-session icon do not receive an accessible name through the shared icon adapter.'
    Assert-True ($parameterAdapter -match 'Set-AtaraxiaWpfAutomationName \$button' -and $drawerAdapter -match 'Set-AtaraxiaWpfAutomationName \$(choose|newSession)' -and $wpfDialogSource -match 'Button x:Name="DialogClose".*AutomationProperties.Name=' -and $wpfDialogSource -match 'Set-AtaraxiaWpfAutomationName \$(up|row)') 'Dynamically generated parameter, drawer, or path-dialog icons do not receive accessible names.'
    Assert-True ($gui -match 'Invoke-Agent\.ps1' -and $gui -match "'-Step','-1'") 'GUI does not run the generic workflow to completion.'
Assert-True ($gui -match 'ProjectDrawer' -and $gui -notmatch 'ProjectSelector|SwitchProject' -and $gui -match 'NewProject' -and $gui -notmatch 'x:Name="RenameProject"' -and $drawerAdapter -match '\$renameItem\.Header=& \$GetText ''gui_rename_project''' -and $drawerAdapter -match "'rename_project'" -and $guiScript -match 'Rename-AtaraxiaProjectFromGui \(\[string\]\$Value\)') 'Project rename is available from the project name context menu rather than a row icon.'
    Assert-True ($gui -match 'ProjectTreePanel' -and $guiScript -match 'Refresh-ProjectSessionTree' -and $drawerAdapter -match 'project-tree:' -and $drawerAdapter -match 'expanded_change' -and $guiScript -match 'Select-AtaraxiaDrawerSession' -and $guiScript -match 'Select-AtaraxiaDrawerProject') 'Drawer projects cannot be selected and expanded to show their sessions.'
    Assert-True ($drawerAdapter -match '\$newSessionTarget' -and $drawerAdapter -match "'new_session'" -and $guiScript -match 'Begin-AtaraxiaNewSessionScreen \(\[string\]\$Value\)' -and $drawerAdapter -match 'gui_new_session') 'Project rows do not offer an icon action to open a new session for that project.'
    Assert-True ($gui -match 'function Begin-AtaraxiaNewSessionScreen' -and $gui -match 'function Materialize-AtaraxiaPendingSession' -and $gui -match 'pending_session_project' -and $gui -match 'IsNullOrWhiteSpace\(\$Goal\.Text\)') 'A new session is created before the user submits a non-empty first request.'
    Assert-True ($gui -match 'Stop-AtaraxiaRun' -and $gui -notmatch 'StopTask' -and $gui -match 'Get-AppText.+gui_stop') 'Run button does not switch to a stop-and-restore action.'
    Assert-True ($gui -match 'SessionSelector' -and $gui -match 'NewSession' -and $gui -match 'guiSessionMenu\.rename_session' -and $gui -match 'New-AtaraxiaGuiSession' -and $gui -match 'function Invoke-AtaraxiaGuiSessionRename' -and $gui -match 'Rename-AtaraxiaGuiSession \(New-AtaraxiaGuiProjectSessionAdapters\)') 'Project sessions cannot be created, selected, and renamed through the application use case.'
    Assert-True ($gui -match 'OtherSession' -and $gui -match 'guiSessionMenu\.copy_session_id' -and $gui -match 'Set-AtaraxiaGuiClipboardText' -and $guiScript -match 'Set-AtaraxiaWpfSessionContextMenuLanguage.*guiLocalizedPresentation') 'Session ID copy action is missing from the additional actions menu or bypasses the clipboard port.'
    Assert-True ($gui -match 'Invoke-AtaraxiaGuiProcessPoll' -and $gui -match "gui_running_role" -and $gui -match 'poll\.presentation\.role') 'GUI does not display the currently running role through the application model.'
    $guiApplication=Get-Content -Raw (Join-Path $projectRoot 'scripts/GuiApplication.ps1')
    Assert-True ($guiApplication -match 'Resolve-AtaraxiaGuiSessionTaskPath' -and $guiApplication -match 'Get-AtaraxiaGuiProcessUpdate' -and $guiApplication -notmatch 'Windows\.(Controls|Media|Visibility)') 'GUI application logic is coupled to WPF instead of being independently testable.'
    Assert-True ($gui -match 'ThemeSelector' -and $gui -match 'Apply-AtaraxiaTheme' -and $gui -match 'Get-AtaraxiaWindowsSystemTheme') 'GUI does not provide system, light, and dark theme selection.'
    $themeAdapter=Get-Content -Raw (Join-Path $projectRoot 'scripts/adapters/WpfThemeAdapter.ps1');$guiComposition=Get-Content -Raw (Join-Path $projectRoot 'scripts/Start-AtaraxiaGui.ps1');Assert-True ($themeAdapter -match 'Set-AtaraxiaWpfThemeResources' -and $themeAdapter -notmatch 'Windows\.(Media|Controls)' -and $guiComposition -match 'Set-AtaraxiaWpfThemeResources \$window\.Resources' -and $guiComposition -match 'Get-AtaraxiaThemePalette \$script:guiThemeDefinitions' -and $guiComposition -match 'configs/gui-themes\.json' -and $guiComposition -notmatch '\$keys=@\{app_background=') 'Theme resource mapping remains in the GUI composition root instead of its adapter.'
    Assert-True ($gui -match 'KoboldToggle' -and $gui -match 'KoboldStatusDot' -and $gui -match 'Start-KoboldCppFromGui' -and $gui -match 'Stop-KoboldCppFromGui' -and $gui -match 'Get-KoboldCppLaunchArguments' -and $gui -match '#555555' -and $gui -match '#BBBBBB') 'GUI does not launch/stop KoboldCpp and color its API connection state.'
    Assert-True ($gui -match 'Start-KoboldCppAcquisitionIfMissing' -and $gui -match 'Test-AtaraxiaStoreFile \$executable \$script:guiJsonFileStore' -and $gui -match 'Initialize-KoboldCpp\.ps1' -and $gui -match 'RedirectStandardOutput' -and $gui -match 'Complete-KoboldCppAcquisitionIfFinished') 'GUI does not acquire a missing KoboldCpp executable asynchronously through the separate initializer.'
    $modelFileAdapter=Get-Content -Raw (Join-Path $projectRoot 'scripts/adapters/ModelFileSystemAdapter.ps1');Assert-True ($gui -match 'ModelFileSelector' -and $gui -match 'Get-AtaraxiaAvailableModels' -and $gui -match 'Save-AtaraxiaSelectedModel' -and $gui -match 'Get-KoboldCppEffectiveSettings' -and $gui -match 'Save-KoboldCppSettings' -and $gui -match 'Get-AtaraxiaModelFiles \$directory \$dependencies' -and $gui -notmatch "-Filter '\*\.gguf' -Recurse" -and $gui -notmatch 'Get-KoboldCppModelSettings|ChangeExtension\(\$ModelPath' -and $gui -match 'Save-AtaraxiaModelParameterPresetAs' -and $gui -match 'Rename-AtaraxiaCurrentModelParameterPreset' -and $gui -match 'Remove-AtaraxiaCurrentModelParameterPreset' -and $modelFileAdapter -match 'function Get-AtaraxiaModelFiles' -and $modelFileAdapter -match 'ReparsePoint' -and $gui -match 'Set-AtaraxiaModelParameterEditorLoading.*\$true;try\{Refresh-AtaraxiaModelSelector\}') 'GUI does not discover local GGUF files through the injectable adapter or manage shared parameter presets without sidecar settings.'
    Assert-True ($gui -match 'Get-AtaraxiaModelParameterPresetCapabilities' -and $gui -match "'save_parameter_preset_enabled'" -and $gui -match "'delete_parameter_preset_enabled'" -and $gui -match 'Test-AtaraxiaModelParameterEditorOverwriteAllowed') 'The GUI does not disable built-in preset overwrite/delete or guard automatic save paths.'
    Assert-True ($gui -match 'KoboldRestart' -and $gui -match 'Restart-KoboldCppFromGui' -and $gui -match 'gui_kobold_restart_requires_managed' -and $gui -match 'gui_kobold_restart_port_busy') 'GUI cannot safely restart its managed KoboldCpp process.'
    Assert-True ($parameterAdapter -match 'Register-AtaraxiaGuiViewAction \$Port \$sliderTarget ''value_change''' -and $parameterAdapter -match 'Register-AtaraxiaGuiViewAction \$Port \$inputTarget ''text_change''' -and $parameterAdapter -match 'Register-AtaraxiaGuiViewAction \$Port \$inputTarget ''lost_focus''' -and $parameterAdapter -match '\$GetInputResult' -and $parameterAdapter -match '\$GetStepValue' -and $guiScript -match '\$getInputResult=\$\{function:Get-AtaraxiaModelParameterInputResult\}' -and $parameterAdapter -notmatch '\$slider\.Add_ValueChanged|\$input\.Add_TextChanged|\$input\.Add_LostFocus|\$sender\.TagData\.(min|max|step)') 'Dynamic model parameter events or validation rules bypass the view port and model contract.'
    Assert-True ($gui -match 'x:Name="NewSession"[^>]*ToolTip="New session"' -and $gui -match '<Path Data="M4,1 H12 L16,5 V16 H4 Z M12,1 V5 H16 M10,8 V14 M7,11 H13"' -and $gui -match "new_session='gui_new_session'" -and $wpfViewAdapter -match 'new_session=@\(''ToolTip'',''tooltips\.new_session''\)') 'New session action is not an icon button with a localized tooltip.'
    $newSessionButton=[regex]::Match($gui,'(?s)<Button x:Name="NewSession".*?</Button>').Value;$sendButton=[regex]::Match($gui,'(?s)<Button x:Name="RunTask".*?</Button>').Value
    $dialogs=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/adapters/WpfDialogAdapter.ps1') -Raw -Encoding UTF8
    $iconAdapter=Get-Content -Raw (Join-Path $projectRoot 'scripts/adapters/WpfIconAssetAdapter.ps1');Assert-True ($iconAdapter -match 'function Set-AtaraxiaWpfPathForeground' -and $drawerAdapter -match '\$SetIcon \$chooseIcon ''''' -and $iconAdapter -match 'SetBinding\(\[Windows\.Shapes\.Shape\]::StrokeProperty,\$binding\)' -and $iconAdapter -match 'RelativeSourceMode\]::FindAncestor' -and $iconAdapter -match '\.AncestorType=\[Windows\.Controls\.Primitives\.ButtonBase\]' -and $newSessionButton -notmatch 'Background="\{DynamicResource AccentBrush\}"|Foreground="\{DynamicResource AccentTextBrush\}"' -and $sendButton -match 'Background="\{DynamicResource IconBrush\}"' -and $sendButton -notmatch 'Background="\{DynamicResource AccentBrush\}"' -and $dialogs -match '\$parts\.close_icon\.SetBinding\(\[Windows\.Shapes\.Shape\]::StrokeProperty,\$closeIconStroke\)') 'Non-send icons do not follow button foreground on transparent backgrounds, or the send action is not monochrome.'
    foreach($control in @('NewProject','ProjectPromptButton','SettingsToggle','BrowseConfig','BrowseTask','BrowseWorkspace','CreateTask','EditLast','RunTask','KoboldToggle','KoboldRestart','RefreshModels')){Assert-True ($gui -match ('x:Name="'+$control+'"[^>]*ToolTip=') -or $gui -match ('\$'+$control+'\.ToolTip=Get-AppText')) "Icon action $control has no tooltip."}
    Assert-True ($gui -match 'function Set-RunTaskIcon' -and $gui -match 'function Set-KoboldToggleIcon' -and $gui -match 'DynamicResource IconBrush') 'Action icons do not reflect state and theme colors.'
    Assert-True ($gui -match 'x:Name="ConversationScrollViewer"' -and $gui -match 'x:Name="ScrollToLatest"[^>]*Visibility="Collapsed"' -and $gui -match 'Update-AtaraxiaScrollToLatestButton' -and $gui -match 'Invoke-AtaraxiaGuiViewOperation \$script:guiViewPort scroll_to_end ''conversation_scroll''') 'The conversation does not provide a conditional jump-to-latest control through the view port.'
    Assert-True ($gui -match 'gui_copy_request' -and $gui -match 'ContextMenu' -and $gui -match 'Wire-AtaraxiaRequestCopyMenus' -and $gui -match 'Set-AtaraxiaGuiClipboardText' -and $gui -match 'Register-AtaraxiaGuiViewAction \$Port \$copyTargetKey ''activate''' -and $gui -notmatch '\$menuItem\.Add_Click') 'Past user request copy menu bypasses the view port or is missing.'
    Assert-True ($gui -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''rename_session_menu'' ''activate''' -and $gui -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''session_prompt_menu'' ''activate''' -and $gui -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''copy_session_id_menu'' ''activate''' -and $gui -notmatch '\$script:(RenameSessionMenuItem|SessionPromptMenuItem|CopySessionIdMenuItem)\.Add_Click') 'Session context menu items bypass the GUI view port.'
    Assert-True ($gui -match 'x:Name="ConversationHeading"[^>]*IsReadOnly="True"' -and $gui -match 'x:Name="ConversationBody"[^>]*IsReadOnly="True"') 'Conversation headings and bodies are not selectable text.'
    Assert-True ($gui -match 'ConversationBubble' -and $gui -match 'HorizontalAlignment" Value="Right"' -and $gui -match 'HorizontalAlignment" Value="Left"' -and $gui -match 'CornerRadius="7" BorderThickness="0"') 'Requests and reports are not shown in a minimal left/right chat layout.'
    Assert-True ($gui -match 'x:Name="SettingsPanel" Grid.Row="1" Visibility="Collapsed"' -and $gui -match 'x:Name="SettingsToggle"' -and $gui -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''settings_toggle'' ''activate''' -and $gui -match 'x:Name="SettingsScrollViewer" VerticalScrollBarVisibility="Auto"' -and $gui -match 'x:Name="SettingsGeneralTitle"' -and $gui -match 'x:Name="SettingsModelTitle"' -and $gui -match 'gui_task_settings' -and $gui -notmatch '<Expander x:Name="(TaskSettingsExpander|ParametersExpander)') 'Settings are not shown together in a scrollable dedicated screen.'
    $settingsScrollNode=$guiXaml.SelectSingleNode("//*[@x:Name='SettingsScrollViewer']",$guiNamespaces);$generalSettingsNode=$guiXaml.SelectSingleNode("//*[@x:Name='SettingsGeneralTitle']",$guiNamespaces);$modelSettingsNode=$guiXaml.SelectSingleNode("//*[@x:Name='SettingsModelTitle']",$guiNamespaces)
    Assert-True ($null -ne $settingsScrollNode -and $null -ne $generalSettingsNode -and $null -ne $modelSettingsNode -and $gui -match 'settings_general_title=@\(''Text'',''labels\.settings_general''\)' -and $gui -match 'settings_model_title=@\(''Text'',''labels\.settings_model''\)' -and $gui -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''close_settings'' ''activate''') 'General and model settings are not simultaneously visible or the close action is missing.'
    Assert-True ($gui -match 'gui_recent_sessions' -and $gui -match 'Get-AtaraxiaRecentSessions' -and $drawerAdapter.Contains('project_name=[string]$sessionCopy.project_name') -and $drawerAdapter.Contains('session=$sessionCopy') -and $guiScript -match 'recent_sessions_max') 'Recent sessions drawer is missing or does not use the normal project/session selection flow.'
    $wpfAdapter=Get-Content -Raw (Join-Path $projectRoot 'scripts/adapters/WpfGuiViewAdapter.ps1');Assert-True ($gui -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''goal'' ''submit''' -and $wpfAdapter -match '''submit''.*Add_PreviewKeyDown' -and $wpfAdapter -match 'ModifierKeys\]::Shift') 'Enter does not send requests or Shift+Enter preserve a newline.'
    Assert-True ($gui -match '<RowDefinition Height="2\*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>' -and $gui -match 'x:Name="Goal" Grid.Row="1" MinHeight="48" MaxHeight="160" Height="48"' -and $gui -match 'x:Name="Goal".*Padding="6,4"' -and $gui -match 'function Update-AtaraxiaGoalInputHeight' -and $gui -match 'Schedule-AtaraxiaGuiViewCallback \$script:guiViewPort ''layout_idle''' -and $gui -match 'update_multiline_input_height' -and $gui -match 'function Get-AtaraxiaGuiInputHeight' -and $gui -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''goal'' ''text_change''' -and $gui -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''goal'' ''size_change''' -and $guiScript -notmatch '\$Goal\.LineCount|\$Goal\.Padding\.Top|\$Goal\.Height\s*=') 'User query input height calculation remains in the composition root or no longer grows with line count.'
    Assert-True ($gui -match 'ProjectPromptButton' -and $gui -match 'session_prompt_menu' -and $gui -match 'Save-AtaraxiaCommonPrompt') 'GUI cannot edit project and session common prompts from their relevant menus.'
    Assert-True ($gui -notmatch 'lastSystemThemeCheck|TotalSeconds -ge 2' -and $gui -match 'Slider' -and $gui -match 'TextBox' -and $gui -match 'Save-AtaraxiaModelParameters') 'GUI still polls themes or lacks synchronized parameter controls.'
    $ja=Read-Json (Join-Path $projectRoot 'locales/ja.json');$en=Read-Json (Join-Path $projectRoot 'locales/en.json')
    foreach($key in @('gui_kobold_start','gui_kobold_stop','gui_kobold_restart','gui_kobold_connected','gui_kobold_disconnected','gui_kobold_starting','gui_kobold_downloading','gui_kobold_downloaded','gui_kobold_download_failed','gui_kobold_missing_executable','gui_kobold_model_required','gui_kobold_restart_requires_managed','gui_kobold_restart_port_busy','gui_model_file','gui_refresh_models','gui_json_repair_title','gui_json_repair_question','gui_json_repair_unavailable','gui_json_repair_none','gui_json_repair_done')){Assert-True ($null -ne $ja.PSObject.Properties[$key] -and $null -ne $en.PSObject.Properties[$key]) "KoboldCpp/JSON GUI label is missing localization: $key"}
    Assert-True ($null -ne $ja.PSObject.Properties['gui_new_session_for_project'] -and $null -ne $en.PSObject.Properties['gui_new_session_for_project']) 'Project-scoped new-session status is not localized.'
    Assert-True ($null -ne $ja.PSObject.Properties['gui_scroll_to_latest'] -and $null -ne $en.PSObject.Properties['gui_scroll_to_latest']) 'Jump-to-latest tooltip is not localized.'
    Assert-True ($null -ne $ja.PSObject.Properties['gui_role_session_namer'] -and $null -ne $en.PSObject.Properties['gui_role_session_namer'] -and $null -ne $ja.PSObject.Properties['gui_running_role'] -and $null -ne $en.PSObject.Properties['gui_running_role']) 'Role status is missing localized labels.'
}

Test-Case 'Dialogs use portable contracts and custom SVG rendering' {
    $dialogScript=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/GuiDialogs.ps1') -Raw -Encoding UTF8
    Assert-True ($dialogScript -notmatch 'Windows\.(Controls|Media|Markup|Input|Visibility)|PresentationFramework') 'GUI dialog application module still depends on WPF types.'
    $dialogConfig=Read-Json (Join-Path $projectRoot 'configs/gui-dialog-contracts.json')
    . (Join-Path $projectRoot 'scripts/GuiDialogContracts.ps1');$contract=New-AtaraxiaDialogContract -Definitions $dialogConfig -Kind input -Title 'Name' -Value 'Draft';$contractRejected=$false;try{$null=New-AtaraxiaDialogContract -Definitions $dialogConfig -Kind unknown -Title 'Bad'}catch{$contractRejected=$true};Assert-True ($contract.contract_id -eq 'ataraxia.dialog.v1' -and $contract.icon -eq 'dialog-input' -and $contract.value -eq 'Draft' -and $contract.outputs -contains 'cancelled' -and $contract.actions -contains 'confirm' -and $contractRejected) 'Portable dialog contract creation did not apply defaults or preserve declared inputs, outputs, and actions.'
    . (Join-Path $projectRoot 'scripts/GuiDialogs.ps1')
    $rendered=[System.Collections.Generic.List[object]]::new();$picked=[System.Collections.Generic.List[object]]::new();$contractFactory={param($Definitions,$Kind,$Title,$Message,$Value,$Icon,$PrimaryLabel,$SecondaryLabel)New-AtaraxiaDialogContract -Definitions $Definitions -Kind $Kind -Title $Title -Message $Message -Value $Value -Icon $Icon -PrimaryLabel $PrimaryLabel -SecondaryLabel $SecondaryLabel};$resolveResult={param($DialogContract,$Result)ConvertTo-AtaraxiaGuiDialogResult $DialogContract $Result};$text={param($Key)"text:$Key"};$render={param($valueContract)$rendered.Add($valueContract);if($valueContract.kind -eq 'confirm'){return $true};if($valueContract.kind -eq 'input'){return 'Alice'};return $null}.GetNewClosure();$pickPath={param($pathContract,$InitialDirectory,$Patterns)$picked.Add([pscustomobject]@{contract=$pathContract;initial=$InitialDirectory;patterns=@($Patterns)});return 'C:\work\task.json'}.GetNewClosure()
    $dialogService=New-AtaraxiaGuiDialogService $dialogConfig $contractFactory $resolveResult $text $render $pickPath
    $messageValue=Invoke-AtaraxiaGuiDialogService $dialogService message @('Notice','warning','Warning text',$false,'','')
    $confirmValue=Invoke-AtaraxiaGuiDialogService $dialogService message @('','question','Continue?',$true,'','')
    $inputValue=Invoke-AtaraxiaGuiDialogService $dialogService input @('Name','Draft','')
    $pathValue=Invoke-AtaraxiaGuiDialogService $dialogService path_picker @('file','Open','C:\work',@('*.task.json'))
    Assert-True ($messageValue -eq $null -and $rendered[0].kind -eq 'message' -and $rendered[0].icon -eq 'dialog-warning' -and $rendered[0].title -eq 'Notice' -and $rendered[0].primary_label -eq 'text:gui_ok' -and $confirmValue -and $rendered[1].kind -eq 'confirm' -and $rendered[1].primary_label -eq 'text:gui_yes' -and $rendered[1].secondary_label -eq 'text:gui_no' -and $inputValue -eq 'Alice' -and $rendered[2].kind -eq 'input' -and $rendered[2].value -eq 'Draft' -and $rendered[2].secondary_label -eq 'text:gui_cancel' -and $pathValue -eq 'C:\work\task.json' -and $picked[0].contract.kind -eq 'file_picker' -and $picked[0].patterns[0] -eq '*.task.json') 'Dialog application service did not build localized contracts, normalize renderer results, or pass path options to its injected picker.'
    $confirmContract=New-AtaraxiaDialogContract $dialogConfig confirm 'Confirm';$inputContract=New-AtaraxiaDialogContract $dialogConfig input 'Input';$fileContract=New-AtaraxiaDialogContract $dialogConfig file_picker 'Open';$messageContract=New-AtaraxiaDialogContract $dialogConfig message 'Notice'
    $confirmed=Invoke-AtaraxiaDialogContract $confirmContract {$true};$declined=Invoke-AtaraxiaDialogContract $confirmContract {$false};$emptyInput=Invoke-AtaraxiaDialogContract $inputContract {''};$cancelledInput=Invoke-AtaraxiaDialogContract $inputContract {$null};$picked=Invoke-AtaraxiaDialogContract $fileContract {'C:\work\file.txt'};$cancelledPicker=Invoke-AtaraxiaDialogContract $fileContract {$null};$messageResult=Invoke-AtaraxiaDialogContract $messageContract {$null}
    $invalidRendererRejected=$false;try{$null=Invoke-AtaraxiaDialogContract $inputContract {42}}catch{$invalidRendererRejected=$true};Assert-True ($confirmed.outputs.confirmed -and -not $declined.outputs.confirmed -and $emptyInput.outputs.value -eq '' -and -not $emptyInput.outputs.cancelled -and $cancelledInput.outputs.cancelled -and $picked.outputs.path -eq 'C:\work\file.txt' -and -not $picked.outputs.cancelled -and $cancelledPicker.outputs.cancelled -and @($messageResult.outputs.PSObject.Properties).Count -eq 0 -and $invalidRendererRejected) 'Dialog renderer results were not normalized according to the portable output contracts.'
    $confirmAction=Resolve-AtaraxiaDialogAction $confirmContract primary;$cancelAction=Resolve-AtaraxiaDialogAction $inputContract cancel;$navigateAction=Resolve-AtaraxiaDialogAction $fileContract navigate 'C:\work';$openAction=Resolve-AtaraxiaDialogAction $fileContract open 'C:\work\file.txt';$invalidActionRejected=$false;try{$null=Resolve-AtaraxiaDialogAction $fileContract select 'C:\work\file.txt'}catch{$invalidActionRejected=$true};Assert-True ($confirmAction.outputs.confirmed -and $cancelAction.outputs.cancelled -and -not $navigateAction.completed -and $navigateAction.outputs.path -eq 'C:\work' -and $openAction.completed -and $openAction.outputs.path -eq 'C:\work\file.txt' -and $invalidActionRejected) 'Dialog user actions did not follow each contract action set.'
    $gui=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/Start-AtaraxiaGui.ps1') -Raw -Encoding UTF8
    Assert-True ($dialogConfig.schema_version -eq 1 -and $dialogConfig.contract_id -eq 'ataraxia.dialog.v1') 'Dialog contract configuration has an unsupported schema.'
    foreach($kind in @('message','confirm','input','multiline','file_picker','folder_picker')){Assert-True ($null -ne $dialogConfig.kinds.PSObject.Properties[$kind]) "Dialog contract kind is missing: $kind"}
    $dialogContracts=Get-Content -Raw (Join-Path $projectRoot 'scripts/GuiDialogContracts.ps1');Assert-True ($dialogContracts -match 'Definitions\.kinds\.PSObject\.Properties\[\$Kind\]' -and $dialogContracts -match 'contract_id=' -and $dialogScript -notmatch 'Get-Content .*gui-dialog-contracts\.json') 'Portable dialog contract creation remains coupled to WPF rendering or omits configuration-based contracts.'
    $wpfDialogScript=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/adapters/WpfDialogAdapter.ps1') -Raw -Encoding UTF8
    Assert-True ($wpfDialogScript -match 'WindowStyle="None"' -and $wpfDialogScript -match 'AllowsTransparency="True"' -and $wpfDialogScript -match 'Get-AtaraxiaWpfUiIconGeometry' -and $wpfDialogScript -match 'Render-AtaraxiaWpfPathPicker' -and $wpfDialogScript -notmatch 'New-AtaraxiaDialogContract|Get-AppText|Invoke-AtaraxiaGuiDialog') 'WPF dialog adapter owns application contract creation, text resolution, or result normalization.'
    Assert-True ($wpfDialogScript -match 'Resolve-AtaraxiaDialogAction' -and $wpfDialogScript -notmatch 'RaiseEvent|RoutedEventArgs' -and ([regex]::Matches($wpfDialogScript,'\.DialogResult=')).Count -eq 1) 'Dialog actions bypass the portable action resolver or complete WPF windows outside the shared completion adapter.'
    Assert-True ($gui -match "GuiDialogs\.ps1" -and $gui -match 'WpfDialogAdapter\.ps1' -and $gui -match 'New-AtaraxiaGuiDialogService' -and $gui -match 'Show-AtaraxiaPathPicker' -and $gui -notmatch 'MessageBox\]::Show|OpenFileDialog|FolderBrowserDialog') 'Main GUI still uses system dialogs or omits the injected dialog service and WPF adapter.'
    foreach($iconName in @('dialog-info','dialog-warning','dialog-error','dialog-question','dialog-input','dialog-text','dialog-close','dialog-folder','dialog-file','dialog-up')){Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot ('assets/ui-icons/'+$iconName+'.svg')) -PathType Leaf) "Dialog SVG icon is missing: $iconName"}
}

Test-Case 'Dialog path adapter filters and resolves entries without WPF' {
    . (Join-Path $projectRoot 'scripts/adapters/PowerShellDialogPathAdapter.ps1')
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-dialog-path-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $root
    try {
        $null=New-Item -ItemType Directory -Path (Join-Path $root 'folder')
        [IO.File]::WriteAllText((Join-Path $root 'task-one.task.json'),'{}',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'notes.txt'),'notes',[Text.UTF8Encoding]::new($false))
        $resolved=Resolve-AtaraxiaDialogDirectory $root 'Invalid path.'
        $files=@(Get-AtaraxiaDialogPathEntries $resolved file @('*.task.json'))
        $folders=@(Get-AtaraxiaDialogPathEntries $resolved folder @('*.task.json'))
        Assert-True ($resolved -eq [IO.Path]::GetFullPath($root) -and $files.Count -eq 2 -and $files[0].Name -eq 'folder' -and $files[1].Name -eq 'task-one.task.json' -and $folders.Count -eq 1 -and $folders[0].Name -eq 'folder') 'Dialog path adapter did not include folders, filter files by pattern, or restrict folder selection entries.'
        $rejected=$false;try{$null=Resolve-AtaraxiaDialogDirectory (Join-Path $root 'missing') 'Invalid path.'}catch{$rejected=$true};Assert-True $rejected 'Dialog path adapter accepted a missing directory.'
    } finally {Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
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

Test-Case 'Conversation store uses injected persistence and clock' {
    . (Join-Path $projectRoot 'scripts/ConversationStore.ps1')
    $memory=[pscustomobject]@{conversation=[pscustomobject][ordered]@{schema_version=1;artifact_type='conversation';entries=@([pscustomobject]@{kind='user_query';body='Old query';timestamp='2026-01-01T00:00:00Z'},[pscustomobject]@{kind='report';body='Old report';timestamp='2026-01-01T00:00:01Z'},[pscustomobject]@{kind='user_query';body='Latest query';timestamp='2026-01-01T00:00:02Z'},[pscustomobject]@{kind='report';body='Latest report';timestamp='2026-01-01T00:00:03Z'})};reads=0;saves=0;saved_path=''}
    $read={param($Path)$memory.reads++;return $memory.conversation}.GetNewClosure()
    $write={param($Path,$Conversation)$memory.saves++;$memory.saved_path=$Path;$memory.conversation=$Conversation}.GetNewClosure()
    $now={return [DateTime]::Parse('2026-03-04T05:06:07Z').ToUniversalTime()}.GetNewClosure()
    $dependencies=New-AtaraxiaStoreDependencies -ReadJson $read -WriteJson $write -UtcNow $now
    $result=Add-AtaraxiaRequest -Path 'memory://conversation' -Body 'Revised query' -ReplaceLatest -Dependencies $dependencies
    Assert-True ($memory.reads -eq 1 -and $memory.saves -eq 1 -and $memory.saved_path -eq 'memory://conversation') 'Conversation store did not route persistence through injected adapters.'
    Assert-True ($result.entries.Count -eq 3 -and $result.entries[-1].body -eq 'Revised query' -and $result.entries[-1].timestamp -eq '2026-03-04T05:06:07.0000000Z') 'Injected clock or branch replacement produced the wrong conversation state.'
}

Test-Case 'GUI request persistence commits related files or compensates partial writes' {
    . (Join-Path $projectRoot 'scripts/GuiRequestApplication.ps1')
    $taskPath='memory://session/task';$metadataPath='memory://session/metadata';$conversationPath='memory://session/conversation';$journalPath='memory://session/request-transaction.json'
    $files=@{};$files[$taskPath]=[pscustomobject]@{goal='old goal';name='task'};$files[$metadataPath]=[pscustomobject]@{artifact_type='session';updated_at='2026-01-01T00:00:00Z'}
    $state=[pscustomobject]@{files=$files;writes=[System.Collections.Generic.List[string]]::new();fail_path='';fail_once=$false;rollback_fail_path='';remove_fail_path='';remove_fail_once=$false}
    $read={param($Path)if(-not $state.files.ContainsKey($Path)){throw "missing: $Path"};ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $state.files[$Path] -Depth 100)}.GetNewClosure()
    $write={param($Path,$Value)$state.writes.Add($Path)|Out-Null;$state.files[$Path]=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 100);if($Path -ceq $state.fail_path -and -not $state.fail_once){$state.fail_once=$true;throw 'simulated write failure'};if($Path -ceq $state.rollback_fail_path -and $state.fail_once){throw 'simulated rollback failure'}}.GetNewClosure()
    $exists={param($Path)$state.files.ContainsKey($Path)}.GetNewClosure();$remove={param($Path)$state.files.Remove($Path)|Out-Null;if($Path -ceq $state.remove_fail_path -and -not $state.remove_fail_once){$state.remove_fail_once=$true;$state.fail_once=$true;throw 'simulated delete failure after removal'}}.GetNewClosure();$now={return [DateTime]::Parse('2026-04-05T06:07:08Z').ToUniversalTime()}
    $dependencies=New-AtaraxiaGuiRequestPersistenceDependencies $read $write $exists $remove $now
    $saved=Save-AtaraxiaGuiRequestTransaction $taskPath $metadataPath $conversationPath $journalPath 'new request' $dependencies
    $targetWriteOrder=@($state.writes|Where-Object{$_ -ne $journalPath})
    Assert-True ($saved.task.goal -eq 'new request' -and $saved.conversation.entries[0].body -eq 'new request' -and $saved.conversation.entries[0].timestamp -eq $saved.session.updated_at -and ($targetWriteOrder -join ',') -eq "$taskPath,$metadataPath,$conversationPath" -and -not $state.files.ContainsKey($journalPath)) 'GUI request persistence did not save task, session timestamp, and conversation with one timestamp, or left its journal after commit.'
    $state.files[$conversationPath]=[pscustomobject]@{schema_version=1;artifact_type='conversation';entries=@([pscustomobject]@{kind='user_query';body='old request';timestamp='2026-01-01T00:00:00Z'},[pscustomobject]@{kind='assistant_report';body='old answer'})};$state.files[$taskPath].goal='old request';$state.files[$metadataPath].updated_at='2026-01-01T00:00:00Z';$beforeTask=ConvertTo-Json $state.files[$taskPath] -Depth 20 -Compress;$beforeMetadata=ConvertTo-Json $state.files[$metadataPath] -Depth 20 -Compress;$beforeConversation=ConvertTo-Json $state.files[$conversationPath] -Depth 20 -Compress;$state.fail_path=$conversationPath;$state.fail_once=$false;$state.writes.Clear();$failed=$false;$failureMessage=''
    try{$null=Save-AtaraxiaGuiRequestTransaction $taskPath $metadataPath $conversationPath $journalPath 'replacement' $dependencies -ReplaceLatest}catch{$failureMessage=$_.Exception.Message;$failed=$true}
    Assert-True ($failed -and $failureMessage -match 'simulated write failure' -and (ConvertTo-Json $state.files[$taskPath] -Depth 20 -Compress) -ceq $beforeTask -and (ConvertTo-Json $state.files[$metadataPath] -Depth 20 -Compress) -ceq $beforeMetadata -and (ConvertTo-Json $state.files[$conversationPath] -Depth 20 -Compress) -ceq $beforeConversation) 'A failed conversation write left the task goal, session timestamp, or conversation branch partially updated.'
    $state.files.Remove($conversationPath)|Out-Null;$state.fail_path=$conversationPath;$state.fail_once=$false;$state.rollback_fail_path=$metadataPath;$rollbackMessage=''
    try{$null=Save-AtaraxiaGuiRequestTransaction $taskPath $metadataPath $conversationPath $journalPath 'uncommitted' $dependencies}catch{$rollbackMessage=$_.Exception.Message}
    Assert-True ($rollbackMessage -match 'simulated write failure' -and $rollbackMessage -match 'Rollback also failed' -and $rollbackMessage -match [regex]::Escape($metadataPath)) 'A rollback failure did not identify both the original failure and the inconsistent file path.'
    Assert-True ($state.files.ContainsKey($journalPath) -and $state.files[$journalPath].state -eq 'pending' -and -not $state.files.ContainsKey($conversationPath)) 'A failed compensation did not retain its pending journal for restart recovery.'
    $state.rollback_fail_path='';$state.fail_path='';$recovered=Resolve-AtaraxiaGuiRequestTransaction $taskPath $metadataPath $conversationPath $journalPath $dependencies
    Assert-True ($recovered.recovered -and (ConvertTo-Json $state.files[$metadataPath] -Depth 20 -Compress) -ceq $beforeMetadata -and -not $state.files.ContainsKey($conversationPath) -and -not $state.files.ContainsKey($journalPath)) 'Restart recovery did not restore pre-transaction state and remove the completed journal.'
    $malformedJournal=[pscustomobject]@{schema_version=1;state='committed'};$state.files[$journalPath]=$malformedJournal;$state.writes.Clear();$invalidJournalRejected=$false
    try{$null=Resolve-AtaraxiaGuiRequestTransaction $taskPath $metadataPath $conversationPath $journalPath $dependencies}catch{$invalidJournalRejected=$true}
    Assert-True ($invalidJournalRejected -and $state.writes.Count -eq 0 -and $state.files[$journalPath].state -eq 'committed') 'Malformed transaction journal was applied, rewritten, or discarded.'
    $state.files.Remove($journalPath)|Out-Null;$state.remove_fail_path=$journalPath;$state.remove_fail_once=$false;$state.rollback_fail_path=$metadataPath;$state.fail_once=$false;$deleteFailureMessage=''
    try{$null=Save-AtaraxiaGuiRequestTransaction $taskPath $metadataPath $conversationPath $journalPath 'delete-boundary' $dependencies}catch{$deleteFailureMessage=$_.Exception.Message}
    Assert-True ($deleteFailureMessage -match 'simulated delete failure' -and $deleteFailureMessage -match 'Rollback also failed' -and $state.files.ContainsKey($journalPath) -and $state.files[$journalPath].state -eq 'pending') 'A journal delete that took effect before throwing left partial data without a recovery record.'
    $state.remove_fail_path='';$state.rollback_fail_path='';$null=Resolve-AtaraxiaGuiRequestTransaction $taskPath $metadataPath $conversationPath $journalPath $dependencies
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-request-recovery-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $temp -Force|Out-Null;$diskTask=Join-Path $temp 'task.json';$diskMetadata=Join-Path $temp 'session.json';$diskConversation=Join-Path $temp 'conversation.json';$diskJournal=Join-Path $temp 'request-transaction.json'
    try{
        $oldTask=[pscustomobject]@{goal='prior';name='sample';working_directory=$temp};$oldMetadata=[pscustomobject]@{artifact_type='session';id='session-test';updated_at='2026-01-01T00:00:00Z'}
        Write-AtaraxiaJsonStoreFile $diskTask $oldTask;$null=Write-AtaraxiaJsonStoreFile $diskMetadata $oldMetadata
        $pending=[pscustomobject][ordered]@{schema_version=1;state='pending';task_before=$oldTask;session_before=$oldMetadata;conversation_existed=$false;conversation_before=$null}
        Write-AtaraxiaJsonStoreFile $diskJournal $pending
        Write-AtaraxiaJsonStoreFile $diskTask ([pscustomobject]@{goal='interrupted';name='sample';working_directory=$temp});Write-AtaraxiaJsonStoreFile $diskMetadata ([pscustomobject]@{artifact_type='session';id='session-test';updated_at='2026-04-05T06:07:08Z'});Write-AtaraxiaJsonStoreFile $diskConversation ([pscustomobject]@{schema_version=1;artifact_type='conversation';entries=@([pscustomobject]@{kind='user_query';body='interrupted';timestamp='2026-04-05T06:07:08Z'})})
        $diskDeps=New-AtaraxiaGuiRequestPersistenceDependencies {param($Path)Read-AgentJsonFile $Path} {param($Path,$Value)Write-AtaraxiaJsonStoreFile $Path $Value} {param($Path)(Test-Path -LiteralPath $Path -PathType Leaf)} {param($Path)if(Test-Path -LiteralPath $Path -PathType Leaf){[IO.File]::Delete($Path)}} {return [DateTime]::UtcNow}
        $diskResult=Resolve-AtaraxiaGuiRequestTransaction $diskTask $diskMetadata $diskConversation $diskJournal $diskDeps
        $restoredTask=Read-AgentJsonFile $diskTask;$restoredMetadata=Read-AgentJsonFile $diskMetadata;$conversationRemains=Test-Path -LiteralPath $diskConversation;$journalRemains=Test-Path -LiteralPath $diskJournal
        Assert-True ($diskResult.recovered -and $restoredTask.goal -eq 'prior' -and ([DateTime]$restoredMetadata.updated_at).ToUniversalTime().ToString('yyyy-MM-dd') -eq '2026-01-01' -and -not $conversationRemains -and -not $journalRemains) "Restart recovery did not replay its persisted journal: recovered=$($diskResult.recovered), goal=$($restoredTask.goal), updated=$($restoredMetadata.updated_at), conversation=$conversationRemains, journal=$journalRemains."
    }finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
}

Test-Case 'GUI request transaction journals are preserved instead of automatically repaired' {
    . (Join-Path $projectRoot 'scripts/StructuredData.ps1')
    $path=Join-Path ([IO.Path]::GetTempPath()) ('request-transaction-'+[guid]::NewGuid().ToString('N')+'.json');Register-AgentJsonRepairKind $path 'journal'
    $proposal=New-AgentJsonRepairProposal $path ([Text.UTF8Encoding]::new($false).GetBytes('{"schema_version":1,"state":'))
    Assert-True (-not $proposal.repairable -and $proposal.kind -eq 'journal') 'A transaction journal with incomplete data was offered speculative repair.'
}

Test-Case 'GUI request submission uses the transactional persistence application' {
    $source=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/Start-AtaraxiaGui.ps1') -Raw -Encoding UTF8
    $submit=[regex]::Match($source,'(?s)function Start-AtaraxiaProcess\s*\{.*?\r?\n\}').Value
    Assert-True ($submit -match 'Save-AtaraxiaGuiRequestTransaction' -and $submit -notmatch 'Add-AtaraxiaRequest|Touch-AtaraxiaSession|\$task\.goal\s*=') 'GUI request submission bypasses its transaction coordinator or persists related files independently.'
    $load=[regex]::Match($source,'(?s)function Load-AtaraxiaTask\([^\r\n]*\)\s*\{.*?\r?\n\}').Value
    Assert-True ($load -match 'Resolve-AtaraxiaGuiRequestTransaction[^\r\n]*\r?\n\s*\$task=Read-AtaraxiaGuiJsonFile \$Path') 'GUI session loading does not recover its transaction journal before reading task state.'
}

Test-Case 'Session creation uses injected filesystem clock and identifier' {
    . (Join-Path $projectRoot 'scripts/RoleContracts.ps1')
    . (Join-Path $projectRoot 'scripts/AgentCore.ps1')
    . (Join-Path $projectRoot 'scripts/SessionStore.ps1')
    $fake=[pscustomobject]@{paths=[System.Collections.Generic.List[string]]::new();writes=[System.Collections.Generic.List[object]]::new();directories=[System.Collections.Generic.List[string]]::new()}
    $exists={param($Path)return ($Path -eq 'C:\virtual\project')}.GetNewClosure()
    $mkdir={param($Path)$fake.directories.Add($Path)}.GetNewClosure()
    $write={param($Path,$Value)$fake.writes.Add([pscustomobject]@{path=$Path;value=$Value})}.GetNewClosure()
    $clock={return [DateTime]::Parse('2026-04-05T06:07:08Z').ToUniversalTime()}.GetNewClosure()
    $id={return '0123456789abcdef0123456789abcdef'}.GetNewClosure()
    $dependencies=New-AtaraxiaSessionStoreDependencies -PathExists $exists -CreateDirectory $mkdir -WriteJson $write -UtcNow $clock -NewId $id
    $contracts=Read-Json (Join-Path $projectRoot 'configs/role-contracts.json')
    $session=New-AtaraxiaSession 'C:\virtual\project' $contracts 'Injected session' $dependencies
    Assert-True ($session.id -eq 'session-20260405-060708-01234567' -and $session.created_at -eq '2026-04-05T06:07:08.0000000Z') 'Session id or timestamp did not use injected values.'
    Assert-True ($fake.directories.Count -eq 3 -and $fake.writes.Count -eq 2 -and $fake.writes[0].value.name -eq $session.id -and $fake.writes[1].value.artifact_type -eq 'session') 'Session creation bypassed injected directory or JSON persistence adapters.'
    $cleanup=[System.Collections.Generic.List[string]]::new();$failedWrites={param($Path,$Value)if($Path -like '*session.json'){throw 'metadata write failed'}};$removeSession={param($Path)$cleanup.Add($Path)|Out-Null}.GetNewClosure()
    $failureDependencies=New-AtaraxiaSessionStoreDependencies -PathExists $exists -CreateDirectory $mkdir -WriteJson $failedWrites -UtcNow $clock -NewId $id -RemoveDirectory $removeSession;$createRejected=$false;$sessionFailureMessage=''
    try{$null=New-AtaraxiaSession 'C:\virtual\project' $contracts 'Partial session' $failureDependencies}catch{$createRejected=$true;$sessionFailureMessage=$_.Exception.Message}
    Assert-True ($createRejected -and $cleanup.Count -eq 2 -and $cleanup[0] -eq 'C:\virtual\project\sessions\session-20260405-060708-01234567' -and $cleanup[1] -eq 'C:\virtual\project\sessions' -and $sessionFailureMessage -match 'metadata write failed') 'A partially created session or its newly created sessions directory was left behind, or the original persistence failure was hidden.'
    $cleanup.Clear();$failedCleanup={param($Path)throw 'cleanup failed'};$cleanupFailureDependencies=New-AtaraxiaSessionStoreDependencies -PathExists $exists -CreateDirectory $mkdir -WriteJson $failedWrites -UtcNow $clock -NewId $id -RemoveDirectory $failedCleanup;$cleanupFailureMessage=''
    try{$null=New-AtaraxiaSession 'C:\virtual\project' $contracts 'Partial session' $cleanupFailureDependencies}catch{$cleanupFailureMessage=$_.Exception.Message}
    Assert-True ($cleanupFailureMessage -match 'metadata write failed' -and $cleanupFailureMessage -match 'cleanup failed' -and $cleanupFailureMessage -match 'session-20260405-060708-01234567') 'A failed session cleanup hid the residual session path or the original error.'
    $temporaryRoot=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-session-rollback-'+[guid]::NewGuid().ToString('N'));$temporaryProject=Join-Path $temporaryRoot 'project';New-Item -ItemType Directory -Path $temporaryProject -Force|Out-Null
    $realFailureDependencies=New-AtaraxiaSessionStoreDependencies -PathExists {param($Path)[IO.Directory]::Exists($Path)} -WriteJson {param($Path,$Value)if($Path -like '*session.json'){throw 'real store failure'};Write-AtaraxiaJsonStoreFile $Path $Value}
    try{try{$null=New-AtaraxiaSession $temporaryProject $contracts 'Rollback check' $realFailureDependencies}catch{};Assert-True (-not [IO.Directory]::Exists((Join-Path $temporaryProject 'sessions'))) 'The default filesystem adapter left a partially written session or its newly created parent directory behind.'}finally{Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

Test-Case 'Allowlisted command execution uses an injected process runner' {
    . (Join-Path $projectRoot 'scripts/AgentHarness.ps1')
    $source=Get-Content -Raw (Join-Path $projectRoot 'scripts/AgentHarness.ps1')
    $settings=Read-Json (Join-Path $projectRoot 'configs/agent-harness.json')
    $probe=[pscustomobject]@{calls=0;command=$null;workspace=''}
    $run={param($Resolved,$WorkspaceDirectory)$probe.calls++;$probe.command=$Resolved;$probe.workspace=$WorkspaceDirectory;return [pscustomobject]@{exit_code=0;timed_out=$false;duration_ms=12;stdout="ok`0`e[31mred`e[0m";stderr=''}}.GetNewClosure()
    $dependencies=New-AgentHarnessDependencies -RunCommand $run
    $result=Invoke-AgentAllowedCommand $settings 'C:\work' ([pscustomobject]@{command_id='git_status';arguments=@('status','--short')}) $dependencies
    Assert-True ($probe.calls -eq 1 -and $probe.command.id -eq 'git_status' -and $probe.workspace -eq 'C:\work') 'Allowlist validation did not precede the injected runner or pass the workspace.'
    Assert-True ($result.exit_code -eq 0 -and $result.duration_ms -eq 12 -and $result.stdout -eq 'okred') 'Injected process output was not normalized through the normal result boundary.'
    $rejected=$false;try{$null=Invoke-AgentAllowedCommand $settings 'C:\work' ([pscustomobject]@{command_id='not_allowed';arguments=@()}) $dependencies}catch{$rejected=$true}
    Assert-True ($rejected -and $probe.calls -eq 1) 'An unlisted command reached the injected process runner.'
    Assert-True ($source -notmatch 'ProcessStartInfo|Invoke-AgentNativeCommand') 'AgentHarness still owns the concrete process adapter.'
}

Test-Case 'Process runner port validates adapters and keeps results deterministic' {
    . (Join-Path $projectRoot 'scripts/ProcessRunnerPort.ps1')
    $harnessSource=Get-Content -Raw (Join-Path $projectRoot 'scripts/AgentHarness.ps1')
    $compositionSource=Get-Content -Raw (Join-Path $projectRoot 'scripts/Invoke-Agent.ps1')
    $adapterSource=Get-Content -Raw (Join-Path $projectRoot 'scripts/PowerShellProcessRunner.ps1')
    Assert-True ($harnessSource -notmatch 'ProcessStartInfo|\.Kill\(\)|Invoke-AtaraxiaPowerShellProcess' -and $compositionSource -match 'PowerShellProcessRunner\.ps1' -and $compositionSource -match 'Invoke-AgentCommandBatch .*\$commandExecutionDependencies' -and $adapterSource -match 'ProcessStartInfo') 'Process execution adapter is not isolated and wired at the CLI composition root.'
    $probe=[pscustomobject]@{calls=0;id='';workspace=''}
    $runner={param($Resolved,$WorkspaceDirectory)$probe.calls++;$probe.id=$Resolved.id;$probe.workspace=$WorkspaceDirectory;return [pscustomobject]@{exit_code=7;timed_out=$false;duration_ms=25L;stdout='out';stderr='err'}}.GetNewClosure()
    $dependencies=New-AgentHarnessDependencies -RunCommand $runner
    $resolved=[pscustomobject]@{id='git_status';executable='git';argument_text='status --short';timeout_seconds=5}
    $result=Invoke-AgentProcessRunner $dependencies $resolved 'C:\work'
    Assert-True ($probe.calls -eq 1 -and $probe.id -eq 'git_status' -and $probe.workspace -eq 'C:\work' -and $result.exit_code -eq 7 -and $result.stderr -eq 'err') 'Process runner port did not forward arguments or preserve the result contract.'
    foreach($bad in @($null,[pscustomobject]@{exit_code='7';timed_out=$false;duration_ms=1;stdout='';stderr=''},[pscustomobject]@{exit_code=0;timed_out='false';duration_ms=1;stdout='';stderr=''},[pscustomobject]@{exit_code=0;timed_out=$false;duration_ms=-1;stdout='';stderr=''},[pscustomobject]@{exit_code=0;timed_out=$false;duration_ms=1;stdout=@('bad');stderr=''})){
        $badRunner={param($Resolved,$WorkspaceDirectory)$bad}.GetNewClosure();$badDependencies=New-AgentHarnessDependencies -RunCommand $badRunner;$rejected=$false;try{$null=Invoke-AgentProcessRunner $badDependencies $resolved 'C:\work'}catch{$rejected=$true};Assert-True $rejected 'An invalid process adapter result crossed the port boundary.'
    }
    $rejected=$false;try{$null=New-AgentHarnessDependencies}catch{$rejected=$true};Assert-True $rejected 'A process runner dependency was allowed to be absent.'
}

Test-Case 'Task execution lock rejects concurrent writers and releases cleanly' {
    . (Join-Path $projectRoot 'scripts/TaskExecutionLock.ps1')
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-task-lock-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $root -Force|Out-Null
    $lockPath=Join-Path $root '.ataraxia-run.lock';$first=$null;$second=$null
    try {
        $first=Enter-AgentTaskExecutionLock $lockPath
        $rejected=$false;try{$second=Enter-AgentTaskExecutionLock $lockPath}catch{$rejected=$true}
        Assert-True ($rejected -and $null -eq $second) 'A second process acquired a task lock already held by the first.'
        Exit-AgentTaskExecutionLock $first;$first=$null
        $second=Enter-AgentTaskExecutionLock $lockPath
        Assert-True ($null -ne $second -and (Test-Path -LiteralPath $lockPath -PathType Leaf)) 'Task lock could not be reacquired after release.'
    } finally {if($null -ne $first){Exit-AgentTaskExecutionLock $first};if($null -ne $second){Exit-AgentTaskExecutionLock $second};Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
    $calls=[System.Collections.Generic.List[string]]::new();$acquire={param($Path)$calls.Add('acquire');[pscustomobject]@{path=$Path}}.GetNewClosure();$release={param($Lock)$calls.Add('release')}.GetNewClosure();$adapter=New-AgentTaskExecutionLockDependencies $acquire $release;$token=Enter-AgentTaskExecutionLock 'C:\virtual\task.lock' $adapter;Exit-AgentTaskExecutionLock $token $adapter
    Assert-True ($calls.Count -eq 2 -and $calls[0] -eq 'acquire' -and $calls[1] -eq 'release') 'Task lock lifecycle bypassed injected acquire/release adapters.'
    $compositionSource=Get-Content -Raw (Join-Path $projectRoot 'scripts/Invoke-Agent.ps1')
    Assert-True ($compositionSource -match 'TaskExecutionLock\.ps1' -and $compositionSource -match 'Enter-AgentTaskExecutionLock' -and $compositionSource -match 'Exit-AgentTaskExecutionLock') 'CLI does not hold the task lock through the complete state/workspace mutation lifecycle.'
    Assert-True ($compositionSource -notmatch 'Test-Path|Get-Item|ReadAllText|ReadAllBytes|WriteAllText|WriteAllBytes|Set-Content|Move-Item|New-Item') 'CLI composition still performs direct filesystem operations instead of using storage ports.'
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

Test-Case 'SVG geometry parser is pure and conversation view accepts icon data' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'GuiConversationModel.ps1')
    $svg='<svg xmlns="http://www.w3.org/2000/svg"><path d="M1 2 L3 4"/><circle cx="5" cy="6" r="2"/><rect x="1" y="2" width="3" height="4"/></svg>'
    $geometry=ConvertFrom-AtaraxiaSvgGeometry $svg
    Assert-True ($geometry -match 'M1 2 L3 4' -and $geometry -match 'A2,2' -and $geometry -match 'H4 V6') 'SVG path, circle, or rectangle geometry was not projected.'
    $conversation=[pscustomobject]@{entries=@()};$state=[pscustomobject]@{history=@([pscustomobject]@{role='planner';timestamp='2026-01-01T00:00:00Z';report=[pscustomobject]@{heading='Plan';body='details'}})}
    $icons=@{planner=$geometry};$view=ConvertTo-AtaraxiaConversationView $conversation $state $icons
    Assert-True ($view.Count -eq 1 -and $view[0].icon_geometry -eq $geometry) 'Conversation view did not use injected role icon geometry.'
    $empty=ConvertTo-AtaraxiaConversationView $conversation $state
    Assert-True ([string]::IsNullOrEmpty($empty[0].icon_geometry)) 'Conversation view relied on hidden global icon state.'
    . (Join-Path $projectRoot 'scripts/adapters/WpfIconAssetAdapter.ps1');$roleAssets=Get-AtaraxiaRoleIconGeometry (Join-Path $projectRoot 'assets/role-icons');Assert-True ($roleAssets.Contains('planner') -and $roleAssets.planner -match 'M' -and (Get-AtaraxiaSvgGeometryFromFile (Join-Path $projectRoot 'assets/role-icons/missing.svg')) -eq '') 'SVG asset adapter did not load role geometry or handle a missing optional asset.'
}

Test-Case 'GUI application models resolve session paths and process updates without WPF' {
    . (Join-Path $projectRoot 'scripts/GuiApplication.ps1')
    . (Join-Path $projectRoot 'scripts/adapters/PowerShellGuiProcessOutputAdapter.ps1')
    . (Join-Path $projectRoot 'scripts/adapters/TcpConnectionAdapter.ps1')
    $probes=[System.Collections.Generic.List[object]]::new();$probe={param($HostName,$Port,$TimeoutMilliseconds)$probes.Add([pscustomobject]@{host=$HostName;port=$Port;timeout=$TimeoutMilliseconds});return $true}.GetNewClosure()
    $connected=Test-AtaraxiaGuiServiceConnection -Endpoint 'http://localhost:5001/api' -Probe $probe -TimeoutMilliseconds 125
    $rejected=Test-AtaraxiaGuiServiceConnection -Endpoint 'not-a-uri' -Probe $probe -TimeoutMilliseconds 125
    $probeFailure=Test-AtaraxiaGuiServiceConnection -Endpoint 'http://localhost:5001/api' -Probe {throw 'probe failed'}
    Assert-True ($connected -and -not $rejected -and -not $probeFailure -and $probes.Count -eq 1 -and $probes[0].host -eq 'localhost' -and $probes[0].port -eq 5001 -and $probes[0].timeout -eq 125) 'GUI service connection model did not validate the endpoint or safely handle injected probe failures.'
    Assert-True (-not (Test-AtaraxiaTcpEndpoint -HostName 'localhost' -Port 0)) 'TCP connection adapter accepted an invalid port.'
    $outputPaths=New-AtaraxiaGuiProcessOutputPaths
    Assert-True ($outputPaths.stdout -ne $outputPaths.stderr -and $outputPaths.stdout -match 'ataraxia-agent-' -and $outputPaths.stderr -eq ($outputPaths.stdout+'.err')) 'Process output adapter did not allocate a unique stdout/stderr path pair.'
    $outputDir=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-output-test-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory -Path $outputDir)
    try {
        $stdoutPath=Join-Path $outputDir 'stdout.log';$stderrPath=Join-Path $outputDir 'stderr.log'
        [IO.File]::WriteAllLines($stdoutPath,@('noise','Run: planner','Run: reviewer'),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($stderrPath,"diagnostic`0 detail",[Text.UTF8Encoding]::new($false))
        $output=Read-AtaraxiaGuiProcessOutput $stdoutPath $stderrPath 1
        Assert-True ($output.lines.Count -eq 2 -and $output.lines[0] -eq 'Run: planner' -and $output.next_index -eq 3 -and $output.error_text.Contains("`0")) 'Process output adapter did not return only unread stdout lines with the current stderr content.'
        Remove-AtaraxiaGuiProcessOutputFiles $stdoutPath $stderrPath
        Assert-True (-not (Test-Path $stdoutPath) -and -not (Test-Path $stderrPath)) 'Process output adapter did not clean up redirected files.'
    } finally {Remove-Item -LiteralPath $outputDir -Recurse -Force -ErrorAction SilentlyContinue}
    Assert-True ((Resolve-AtaraxiaGuiKoboldStatus $true $false $false) -eq 'connected' -and (Resolve-AtaraxiaGuiKoboldStatus $false $true $false) -eq 'starting' -and (Resolve-AtaraxiaGuiKoboldStatus $false $false $true) -eq 'starting' -and (Resolve-AtaraxiaGuiKoboldStatus $false $false $false) -eq 'disconnected' -and (Resolve-AtaraxiaGuiKoboldStatus $true $true $false) -eq 'connected') 'KoboldCpp UI status does not resolve API, managed process, and setup states consistently.'
    $restartEvents=[System.Collections.Generic.List[string]]::new();$restartState=[pscustomobject]@{ticks=0}
    $restartSave={$restartEvents.Add('save')}.GetNewClosure();$restartStop={$restartEvents.Add('stop')}.GetNewClosure()
    $restartProbe={return $restartState.ticks -lt 2}.GetNewClosure();$restartWait={param($milliseconds)$restartEvents.Add("wait:$milliseconds");$restartState.ticks++}.GetNewClosure()
    $restartClock={[datetime]::UtcNow.AddSeconds($restartState.ticks)}.GetNewClosure();$restartStart={$restartEvents.Add('start')}.GetNewClosure()
    $restart=Invoke-AtaraxiaGuiKoboldRestart $true $restartSave $restartStop $restartProbe $restartWait $restartClock $restartStart 10 250
    Assert-True ($restart.restarted -and $restart.reason -eq '' -and (@($restartEvents) -join ',') -eq 'save,stop,wait:250,wait:250,start') 'KoboldCpp restart did not save, stop, wait for the port, and restart in order through injected dependencies.'
    $unmanaged=Invoke-AtaraxiaGuiKoboldRestart $false $restartSave $restartStop $restartProbe $restartWait $restartClock $restartStart
    Assert-True (-not $unmanaged.restarted -and $unmanaged.reason -eq 'managed_process_required' -and $restartEvents.Count -eq 5) 'KoboldCpp restart did not reject an unmanaged process before invoking effects.'
    $busyState=[pscustomobject]@{ticks=0};$busyWait={param($milliseconds)$busyState.ticks++}.GetNewClosure();$busyClock={[datetime]::UtcNow.AddSeconds($busyState.ticks)}.GetNewClosure();$alwaysReachable={return $true}
    $busy=Invoke-AtaraxiaGuiKoboldRestart $true {$null=$null} {$null=$null} $alwaysReachable $busyWait $busyClock {throw 'Must not restart while the port is occupied.'} 1 500
    Assert-True (-not $busy.restarted -and $busy.reason -eq 'port_busy' -and $busyState.ticks -eq 1) 'KoboldCpp restart did not stop at the injected timeout while the service port remained occupied.'
    $saveFailureEvents=[System.Collections.Generic.List[string]]::new();$saveFailed=$false
    $saveFailureSave={$saveFailureEvents.Add('save')|Out-Null;throw 'save failed'}.GetNewClosure();$saveFailureStop={$saveFailureEvents.Add('stop')|Out-Null}.GetNewClosure();$saveFailureProbe={return $false};$saveFailureWait={param($Milliseconds)};$saveFailureClock={[datetime]::UtcNow};$saveFailureStart={$saveFailureEvents.Add('start')|Out-Null}.GetNewClosure()
    try{$null=Invoke-AtaraxiaGuiKoboldRestart $true $saveFailureSave $saveFailureStop $saveFailureProbe $saveFailureWait $saveFailureClock $saveFailureStart}catch{$saveFailed=$true}
    Assert-True ($saveFailed -and ($saveFailureEvents -join ',') -eq 'save') 'KoboldCpp restart continued to stop or start the process after saving settings failed.'
    $selectionState=New-AtaraxiaGuiSessionSelectionState
    $syncing=Set-AtaraxiaGuiSessionSelectionSynchronization $selectionState $true
    $userSelection=Set-AtaraxiaGuiSessionSelectionSynchronization $syncing.state $false
    Assert-True ($syncing.state.is_synchronizing -and -not $syncing.selection_requested -and -not $userSelection.state.is_synchronizing -and $userSelection.selection_requested) 'Programmatic session selector synchronization was not distinguished from user selection.'
    $read={param($Path) return [pscustomobject]@{task_file='session-1.task.json'}}
    $selection=Resolve-AtaraxiaGuiSessionTaskPath -ProjectPath 'C:\work\Research' -SessionPath 'C:\work\Research\sessions\session-1' -ReadMetadata $read
    Assert-True ($selection.task_path -eq 'C:\work\Research\sessions\session-1\session-1.task.json' -and $selection.session_path -eq 'C:\work\Research\sessions\session-1') 'GUI application model returned an incorrect session task path.'
    $activated=[System.Collections.Generic.List[string]]::new();$activate={param($Name)$activated.Add($Name)}.GetNewClosure()
    $opened=Open-AtaraxiaGuiProjectSession 'C:\work\Research' 'C:\work\Research\sessions\session-1' 'Other' $read $activate
    Assert-True ($opened.activated_project -and $opened.project_name -eq 'Research' -and $activated.Count -eq 1 -and $activated[0] -eq 'Research') 'Opening a session did not activate its owning project exactly once.'
    $same=Open-AtaraxiaGuiProjectSession 'C:\work\Research' 'C:\work\Research\sessions\session-1' 'Research' $read $activate
    Assert-True (-not $same.activated_project -and $activated.Count -eq 1) 'Opening a session in the active project performed an unnecessary activation.'
    $rejected=$false;try{$null=Open-AtaraxiaGuiProjectSession 'C:\work\Research' 'C:\work\Other\session-1' 'Other' $read $activate}catch{$rejected=$true}
    Assert-True ($rejected -and $activated.Count -eq 1) 'A session outside its project triggered a project change.'
    $listProjects={param($Root)@('Research','Studio')};$resolve={param($Root,$Name)(Join-Path $Root $Name)};$listSessions={param($Path)@([pscustomobject]@{path=(Join-Path $Path 'sessions/s1');title='Recent'})};$recent={param($Root,$Max)@([pscustomobject]@{project_name='Research'})|Select-Object -First $Max};$exists={param($Path)$false};$createdProjects=[System.Collections.Generic.List[string]]::new();$createdSessions=[System.Collections.Generic.List[string]]::new();$renamed=[System.Collections.Generic.List[string]]::new();$createProject={param($Root,$Name)$createdProjects.Add($Name)}.GetNewClosure();$renameProject={param($Root,$Old,$New)$renamed.Add("$Old->$New");Join-Path $Root $New}.GetNewClosure();$createSession={param($Path,$Contracts,$Title)$createdSessions.Add($Path);[pscustomobject]@{path=(Join-Path $Path 'sessions/s2');task_file='s2.task.json'}}.GetNewClosure();$renameSession={param($Path,$Title,$Source)[pscustomobject]@{path=$Path;title=$Title;title_source=$Source}};$activate={param($Name)$activated.Add($Name)}.GetNewClosure();$deps=New-AtaraxiaGuiProjectSessionDependencies $listProjects $resolve $listSessions $recent $exists $createProject $renameProject $createSession $renameSession $activate
    $overview=Get-AtaraxiaGuiProjectSessionOverview $deps 'C:\work' 'Studio' 1
    Assert-True ($overview.projects.Count -eq 2 -and $overview.projects[1].is_active -and $overview.projects[0].sessions.Count -eq 1 -and $overview.recent_sessions.Count -eq 1) 'Project/session overview did not assemble its view model from the ports.'
    $directOverview=Build-AtaraxiaGuiProjectSessionOverview 'C:\work' 'Research' 1 $listProjects $resolve $listSessions $recent
    Assert-True ($directOverview.projects.Count -eq 2 -and $directOverview.projects[0].sessions.Count -eq 1 -and $directOverview.recent_sessions.Count -eq 1) 'Project/session overview builder depends on a caller-scope Dependencies variable.'
    $readerCalls=[System.Collections.Generic.List[string]]::new();$jsonReader={param($Path)$readerCalls.Add($Path)|Out-Null;[pscustomobject]@{task_file='session.task.json'}}.GetNewClosure()
    $sessionsWithReader={param($Path,$Reader)if($Reader -isnot [scriptblock]){throw 'Session metadata reader was not forwarded.'};$readerCalls.Add('sessions')|Out-Null;& $Reader (Join-Path $Path 'session.json')|Out-Null;@([pscustomobject]@{path=(Join-Path $Path 'sessions/s1')})}.GetNewClosure()
    $recentWithReader={param($Root,$Max,$Reader)if($Reader -isnot [scriptblock]){throw 'Recent-session metadata reader was not forwarded.'};$readerCalls.Add('recent')|Out-Null;@([pscustomobject]@{project_name='Research'})|Select-Object -First $Max}.GetNewClosure()
    $readerDeps=New-AtaraxiaGuiProjectSessionDependencies $listProjects $resolve $sessionsWithReader $recentWithReader $exists $createProject $renameProject $createSession $renameSession $activate
    $readerDeps|Add-Member -NotePropertyName json_reader -NotePropertyValue $jsonReader
    $readerOverview=Get-AtaraxiaGuiProjectSessionOverview $readerDeps 'C:\work' 'Research' 1
    Assert-True ($readerOverview.projects.Count -eq 2 -and $readerCalls.Contains('sessions') -and $readerCalls.Contains('recent') -and @($readerCalls|Where-Object{$_ -like '*session.json'}).Count -eq 2) 'Project/session overview did not explicitly forward its injected JSON reader to both session stores.'
    $emptyProjects={param($Root)@()};$observedLimit=[pscustomobject]@{value=-1};$recentLimitProbe={param($Root,$Maximum)$observedLimit.value=$Maximum;@()}.GetNewClosure()
    $emptyOverview=Build-AtaraxiaGuiProjectSessionOverview 'C:\work' 'Research' -2 $emptyProjects $resolve $listSessions $recentLimitProbe
    Assert-True ($emptyOverview.projects.Count -eq 0 -and $emptyOverview.recent_sessions -is [System.Array] -and $emptyOverview.recent_sessions.Count -eq 0 -and $observedLimit.value -eq 0) 'Project/session overview did not return a stable empty array or clamp a negative recent-session limit to zero.'
    $noSessions={param($Path)@()};$emptyProjectOverview=Build-AtaraxiaGuiProjectSessionOverview 'C:\work' 'Research' 1 $listProjects $resolve $noSessions $recentLimitProbe
    Assert-True ($emptyProjectOverview.projects.Count -eq 2 -and $emptyProjectOverview.projects[0].sessions -is [System.Array] -and $emptyProjectOverview.projects[0].sessions.Count -eq 0) 'A project with no sessions did not expose a stable empty session array.'
    $projectsCalls=[pscustomobject]@{count=0};$countProjects={param($Root)$projectsCalls.count++;@()}.GetNewClosure();$invalidPortsRejected=$false
    try{$null=Build-AtaraxiaGuiProjectSessionOverview 'C:\work' 'Research' 5 $null $resolve $listSessions $recent}catch{$invalidPortsRejected=$true}
    Assert-True ($invalidPortsRejected -and $projectsCalls.count -eq 0) 'Project/session overview invoked a store before rejecting an incomplete adapter set.'
    $prepared=Prepare-AtaraxiaGuiProject $deps 'C:\work' 'Studio' 'Research'
    Assert-True ($prepared.created_project -and $prepared.activated_project -and $createdProjects[0] -eq 'Studio') 'Preparing a new session project did not create and activate its project.'
    $renamedProject=Rename-AtaraxiaGuiProject $deps 'C:\work' 'Studio' 'Studio2' 'Studio'
    Assert-True ($renamedProject.active_project_changed -and $renamed[0] -eq 'Studio->Studio2') 'Active project rename did not move and reactivate the new project name.'
    $renameState=[pscustomobject]@{name='Research'};$renameEvents=[System.Collections.Generic.List[string]]::new()
    $compensatingRename={param($Root,$Old,$New)if($renameState.name -cne $Old){throw "Unexpected project path rename: $($renameState.name) -> $Old"};$renameEvents.Add("rename:$Old->$New")|Out-Null;$renameState.name=$New;Join-Path $Root $New}.GetNewClosure()
    $failingActivation={param($Name)$renameEvents.Add("activate:$Name")|Out-Null;if($Name -eq 'Research2'){throw 'activation failed'}}.GetNewClosure()
    $compensationFailed=$false;try{$null=Rename-AtaraxiaGuiProject ([pscustomobject]@{rename_project=$compensatingRename;activate_project=$failingActivation}) 'C:\work' 'Research' 'Research2' 'Research'}catch{$compensationFailed=$true}
    Assert-True ($compensationFailed -and $renameState.name -eq 'Research' -and ($renameEvents -join ',') -eq 'rename:Research->Research2,activate:Research2,rename:Research2->Research,activate:Research') 'A failed active-project switch left its renamed project path inconsistent instead of attempting compensation.'
    $failedRollbackEvents=[System.Collections.Generic.List[string]]::new();$failedRollbackState=[pscustomobject]@{name='Research'};$failedRollbackMessage='';$renameWithFailedRollback={param($Root,$Old,$New)$failedRollbackEvents.Add("rename:$Old->$New")|Out-Null;if($Old -eq 'Research2'){throw 'rename rollback failed'};$failedRollbackState.name=$New;Join-Path $Root $New}.GetNewClosure();$activationWithFailure={param($Name)$failedRollbackEvents.Add("activate:$Name")|Out-Null;if($Name -eq 'Research2'){throw 'activation failed'}}.GetNewClosure()
    try{$null=Rename-AtaraxiaGuiProject ([pscustomobject]@{rename_project=$renameWithFailedRollback;activate_project=$activationWithFailure}) 'C:\work' 'Research' 'Research2' 'Research'}catch{$failedRollbackMessage=$_.Exception.Message}
    Assert-True ($failedRollbackMessage -match 'activation failed' -and $failedRollbackMessage -match 'rename rollback failed' -and ($failedRollbackEvents -join ',') -eq 'rename:Research->Research2,activate:Research2,rename:Research2->Research') 'A failed path rollback was masked or triggered an activation against the missing old path.'
    $createFailureEvents=[System.Collections.Generic.List[string]]::new();$createFailed=$false;$failedCreateProject={param($Root,$Name)$createFailureEvents.Add('create')|Out-Null;throw 'project creation failed'}.GetNewClosure();$failedCreateDeps=$deps.PSObject.Copy();$failedCreateDeps.create_project=$failedCreateProject;$failedCreateDeps.activate_project={param($Name)$createFailureEvents.Add('activate')|Out-Null}.GetNewClosure();$failedCreateDeps.create_session={param($Path,$Contracts,$Title)$createFailureEvents.Add('session')|Out-Null}.GetNewClosure()
    try{$null=New-AtaraxiaGuiSessionForProject $failedCreateDeps 'C:\work' 'NewProject' 'Research' ([pscustomobject]@{})}catch{$createFailed=$true}
    Assert-True ($createFailed -and ($createFailureEvents -join ',') -eq 'create') 'Session creation continued after the project store failed.'
    $activationFailureEvents=[System.Collections.Generic.List[string]]::new();$activationFailed=$false;$failedActivationDeps=$deps.PSObject.Copy();$failedActivationDeps.create_project={param($Root,$Name)$activationFailureEvents.Add('create')|Out-Null}.GetNewClosure();$failedActivationDeps.activate_project={param($Name)$activationFailureEvents.Add('activate')|Out-Null;throw 'activation failed'}.GetNewClosure();$failedActivationDeps.create_session={param($Path,$Contracts,$Title)$activationFailureEvents.Add('session')|Out-Null}.GetNewClosure();$failedActivationDeps.remove_project={param($Root,$Name)$activationFailureEvents.Add('remove')|Out-Null}.GetNewClosure()
    try{$null=New-AtaraxiaGuiSessionForProject $failedActivationDeps 'C:\work' 'NewProject' 'Research' ([pscustomobject]@{})}catch{$activationFailed=$true}
    Assert-True ($activationFailed -and ($activationFailureEvents -join ',') -eq 'create,activate,remove') 'Session creation continued after project activation failed or left the newly created project behind.'
    $prepareEvents=[System.Collections.Generic.List[string]]::new();$failedPrepareDeps=$deps.PSObject.Copy();$failedPrepareDeps.create_project={param($Root,$Name)$prepareEvents.Add('create')|Out-Null}.GetNewClosure();$failedPrepareDeps.activate_project={param($Name)$prepareEvents.Add('activate')|Out-Null;throw 'prepare activation failed'}.GetNewClosure();$failedPrepareDeps.remove_project={param($Root,$Name)$prepareEvents.Add('remove')|Out-Null}.GetNewClosure();$prepareFailed=$false
    try{$null=Prepare-AtaraxiaGuiProject $failedPrepareDeps 'C:\work' 'NewProject' 'Research'}catch{$prepareFailed=$true}
    Assert-True ($prepareFailed -and ($prepareEvents -join ',') -eq 'create,activate,remove') 'Project preparation left a newly created directory after activation failed.'
    $sessionFailureEvents=[System.Collections.Generic.List[string]]::new();$failedSessionDeps=$deps.PSObject.Copy();$failedSessionDeps.create_project={param($Root,$Name)$sessionFailureEvents.Add('create')|Out-Null}.GetNewClosure();$failedSessionDeps.activate_project={param($Name)$sessionFailureEvents.Add('activate')|Out-Null}.GetNewClosure();$failedSessionDeps.create_session={param($Path,$Contracts,$Title)$sessionFailureEvents.Add('session')|Out-Null;throw 'session failure'}.GetNewClosure();$failedSessionDeps.remove_project={param($Root,$Name)$sessionFailureEvents.Add('remove')|Out-Null}.GetNewClosure();$newSessionFailed=$false
    try{$null=New-AtaraxiaGuiSessionForProject $failedSessionDeps 'C:\work' 'NewProject' 'Research' ([pscustomobject]@{})}catch{$newSessionFailed=$true}
    Assert-True ($newSessionFailed -and ($sessionFailureEvents -join ',') -eq 'create,activate,session,remove') 'A failed first session creation left a newly created, unused project behind.'
    $cleanupProjectFailed=$false;$failedProjectCleanup=$failedPrepareDeps.PSObject.Copy();$failedProjectCleanup.remove_project={param($Root,$Name)throw 'project cleanup failed'}.GetNewClosure();$cleanupProjectMessage=''
    try{$null=Prepare-AtaraxiaGuiProject $failedProjectCleanup 'C:\work' 'NewProject' 'Research'}catch{$cleanupProjectMessage=$_.Exception.Message;$cleanupProjectFailed=$true}
    Assert-True ($cleanupProjectFailed -and $cleanupProjectMessage -match 'prepare activation failed' -and $cleanupProjectMessage -match 'project cleanup failed') 'Project cleanup failure hid the original activation failure.'
    $sessionResult=New-AtaraxiaGuiSessionForProject $deps 'C:\work' 'Research' 'Research' ([pscustomobject]@{})
    Assert-True ($sessionResult.task_path -eq (Join-Path $sessionResult.session.path 's2.task.json') -and $createdSessions.Count -eq 1) 'Session creation did not return a task selection model.'
    $renamedSession=Rename-AtaraxiaGuiSession $deps 'C:\work\Research\sessions\s1' 'Notes' 'user'
    Assert-True ($renamedSession.title -eq 'Notes' -and $renamedSession.title_source -eq 'user') 'Session title update did not return its updated model.'
    $rejected=$false;try{$null=Resolve-AtaraxiaGuiSessionTaskPath -ProjectPath 'C:\work\Research' -SessionPath 'C:\work\Other\session-1' -ReadMetadata $read}catch{$rejected=$true}
    Assert-True $rejected 'GUI application model accepted a session outside its project.'
    foreach($invalidTaskFile in @('', '..\outside.task.json', 'nested\task.json')){$badRead={param($Path)[pscustomobject]@{task_file=$invalidTaskFile}}.GetNewClosure();$badTaskRejected=$false;try{$null=Resolve-AtaraxiaGuiSessionTaskPath 'C:\work\Research' 'C:\work\Research\sessions\session-1' $badRead}catch{$badTaskRejected=$true};Assert-True $badTaskRejected "GUI session path accepted an unsafe or missing task filename: $invalidTaskFile"}
    $update=Get-AtaraxiaGuiProcessUpdate -Lines @('Run: planner','Run: reviewer') -ErrorText "bad`0 error"
    Assert-True ($update.role_events.Count -eq 2 -and $update.role_events[0].role -eq 'planner' -and $update.role_events[1].role -eq 'reviewer' -and $update.error_text -eq 'bad error' -and -not $update.PSObject.Properties['next_index']) 'GUI application model did not parse received role events, sanitize errors, and leave I/O cursor state to the adapter.'
}

Test-Case 'GUI startup plan handles relaunch arguments and splash policy without WPF' {
    . (Join-Path $projectRoot 'scripts/GuiApplication.ps1')
    $scriptPath='C:\Ataraxia Home\scripts\Start-AtaraxiaGui.ps1'
    $configPath='C:\Ataraxia Home\settings\gui config.json'
    $headless=New-AtaraxiaGuiStartupPlan -ScriptPath $scriptPath -ConfigPath $configPath -NoSplash
    Assert-True (-not $headless.show_splash -and $headless.argument_text.Contains('"'+$scriptPath+'"') -and $headless.argument_text.Contains('"'+$configPath+'"') -and $headless.argument_text -match '-NoSplash') 'Startup plan did not preserve quoted paths or the no-splash option.'
    $normal=New-AtaraxiaGuiStartupPlan -ScriptPath $scriptPath
    Assert-True ($normal.show_splash -and $normal.argument_text -notmatch '-NoSplash' -and $normal.argument_text -notmatch '-ConfigPath') 'Default startup plan changed splash behavior or added an absent config path.'
    $now=[DateTime]::UtcNow;$last=$now.AddMilliseconds(-2100);$recent=$now.AddMilliseconds(-500)
    Assert-True (Test-AtaraxiaGuiPollingIntervalElapsed $now $last 2000) 'GUI polling interval was not reached for an earlier timestamp.'
    Assert-True (-not (Test-AtaraxiaGuiPollingIntervalElapsed $now $recent 2000)) 'GUI polling interval fired before its elapsed duration.'
    $uninitialized=[DateTime]::MinValue;Assert-True (Test-AtaraxiaGuiPollingIntervalElapsed $now $uninitialized 2000) 'GUI polling interval did not treat an uninitialized timestamp as due.'
    $invalidIntervalRejected=$false;try{$null=Test-AtaraxiaGuiPollingIntervalElapsed $now $last -1}catch{$invalidIntervalRejected=$true};Assert-True $invalidIntervalRejected 'GUI polling interval accepted a negative duration.'
    $guiSource=Get-Content -Raw (Join-Path $projectRoot 'scripts/Start-AtaraxiaGui.ps1')
    Assert-True ($guiSource -match '\$now=\[DateTime\]::UtcNow;if\(Test-AtaraxiaGuiPollingIntervalElapsed \$now \$pollState\.last_poll 2000\)' -and $guiSource -notmatch '\[DateTime\]::UtcNow-\$script:lastKoboldPoll') 'GUI timer still subtracts DateTime values through PowerShell operator dispatch.'
    Assert-True ($guiSource -match '\$pollState=\[pscustomobject\]@\{last_poll=\[DateTime\]::MinValue\}' -and $guiSource -match 'Test-AtaraxiaGuiPollingIntervalElapsed \$now \$pollState\.last_poll 2000' -and $guiSource -notmatch '\$script:lastKoboldPoll') 'GUI timer captures its polling timestamp through a script-scoped variable that becomes null in Windows PowerShell 5.1 closures.'
    . (Join-Path $projectRoot 'scripts/GuiProcessApplication.ps1')
    $request=New-AtaraxiaGuiStartupRelaunchRequest 'C:\Program Files\PowerShell\pwsh.exe' $headless 'C:\Ataraxia Home'
    Assert-True ($request.executable -match 'pwsh\.exe$' -and $request.arguments -eq $headless.argument_text -and $request.working_directory -eq 'C:\Ataraxia Home' -and $request.stdout_path -eq '') 'STA relaunch request did not preserve its startup plan or working directory.'
}

Test-Case 'GUI instance identity is stable per config and differs across configs' {
    . (Join-Path $projectRoot 'scripts/GuiSingleInstance.ps1')
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-gui-instance-'+[guid]::NewGuid().ToString('N'))
    $config=Join-Path $root 'gui.json';$equivalent=Join-Path $root '.\gui.json';$other=Join-Path $root 'other.json'
    $identity=Get-AtaraxiaGuiInstanceIdentity $config;$same=Get-AtaraxiaGuiInstanceIdentity $equivalent;$sameCase=Get-AtaraxiaGuiInstanceIdentity $config.ToUpperInvariant();$separate=Get-AtaraxiaGuiInstanceIdentity $other
    Assert-True ($identity.config_path -eq [IO.Path]::GetFullPath($config) -and $identity.mutex_name -eq $same.mutex_name -and $identity.activation_event_name -eq $same.activation_event_name -and $identity.mutex_name -eq $sameCase.mutex_name) 'Equivalent or case-variant config paths do not resolve to the same GUI instance identity.'
    Assert-True ($identity.mutex_name -match '^Local\\Ataraxia\.Gui\.' -and $identity.activation_event_name -ne $same.mutex_name -and $identity.mutex_name -ne $separate.mutex_name -and $identity.activation_event_name -ne $separate.activation_event_name) 'GUI instance names are not scoped by normalized config path and Windows session.'
    $rejected=$false;try{$null=Get-AtaraxiaGuiInstanceIdentity ''}catch{$rejected=$true};Assert-True $rejected 'GUI instance identity accepted an empty config path.'
    $start=Get-Content -Raw (Join-Path $projectRoot 'scripts/Start-AtaraxiaGui.ps1');$viewPort=Get-Content -Raw (Join-Path $projectRoot 'scripts/GuiPresentationPort.ps1');$viewAdapter=Get-Content -Raw (Join-Path $projectRoot 'scripts/adapters/WpfGuiViewAdapter.ps1');$instanceAdapter=Get-Content -Raw (Join-Path $projectRoot 'scripts/adapters/PowerShellGuiSingleInstanceAdapter.ps1')
    Assert-True ($start -match 'Enter-AtaraxiaGuiInstance \(Get-AtaraxiaGuiInstanceIdentity \$ConfigPath\)' -and $start -match 'if\(-not \$script:guiInstance\.is_primary\)\{exit 0\}' -and $start -match 'Test-AtaraxiaGuiActivationRequested \$guiInstanceForPolling' -and $start -match 'activate_window ''main_window''' -and $start -match 'Exit-AtaraxiaGuiInstance \$script:guiInstance' -and $viewPort -match "ValidateSet\('activate_window'" -and $viewAdapter -match "'activate_window'" -and $viewAdapter -match '\$control\.WindowState=\[Windows\.WindowState\]::Normal' -and $instanceAdapter -match 'WaitOne\(0\)' -and $instanceAdapter -match '\$null=\$activationEvent\.Set\(\)') 'GUI startup does not acquire, signal, consume, activate, and release the per-config instance boundary.'
}

Test-Case 'GUI errors are logged with source details without modal dialogs' {
    . (Join-Path $projectRoot 'scripts/GuiErrorLogging.ps1')
    $writes=[System.Collections.Generic.List[string]]::new()
    $append={param($Path,$Contents)$writes.Add(([string]$Path+"`n"+[string]$Contents))}.GetNewClosure()
    $dependencies=New-AtaraxiaGuiErrorLogDependencies $append
    try{throw 'simulated GUI failure'}catch{$record=$_}
    $logged=Write-AtaraxiaGuiErrorLog $record 'test_action' 'C:\AtaraxiaLogs\gui-error.log' $dependencies
    Assert-True ($logged.written -and $logged.path -eq 'C:\AtaraxiaLogs\gui-error.log' -and $writes.Count -eq 1 -and $writes[0] -match 'simulated GUI failure' -and $writes[0] -match 'test_action' -and $writes[0] -match 'Script stack trace:') 'GUI error logging did not persist the exception, context, and script location through its injected writer.'
    $guiSource=Get-Content -Raw (Join-Path $projectRoot 'scripts/Start-AtaraxiaGui.ps1')
    Assert-True ($guiSource -notmatch 'Show-AtaraxiaMessageDialog[^\r\n]*-Kind error' -and $guiSource -match 'Write-AtaraxiaGuiErrorLog') 'GUI errors still open modal dialogs or bypass the error log.'
}

Test-Case 'Theme selection failures are logged without escaping the GUI event' {
    $guiSource=Get-Content -Raw (Join-Path $projectRoot 'scripts/Start-AtaraxiaGui.ps1')
    $themeAction=[regex]::Match($guiSource,"(?m)^Register-AtaraxiaGuiViewAction .*'theme_selector'.*$").Value
    $saveFunction=[regex]::Match($guiSource,'(?s)function Save-AtaraxiaThemePreference[^\r\n]*\{.*?\r?\n\}').Value
    Assert-True ($themeAction -match 'try\{Save-AtaraxiaThemePreference' -and $themeAction -match 'catch\{Report-AtaraxiaGuiError \$_ ''save_theme''\}' -and $saveFunction -match '\$ThemeSelector\.SelectedValue=\$script:themeState\.preference') 'Theme persistence errors can escape the WPF selection event or leave an uncommitted value selected.'
}

Test-Case 'GUI localized presentation model resolves labels and theme options' {
    . (Join-Path $projectRoot 'scripts/GuiLocalizedPresentation.ps1')
    $text={param($Key)"translated:$Key"}
    $presentation=New-AtaraxiaGuiLocalizedPresentation $text
    Assert-True ($presentation.window_title -eq '' -and $presentation.status_ready -eq 'translated:gui_ready' -and $presentation.labels.settings_general -eq 'translated:gui_task_settings' -and $presentation.labels.project_group -eq 'translated:gui_projects' -and $presentation.tooltips.new_session -eq 'translated:gui_new_session' -and $presentation.tooltips.edit_last -eq 'translated:gui_edit_last_query' -and $presentation.theme_options.Count -eq 3 -and $presentation.theme_options[0].key -eq 'system' -and $presentation.theme_options[2].label -eq 'translated:gui_theme_dark') 'Localized presentation data omitted labels, tooltips, status, or theme choices.'
    $missingResolverRejected=$false;try{$null=New-AtaraxiaGuiLocalizedPresentation $null}catch{$missingResolverRejected=$true};Assert-True $missingResolverRejected 'Localized presentation accepted a missing translation resolver.'
}

Test-Case 'GUI screen state initializes and resets task-scoped workflow state' {
    . (Join-Path $projectRoot 'scripts/GuiScreenState.ps1')
    $state=New-AtaraxiaGuiScreenState
    Assert-True ($state.task_path -eq '' -and -not $state.editing -and $state.pending_session_project -eq '' -and $state.project_tree_expanded.Count -eq 0 -and -not $state.recent_sessions_expanded) 'GUI screen state did not initialize its defaults.'
    $state.editing=$true;$state.pending_session_project='Draft';$state.project_tree_expanded=@{Research=$true};$state.recent_sessions_expanded=$true
    $loaded=Set-AtaraxiaGuiScreenTask $state (Join-Path $env:TEMP 'screen.task.json')
    Assert-True ([IO.Path]::IsPathRooted($loaded.task_path) -and -not $loaded.editing -and $loaded.pending_session_project -eq '') 'Loading a task did not normalize its path or clear pending/editing state.'
    $reset=Reset-AtaraxiaGuiScreenTask $loaded
    Assert-True ($reset.task_path -eq '' -and -not $reset.editing -and $reset.pending_session_project -eq '' -and $reset.project_tree_expanded.Research -and $reset.recent_sessions_expanded) 'Task reset did not clear task state while preserving drawer state.'
    $rejected=$false;try{$null=Set-AtaraxiaGuiScreenTask $state ''}catch{$rejected=$true};Assert-True $rejected 'GUI screen state accepted an empty task path.'
}

Test-Case 'GUI process state tracks output cursor role and terminal transitions' {
    . (Join-Path $projectRoot 'scripts/GuiProcessState.ps1')
    $state=New-AtaraxiaGuiProcessState
    Assert-True ($state.phase -eq 'idle' -and $state.output_line_count -eq 0 -and $state.current_role -eq '' -and $null -eq $state.exit_code) 'GUI process state did not initialize as idle.'
    $state=Start-AtaraxiaGuiProcessState $state
    $update=[pscustomobject]@{role_events=@([pscustomobject]@{role='planner'},[pscustomobject]@{role='reviewer'});next_index=8;error_text=''}
    $state=Update-AtaraxiaGuiProcessState $state $update
    Assert-True ($state.phase -eq 'running' -and $state.output_line_count -eq 8 -and $state.current_role -eq 'reviewer') 'GUI process state did not accept a valid role/output update.'
    $completed=Complete-AtaraxiaGuiProcessState $state 0
    Assert-True ($completed.phase -eq 'completed' -and $completed.exit_code -eq 0 -and $completed.current_role -eq '' -and $completed.output_line_count -eq 8) 'GUI process completion did not retain its cursor or clear transient role state.'
    $stopState=Start-AtaraxiaGuiProcessState (New-AtaraxiaGuiProcessState);$stopState=Update-AtaraxiaGuiProcessState $stopState $update;$stopped=Stop-AtaraxiaGuiProcessState $stopState
    Assert-True ($stopped.phase -eq 'stopped' -and $stopped.exit_code -eq $null -and $stopped.output_line_count -eq 8) 'GUI process stop did not retain output progress.'
    $regressionState=Start-AtaraxiaGuiProcessState (New-AtaraxiaGuiProcessState);$regressionState=Update-AtaraxiaGuiProcessState $regressionState $update
    $rejected=$false;try{$null=Update-AtaraxiaGuiProcessState $regressionState ([pscustomobject]@{role_events=@();next_index=2})}catch{$rejected=$true};Assert-True $rejected 'GUI process state accepted a regressing output cursor.'
}

Test-Case 'GUI process application coordinates polling completion and rollback intent' {
    . (Join-Path $projectRoot 'scripts/GuiProcessState.ps1')
    . (Join-Path $projectRoot 'scripts/GuiApplication.ps1')
    . (Join-Path $projectRoot 'scripts/GuiProcessApplication.ps1')
    $state=Start-AtaraxiaGuiProcessState (New-AtaraxiaGuiProcessState)
    $reader={param($Stdout,$Stderr,$StartIndex)[pscustomobject]@{lines=@('Run: planner','Run: reviewer');next_index=4;error_text=''}}
    $poll=Invoke-AtaraxiaGuiProcessPoll $state 'out' 'err' $reader
    Assert-True ($poll.state.current_role -eq 'reviewer' -and $poll.state.output_line_count -eq 4 -and $poll.presentation.kind -eq 'role' -and $poll.presentation.role -eq 'reviewer') 'Process polling did not combine adapter output with application role parsing and state updates.'
    $success=Complete-AtaraxiaGuiProcess $poll.state 0 'C:\tasks\one.task.json'
    $failure=Complete-AtaraxiaGuiProcess (Start-AtaraxiaGuiProcessState (New-AtaraxiaGuiProcessState)) 7 ''
    Assert-True ($success.state.phase -eq 'completed' -and $success.presentation.kind -eq 'ready' -and $success.refresh_session -and $failure.presentation.kind -eq 'failure' -and -not $failure.refresh_session) 'Process completion did not resolve status and refresh behavior.'
    $rollback=New-AtaraxiaGuiRollbackRequest 'C:\tasks\one.task.json' 'C:\app\configs\config.json'
    $noRollback=New-AtaraxiaGuiRollbackRequest '' 'C:\app\configs\config.json'
    Assert-True ($rollback.required -and $rollback.task_path -eq [IO.Path]::GetFullPath('C:\tasks\one.task.json') -and $rollback.config_path -eq [IO.Path]::GetFullPath('C:\app\configs\config.json') -and -not $noRollback.required) 'Rollback decision contains invalid task/configuration paths or runs without a loaded task.'
    $launch=New-AtaraxiaGuiAgentLaunchRequest 'C:\Program Files\PowerShell\pwsh.exe' 'C:\app\scripts\Invoke-Agent.ps1' 'C:\tasks\one.task.json' 'C:\app\configs\config.json' 'C:\app' 'C:\temp\agent.out' 'C:\temp\agent.err'
    Assert-True ($launch.executable -match 'pwsh\.exe$' -and $launch.working_directory -eq [IO.Path]::GetFullPath('C:\app') -and $launch.arguments -match '-Run' -and $launch.arguments -match '-Step -1' -and $launch.stdout_path -eq 'C:\temp\agent.out' -and $launch.stderr_path -eq 'C:\temp\agent.err') 'GUI application did not create a process launch request with task, config, and output paths.'
    $serviceRequest=New-AtaraxiaGuiChildProcessRequest 'C:\models\koboldcpp.exe' '--port 5001' 'C:\models'
    $rejected=$false;try{$null=New-AtaraxiaGuiChildProcessRequest 'C:\models\koboldcpp.exe' '--port 5001' 'C:\models' 'C:\temp\only.out' ''}catch{$rejected=$true}
    Assert-True ($serviceRequest.executable -match 'koboldcpp\.exe$' -and $serviceRequest.stdout_path -eq '' -and $rejected) 'Managed service launch request did not support no redirection or reject an incomplete output pair.'
    $rollbackLaunch=New-AtaraxiaGuiRollbackLaunchRequest 'C:\Program Files\PowerShell\pwsh.exe' 'C:\app\scripts\Invoke-Agent.ps1' 'C:\tasks\one.task.json' 'C:\app\configs\config.json' 'C:\app' 'C:\temp\rollback.out' 'C:\temp\rollback.err'
    Assert-True ($rollbackLaunch.required -and $rollbackLaunch.arguments -match '-Rollback' -and $rollbackLaunch.arguments -match 'config\.json') 'GUI application did not create a rollback process request.'
}

Test-Case 'GUI process adapter validates external process requests before launch' {
    . (Join-Path $projectRoot 'scripts/adapters/PowerShellGuiProcessAdapter.ps1')
    $rejected=$false;try{$null=Start-AtaraxiaGuiChildProcess ([pscustomobject]@{executable='';arguments='';working_directory='';stdout_path='';stderr_path=''})}catch{$rejected=$true};Assert-True $rejected 'GUI process adapter accepted an invalid executable or working directory.'
    $rejected=$false;try{$null=Get-AtaraxiaGuiChildProcessStatus $null}catch{$rejected=$true};Assert-True $rejected 'GUI process status adapter accepted a missing process handle.'
    $rejected=$false;try{$null=Stop-AtaraxiaGuiChildProcess $null}catch{$rejected=$true};Assert-True $rejected 'GUI process stop adapter accepted a missing process handle.'
    $guiScript=Get-Content -Raw (Join-Path $projectRoot 'scripts/Start-AtaraxiaGui.ps1')
    $koboldStart=[regex]::Match($guiScript,'(?s)function Start-KoboldCppFromGui\s*\{.*?\n\}').Value;$koboldSetup=[regex]::Match($guiScript,'(?s)function Start-KoboldCppAcquisitionIfMissing\s*\{.*?\n\}').Value
    Assert-True ($koboldStart -match 'Start-AtaraxiaGuiChildProcess' -and $koboldStart -notmatch 'Start-Process' -and $koboldSetup -match 'Start-AtaraxiaGuiChildProcess' -and $koboldSetup -notmatch 'Start-Process' -and $guiScript -notmatch '\$script:koboldProcess\.(Kill|WaitForExit|Refresh|Dispose)\(') 'KoboldCpp managed process creation or lifecycle bypasses the shared process adapter.'
}

Test-Case 'GUI navigation model resolves settings and conversation visibility' {
    . (Join-Path $projectRoot 'scripts/GuiNavigationState.ps1')
    $state=New-AtaraxiaGuiNavigationState
    Assert-True ($state.page -eq 'conversation' -and $state.project_drawer_open) 'GUI navigation did not start on the conversation page with the project drawer open.'
    $settings=Set-AtaraxiaGuiNavigationState $state 'open_settings'
    Assert-True ($settings.state.page -eq 'settings' -and -not $settings.state.project_drawer_open -and -not $settings.visibility.conversation_page -and $settings.visibility.settings_panel -and -not $settings.visibility.project_drawer) 'Opening settings did not resolve exclusive settings visibility.'
    $conversation=Set-AtaraxiaGuiNavigationState $settings.state 'close_settings'
    Assert-True ($conversation.state.page -eq 'conversation' -and $conversation.state.project_drawer_open -and $conversation.visibility.conversation_page -and -not $conversation.visibility.settings_panel -and $conversation.visibility.project_drawer) 'Closing settings did not restore conversation and project drawer visibility.'
    $rejected=$false;try{$null=Set-AtaraxiaGuiNavigationState $state 'unknown'}catch{$rejected=$true};Assert-True $rejected 'GUI navigation accepted an unknown action.'
}

Test-Case 'WPF localized presentation adapter applies neutral labels and theme choices' {
    . (Join-Path $projectRoot 'scripts/GuiLocalizedPresentation.ps1')
    . (Join-Path $projectRoot 'scripts/adapters/WpfGuiViewAdapter.ps1')
    $presentation=New-AtaraxiaGuiLocalizedPresentation {param($Key)"translated:$Key"}
    $controls=@{window=[pscustomobject]@{Title='old';Tag='old';Resources=@{ThemeOptionTemplate='theme-template'}};theme_selector=[pscustomobject]@{ItemsSource=@();ItemTemplate=$null;SelectedValuePath='';SelectedValue=''} }
    $bindings=@{settings_general_title='labels.settings_general';config_label='labels.runtime_config';theme_label='labels.theme';settings_model_title='labels.settings_model';project_prompt_button='tooltips.project_prompt';session_prompt_button='tooltips.session_prompt';project_group_title='labels.project_group';recent_sessions_title='labels.recent_sessions';new_project='tooltips.new_project';task_name_label='labels.task_name';workspace_label='labels.working_directory';browse_config='tooltips.browse_config';new_session='tooltips.new_session';other_session='tooltips.session_more';browse_task='tooltips.open_task';browse_workspace='tooltips.browse_folder';kobold_restart='tooltips.kobold_restart';model_file_label='labels.model_file';refresh_models='tooltips.refresh_models';conversation_label='labels.conversation';scroll_latest='tooltips.scroll_to_latest';create_task='tooltips.new_task';edit_last='tooltips.edit_last';run_task='tooltips.send_run';save_parameter_preset='labels.parameter_preset_save';save_as_parameter_preset='labels.parameter_preset_save_as';rename_parameter_preset='labels.parameter_preset_rename';delete_parameter_preset='labels.parameter_preset_delete'}
    foreach($target in $bindings.Keys){$property=if($target -in @('save_parameter_preset','save_as_parameter_preset','rename_parameter_preset','delete_parameter_preset')){'ToolTip'}elseif($bindings[$target].StartsWith('labels.')){'Text'}else{'ToolTip'};$controls[$target]=[pscustomobject]@{};$controls[$target]|Add-Member -NotePropertyName $property -NotePropertyValue ''}
    Set-AtaraxiaWpfLocalizedPresentation $controls $presentation 'dark'
    Assert-True ($controls.settings_general_title.Text -eq 'translated:gui_task_settings' -and $controls.project_group_title.Text -eq 'translated:gui_projects' -and $controls.new_session.ToolTip -eq 'translated:gui_new_session' -and $controls.save_parameter_preset.ToolTip -eq 'translated:gui_parameter_preset_save' -and $controls.delete_parameter_preset.ToolTip -eq 'translated:gui_parameter_preset_delete' -and $controls.window.Tag -eq 'translated:gui_copy_request' -and $controls.window.Title -eq '' -and $controls.theme_selector.ItemsSource.Count -eq 3 -and $controls.theme_selector.ItemTemplate -eq 'theme-template' -and $controls.theme_selector.SelectedValuePath -eq 'key' -and $controls.theme_selector.SelectedValue -eq 'dark') 'WPF localized presentation adapter failed to map translated display values to controls.'
}

Test-Case 'GUI input layout model calculates bounded multiline height' {
    . (Join-Path $projectRoot 'scripts/GuiInputLayout.ps1')
    $single=Get-AtaraxiaGuiInputHeight 1 14 8 48 160;$multi=Get-AtaraxiaGuiInputHeight 4 14 8 48 160;$bounded=Get-AtaraxiaGuiInputHeight 20 14 8 48 160;$fallback=Get-AtaraxiaGuiInputHeight 2 0 10 48 160;$empty=Get-AtaraxiaGuiInputHeight 0 14 8 48 160
    Assert-True ($single -eq 48 -and $multi -eq 92 -and $bounded -eq 160 -and $fallback -eq 52 -and $empty -eq 48) 'Multiline height did not account for line count and vertical padding within the configured bounds.'
    foreach($parameters in @(@(2,14,-1,48,160),@(2,14,8,160,48),@(2,[double]::NaN,8,48,160))){$rejected=$false;try{$null=Get-AtaraxiaGuiInputHeight @parameters}catch{$rejected=$true};Assert-True $rejected 'Input height accepted invalid padding, font size, or height bounds.'}
}

Test-Case 'GUI view port separates presentation updates from the UI framework' {
    . (Join-Path $projectRoot 'scripts/GuiPresentationPort.ps1')
    . (Join-Path $projectRoot 'scripts/GuiInputLayout.ps1')
    $calls=[System.Collections.Generic.List[object]]::new()
    $setItems={param($Target,$Items)$calls.Add([pscustomobject]@{kind='items';target=$Target;items=@($Items)})}.GetNewClosure()
    $setValue={param($Target,$Value)$calls.Add([pscustomobject]@{kind='value';target=$Target;value=$Value})}.GetNewClosure()
    $bindAction={param($Target,$Action,$Handler)$calls.Add([pscustomobject]@{kind='action';target=$Target;action=$Action;handler=$Handler})}.GetNewClosure()
    $schedule={param($Priority,$Callback)$calls.Add([pscustomobject]@{kind='schedule';priority=$Priority;callback=$Callback})}.GetNewClosure()
    $startTimer={param($Interval,$Callback)$handle=[pscustomobject]@{interval=$Interval;callback=$Callback};$calls.Add([pscustomobject]@{kind='timer_start';handle=$handle});return $handle}.GetNewClosure()
    $stopTimer={param($Handle)$calls.Add([pscustomobject]@{kind='timer_stop';handle=$Handle})}.GetNewClosure()
    $wait={param($Milliseconds)$calls.Add([pscustomobject]@{kind='wait';milliseconds=$Milliseconds})}.GetNewClosure()
    $registerTarget={param($Target,$Handle)$calls.Add([pscustomobject]@{kind='target';target=$Target;handle=$Handle})}.GetNewClosure()
    $setClipboard={param($Text)$calls.Add([pscustomobject]@{kind='clipboard';text=$Text})}.GetNewClosure()
    $invokeViewOperation={param($Operation,$Target,$Value)$calls.Add([pscustomobject]@{kind='view_operation';operation=$Operation;target=$Target;value=$Value})}.GetNewClosure()
    $port=New-AtaraxiaGuiViewPort $setItems $setValue $bindAction $schedule $startTimer $stopTimer $wait $registerTarget $setClipboard $invokeViewOperation
    $rows=@([pscustomobject]@{id='s1'},[pscustomobject]@{id='s2'})
    Set-AtaraxiaGuiViewItems $port 'sessions' $rows
    Set-AtaraxiaGuiViewValue $port 'status' 'Ready'
    $handler={param($Sender,$EventArgs)};Register-AtaraxiaGuiViewAction $port 'session_selector' 'selection_change' $handler
    $deferred={};Schedule-AtaraxiaGuiViewCallback $port 'layout_idle' $deferred
    $tick={};$timer=Start-AtaraxiaGuiViewTimer $port 250 $tick;Stop-AtaraxiaGuiViewTimer $port $timer;Wait-AtaraxiaGuiViewDelay $port 400
    Set-AtaraxiaGuiClipboardText $port 'session-123'
    Invoke-AtaraxiaGuiViewOperation $port activate_window 'main_window'
    Invoke-AtaraxiaGuiViewOperation $port focus 'goal'
    Invoke-AtaraxiaGuiViewOperation $port set_text_focus_end 'goal' 'Draft request'
    Invoke-AtaraxiaGuiViewOperation $port scroll_to_end 'conversation_scroll'
    Invoke-AtaraxiaGuiViewOperation $port toggle_expanded 'recent_sessions_group'
    Invoke-AtaraxiaGuiViewOperation $port open_context_menu 'other_session'
    Invoke-AtaraxiaGuiViewOperation $port sync_scroll_to_latest_visibility 'scroll_latest' 'conversation_scroll'
    Invoke-AtaraxiaGuiViewOperation $port update_multiline_input_height 'goal'
    Assert-True ($calls.Count -eq 16 -and $calls[0].kind -eq 'items' -and $calls[0].target -eq 'sessions' -and $calls[0].items.Count -eq 2 -and $calls[1].value -eq 'Ready' -and $calls[2].action -eq 'selection_change' -and $calls[2].handler -eq $handler -and $calls[3].kind -eq 'schedule' -and $calls[3].priority -eq 'layout_idle' -and $calls[3].callback -eq $deferred -and $calls[4].handle.interval -eq 250 -and $calls[5].handle -eq $timer -and $calls[6].milliseconds -eq 400 -and $calls[7].kind -eq 'clipboard' -and $calls[7].text -eq 'session-123' -and $calls[8].operation -eq 'activate_window' -and $calls[9].operation -eq 'focus' -and $calls[10].value -eq 'Draft request' -and $calls[11].operation -eq 'scroll_to_end' -and $calls[12].operation -eq 'toggle_expanded' -and $calls[13].operation -eq 'open_context_menu' -and $calls[14].operation -eq 'sync_scroll_to_latest_visibility' -and $calls[15].operation -eq 'update_multiline_input_height') 'Framework-neutral view port did not relay view updates, actions, clipboard, activation, view operations, timers, and delays.'
    $missingRejected=$false;try{$null=New-AtaraxiaGuiViewPort $null $setValue $bindAction $schedule $startTimer $stopTimer $wait $registerTarget $setClipboard $invokeViewOperation}catch{$missingRejected=$true}
    $missingClipboardRejected=$false;try{$null=New-AtaraxiaGuiViewPort $setItems $setValue $bindAction $schedule $startTimer $stopTimer $wait $registerTarget $null}catch{$missingClipboardRejected=$true}
    $missingViewOperationRejected=$false;try{$null=New-AtaraxiaGuiViewPort $setItems $setValue $bindAction $schedule $startTimer $stopTimer $wait $registerTarget $setClipboard $null}catch{$missingViewOperationRejected=$true}
    Assert-True ($missingRejected -and $missingClipboardRejected -and $missingViewOperationRejected) 'View port accepted a missing UI adapter operation.'
    . (Join-Path $projectRoot 'scripts/adapters/WpfGuiViewAdapter.ps1')
    $dispatcher=[pscustomobject]@{Invocations=[System.Collections.Generic.List[object]]::new()}
    Add-Member -InputObject $dispatcher -MemberType ScriptMethod -Name BeginInvoke -Value {param($Callback)$this.Invocations.Add($Callback)}
    $conversationControl=[pscustomobject]@{ItemsSource=@();ScrollPosition='';ScrollableHeight=100;VerticalOffset=0};Add-Member -InputObject $conversationControl -MemberType ScriptMethod -Name ScrollToEnd -Value {$this.ScrollPosition='end'};Add-Member -InputObject $conversationControl -MemberType ScriptMethod -Name ScrollToTop -Value {$this.ScrollPosition='top'};$statusControl=[pscustomobject]@{Text=''};$settingsViewControl=[pscustomobject]@{Visibility='Collapsed'};$goalControl=[pscustomobject]@{Text='';CaretIndex=0;Focused=$false;LineCount=4;FontSize=14;Padding=[pscustomobject]@{Top=4;Bottom=4};MinHeight=48;MaxHeight=160;Height=48};Add-Member -InputObject $goalControl -MemberType ScriptMethod -Name Focus -Value {$this.Focused=$true;return $true};$expanderControl=[pscustomobject]@{IsExpanded=$false};$contextMenu=[pscustomobject]@{PlacementTarget=$null;IsOpen=$false};$menuControl=[pscustomobject]@{ContextMenu=$contextMenu};$scrollButton=[pscustomobject]@{Visibility='Collapsed'}
    $adapterClipboard=[System.Collections.Generic.List[string]]::new();$wpfClipboard={param($Text)$adapterClipboard.Add([string]$Text)}.GetNewClosure()
    $wpfPort=New-AtaraxiaWpfGuiViewPort @{conversation=$conversationControl;conversation_scroll=$conversationControl;goal=$goalControl;status=$statusControl;settings_view=$settingsViewControl;recent_sessions_group=$expanderControl;other_session=$menuControl;scroll_latest=$scrollButton;dispatcher=$dispatcher} @{status='Text';settings_view='Visibility'} $wpfClipboard ${function:Get-AtaraxiaGuiInputHeight}
    Set-AtaraxiaGuiViewItems $wpfPort 'conversation' $rows;Set-AtaraxiaGuiViewValue $wpfPort 'status' 'Ready'
    Set-AtaraxiaGuiViewValue $wpfPort 'settings_view' $true
    Assert-True ($conversationControl.ItemsSource.Count -eq 2 -and $statusControl.Text -eq 'Ready' -and $settingsViewControl.Visibility -eq 'Visible') 'WPF adapter did not map collection, text, or abstract visibility updates to controls.'
    Set-AtaraxiaGuiViewValue $wpfPort 'settings_view' $false
    Assert-True ($settingsViewControl.Visibility -eq 'Collapsed') 'WPF adapter did not map a hidden view state to collapsed visibility.'
    $invalidVisibilityRejected=$false;try{Set-AtaraxiaGuiViewValue $wpfPort 'settings_view' 'Visible'}catch{$invalidVisibilityRejected=$true};Assert-True $invalidVisibilityRejected 'WPF visibility adapter accepted a non-boolean application state.'
    Set-AtaraxiaGuiClipboardText $wpfPort 'copied through WPF adapter'
    Assert-True ($adapterClipboard.Count -eq 1 -and $adapterClipboard[0] -eq 'copied through WPF adapter') 'WPF view adapter did not route clipboard text through its replaceable implementation.'
    Invoke-AtaraxiaGuiViewOperation $wpfPort focus 'goal';Invoke-AtaraxiaGuiViewOperation $wpfPort set_text_focus_end 'goal' 'Restored request';Invoke-AtaraxiaGuiViewOperation $wpfPort scroll_to_end 'conversation_scroll';Invoke-AtaraxiaGuiViewOperation $wpfPort toggle_expanded 'recent_sessions_group';Invoke-AtaraxiaGuiViewOperation $wpfPort open_context_menu 'other_session';Invoke-AtaraxiaGuiViewOperation $wpfPort sync_scroll_to_latest_visibility 'scroll_latest' 'conversation_scroll';Invoke-AtaraxiaGuiViewOperation $wpfPort update_multiline_input_height 'goal';Assert-True ($goalControl.Focused -and $goalControl.Text -eq 'Restored request' -and $goalControl.CaretIndex -eq $goalControl.Text.Length -and $conversationControl.ScrollPosition -eq 'end' -and $expanderControl.IsExpanded -and $contextMenu.IsOpen -and $contextMenu.PlacementTarget -eq $menuControl -and $scrollButton.Visibility -eq 'Visible' -and $goalControl.Height -eq 92) 'WPF adapter did not implement injected focus, edit-caret, scroll, expander, menu, scroll-button, or input-layout operations.'
    $scheduled={};Schedule-AtaraxiaGuiViewCallback $wpfPort 'normal' $scheduled
    Assert-True ($dispatcher.Invocations.Count -eq 1) 'WPF adapter did not schedule a deferred callback.'
    $eventControl=[pscustomobject]@{ClickHandler=$null;SelectionHandler=$null;TextHandler=$null;SizeHandler=$null;ValueHandler=$null;LostFocusHandler=$null;ExpandedHandler=$null;CollapsedHandler=$null;IsExpanded=$false;ScrollHandler=$null;ClosingHandler=$null;ContentHandler=$null;PreviewKeyHandler=$null}
    Add-Member -InputObject $eventControl -MemberType ScriptMethod -Name Add_Click -Value {param($ActionHandler)$this.ClickHandler=$ActionHandler}
    Add-Member -InputObject $eventControl -MemberType ScriptMethod -Name Add_SelectionChanged -Value {param($ActionHandler)$this.SelectionHandler=$ActionHandler}
    Add-Member -InputObject $eventControl -MemberType ScriptMethod -Name Add_TextChanged -Value {param($ActionHandler)$this.TextHandler=$ActionHandler}
    Add-Member -InputObject $eventControl -MemberType ScriptMethod -Name Add_SizeChanged -Value {param($ActionHandler)$this.SizeHandler=$ActionHandler}
    Add-Member -InputObject $eventControl -MemberType ScriptMethod -Name Add_ValueChanged -Value {param($ActionHandler)$this.ValueHandler=$ActionHandler}
    Add-Member -InputObject $eventControl -MemberType ScriptMethod -Name Add_LostFocus -Value {param($ActionHandler)$this.LostFocusHandler=$ActionHandler}
    Add-Member -InputObject $eventControl -MemberType ScriptMethod -Name Add_Expanded -Value {param($ActionHandler)$this.ExpandedHandler=$ActionHandler}
    Add-Member -InputObject $eventControl -MemberType ScriptMethod -Name Add_Collapsed -Value {param($ActionHandler)$this.CollapsedHandler=$ActionHandler}
    Add-Member -InputObject $eventControl -MemberType ScriptMethod -Name Add_ScrollChanged -Value {param($ActionHandler)$this.ScrollHandler=$ActionHandler}
    Add-Member -InputObject $eventControl -MemberType ScriptMethod -Name Add_Closing -Value {param($ActionHandler)$this.ClosingHandler=$ActionHandler}
    Add-Member -InputObject $eventControl -MemberType ScriptMethod -Name Add_ContentRendered -Value {param($ActionHandler)$this.ContentHandler=$ActionHandler}
    Add-Member -InputObject $eventControl -MemberType ScriptMethod -Name Add_PreviewKeyDown -Value {param($ActionHandler)$this.PreviewKeyHandler=$ActionHandler}
    $eventPort=New-AtaraxiaWpfGuiViewPort @{button=$eventControl;dispatcher=$dispatcher} @{} $null ${function:Get-AtaraxiaGuiInputHeight}
    Register-AtaraxiaGuiViewTarget $eventPort 'dynamic_button' $eventControl
    $clickHandler={};$selectionHandler={};$textHandler={};$sizeHandler={};$scrollHandler={};$closingHandler={};$contentHandler={};$submitHandler={}
    Register-AtaraxiaGuiViewAction $eventPort 'button' 'activate' $clickHandler;Register-AtaraxiaGuiViewAction $eventPort 'button' 'selection_change' $selectionHandler;Register-AtaraxiaGuiViewAction $eventPort 'button' 'text_change' $textHandler;Register-AtaraxiaGuiViewAction $eventPort 'button' 'size_change' $sizeHandler;Register-AtaraxiaGuiViewAction $eventPort 'button' 'value_change' $sizeHandler;Register-AtaraxiaGuiViewAction $eventPort 'button' 'lost_focus' $sizeHandler;Register-AtaraxiaGuiViewAction $eventPort 'button' 'expanded_change' $sizeHandler;Register-AtaraxiaGuiViewAction $eventPort 'button' 'scroll' $scrollHandler;Register-AtaraxiaGuiViewAction $eventPort 'button' 'close' $closingHandler;Register-AtaraxiaGuiViewAction $eventPort 'button' 'content_ready' $contentHandler
    Register-AtaraxiaGuiViewAction $eventPort 'button' 'submit' $submitHandler;Register-AtaraxiaGuiViewAction $eventPort 'dynamic_button' 'activate' $clickHandler
    Assert-True ($eventControl.ClickHandler -eq $clickHandler -and $eventControl.SelectionHandler -eq $selectionHandler -and $eventControl.TextHandler -eq $textHandler -and $eventControl.SizeHandler -eq $sizeHandler -and $eventControl.ValueHandler -eq $sizeHandler -and $eventControl.LostFocusHandler -eq $sizeHandler -and $null -ne $eventControl.ExpandedHandler -and $eventControl.ExpandedHandler -eq $eventControl.CollapsedHandler -and $eventControl.ScrollHandler -eq $scrollHandler -and $eventControl.ClosingHandler -eq $closingHandler -and $eventControl.ContentHandler -eq $contentHandler -and $eventControl.PreviewKeyHandler) 'WPF adapter did not map neutral actions to framework events.'
    $unmappedRejected=$false;try{Set-AtaraxiaGuiViewValue $wpfPort 'missing' 'x'}catch{$unmappedRejected=$true}
    Assert-True $unmappedRejected 'WPF adapter accepted an unmapped view target.'
    $module=Get-Content -Raw (Join-Path $projectRoot 'scripts/GuiPresentationPort.ps1')
    $wpfAdapter=Get-Content -Raw (Join-Path $projectRoot 'scripts/adapters/WpfGuiViewAdapter.ps1')
    $start=Get-Content -Raw (Join-Path $projectRoot 'scripts/Start-AtaraxiaGui.ps1')
    Assert-True ($wpfAdapter -match '\$timer\.Add_Tick\(\$Callback\)' -and $wpfAdapter -notmatch '\$Callback\.GetNewClosure\(\)') 'WPF timer adapter changes the callback script scope and loses the GUI polling state under Windows PowerShell.'
    Assert-True ($module -notmatch 'Windows\.|PresentationFramework|XamlReader|Dispatcher') 'Framework-neutral view port contains a GUI framework dependency.'
    Assert-True ($start -match 'Schedule-AtaraxiaGuiViewCallback \$script:guiViewPort' -and $start -match 'Start-AtaraxiaGuiViewTimer \$script:guiViewPort' -and $start -match 'Wait-AtaraxiaGuiViewDelay \$script:guiViewPort' -and $start -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''goal'' ''text_change''' -and $start -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''goal'' ''submit''' -and $start -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''main_window'' ''close''' -and $start -notmatch '\$Goal\.Add_TextChanged|\$Goal\.Add_SizeChanged|\$Goal\.Add_PreviewKeyDown|\$RunTask\.RaiseEvent|Windows\.Input\.Keyboard|\$ConversationScrollViewer\.Add_ScrollChanged|\$window\.Add_Closing|\$window\.Add_ContentRendered|DispatcherTimer|DispatcherFrame|\[Windows\.Threading\.Dispatcher\]') 'GUI composition root still calls framework event, dispatcher, or timer APIs directly.'
    Assert-True ($start -match 'Set-AtaraxiaGuiViewItems \$script:guiViewPort ''conversation''' -and $start -match 'Set-AtaraxiaGuiViewItems \$script:guiViewPort ''sessions''' -and $start -match 'Set-AtaraxiaGuiViewItems \$script:guiViewPort ''models''' -and $start -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''session_selector'' ''selection_change''' -and $start -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''theme_selector'' ''selection_change''' -and $start -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''model_selector'' ''selection_change''' -and $start -match 'Register-AtaraxiaGuiViewAction \$script:guiViewPort ''run_task'' ''activate''' -and $start -notmatch '\$RunTask\.Add_Click\(' -and $start -notmatch '\$Status\.Text\s*(?:=|\+=)' -and $start -match 'Set-AtaraxiaGuiStatusText') 'GUI composition root bypasses the view port for a collection, primary action, or status update.'
    Assert-True ($start -match "Invoke-AtaraxiaGuiNavigation 'open_settings'" -and $start -match "Invoke-AtaraxiaGuiNavigation 'close_settings'" -and $start -match 'Set-AtaraxiaGuiNavigationState \$script:guiNavigationState' -and $start -match 'Set-AtaraxiaGuiViewValue \$script:guiViewPort \$target' -and $start -notmatch '\$(ConversationPage|ProjectDrawer|SettingsPanel)\.Visibility') 'Settings navigation does not resolve through the headless navigation model and view port.'
    Assert-True ($start -match 'Set-AtaraxiaGuiClipboardText \$script:guiViewPort' -and $start -notmatch '\[Windows\.Clipboard\]') 'GUI composition root performs clipboard access instead of using the injected view port.'
    Assert-True ($start -match 'Invoke-AtaraxiaGuiViewOperation \$script:guiViewPort focus' -and $start -match 'Invoke-AtaraxiaGuiViewOperation \$script:guiViewPort set_text_focus_end' -and $start -notmatch '\$Goal\.Focus\(|\$Goal\.CaretIndex\s*=|\$ConversationScrollViewer\.ScrollTo(End|Top)\(') 'GUI composition root performs focus, caret, or conversation scrolling outside the view adapter.'
    Assert-True ($start -match 'Invoke-AtaraxiaGuiViewOperation \$script:guiViewPort toggle_expanded' -and $start -match 'Invoke-AtaraxiaGuiViewOperation \$script:guiViewPort open_context_menu' -and $start -match 'Invoke-AtaraxiaGuiViewOperation \$script:guiViewPort sync_scroll_to_latest_visibility' -and $start -notmatch '\$RecentSessionsExpander\.IsExpanded\s*=|\$OtherSession\.ContextMenu\.IsOpen\s*=|\$ScrollToLatest\.Visibility\s*=') 'GUI composition root directly manipulates expanders, context menus, or scroll affordance visibility.'
}

Test-Case 'Default unit suite does not launch the GUI executable' {
    $runner=Get-Content -Raw (Join-Path $PSScriptRoot 'run_tests.ps1')
    $gate=$runner.IndexOf('if ($GuiIntegration)',[StringComparison]::Ordinal)
    $launch=$runner.IndexOf("Start-Process -FilePath (Join-Path `$projectRoot 'Ataraxia.exe')",[StringComparison]::Ordinal)
    $legacyGate='ATARAXIA_RUN_GUI_'+'INTEGRATION'
    Assert-True ($runner -match '(?m)^param\(\[switch\]\$GuiIntegration\)' -and $runner -notmatch [regex]::Escape($legacyGate) -and $gate -ge 0 -and $launch -gt $gate) 'GUI integration is not controlled by an explicit per-invocation switch, so inherited environment can launch windows during unit tests.'
}

Test-Case 'WPF control emulation is isolated and never displays windows' {
    $emulationPath=Join-Path $PSScriptRoot 'run_wpf_control_tests.ps1'
    Assert-True (Test-Path -LiteralPath $emulationPath -PathType Leaf) 'WPF control emulation test runner is missing.'
    $emulation=Get-Content -LiteralPath $emulationPath -Raw -Encoding UTF8
    Assert-True ($emulation -match 'GetApartmentState\(\)' -and $emulation -match 'XamlReader\]::Load' -and $emulation -match 'IsVisible' -and $emulation -match 'New-AtaraxiaWpfModelParameterControls' -and $emulation -match 'Set-AtaraxiaWpfThemeResources' -and $emulation -match 'ConvertTo-AtaraxiaConversationView' -and $emulation -match 'ModelFileSelector' -and $emulation -match 'sync_scroll_to_latest_visibility' -and $emulation -notmatch '\.(Show|ShowDialog)\(' -and $emulation -notmatch 'Start-Process|Ataraxia\.exe') 'WPF control emulation does not enforce STA, exercise parameter, theme, conversation, selector, and scroll controls, or stay separate from visible GUI/process startup.'
}

Test-Case 'GUI window view is valid XAML and retains presentation control contracts' {
    $viewPath=Join-Path $projectRoot 'scripts/presentation/AtaraxiaWindow.xaml'
    Assert-True (Test-Path -LiteralPath $viewPath -PathType Leaf) 'Standalone GUI window view is missing.'
    [xml]$view=[IO.File]::ReadAllText($viewPath)
    $ns=[Xml.XmlNamespaceManager]::new($view.NameTable);$ns.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')
    $names=@($view.SelectNodes('//*[@x:Name]',$ns)|ForEach-Object{[string]$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')})
    foreach($required in @('ProjectTreePanel','SessionSelector','Conversation','Goal','RunTask','SettingsPanel')){Assert-True ($names -contains $required) "GUI view is missing presentation control '$required'."}
    foreach($name in @('RuntimeConfig','TaskName','Workspace')){$input=$view.SelectSingleNode(('//*[@x:Name="'+$name+'"]'),$ns);Assert-True ($null -ne $input -and [double]$input.GetAttribute('Height') -ge 34 -and $input.GetAttribute('Padding') -eq '6,2' -and $input.GetAttribute('VerticalContentAlignment') -eq 'Center') "Single-line input '$name' does not reserve readable text height and vertical alignment."}
    Assert-True ($view.OuterXml -match 'TargetType="\{x:Type TextBox\}"[^>]*' -and $view.OuterXml -match 'Setter Property="Padding" Value="7,2"') 'Default TextBox style uses excessive vertical padding for compact single-line controls.'
    $modelSelector=$view.SelectSingleNode("//*[@x:Name='ModelFileSelector']",$ns);$modelTemplate=$modelSelector.SelectSingleNode('./*[local-name()="ComboBox.ItemTemplate"]');$modelText=$modelTemplate.SelectSingleNode('.//*[local-name()="TextBlock"]');$modelScript=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/Start-AtaraxiaGui.ps1') -Raw -Encoding UTF8
    Assert-True ($null -ne $modelText -and $modelText.GetAttribute('Text') -eq '{Binding name}' -and $modelScript -notmatch '\$ModelFileSelector\.DisplayMemberPath') 'Model selector does not render the selected model name through an explicit item template.'
    $start=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/Start-AtaraxiaGui.ps1') -Raw -Encoding UTF8
    Assert-True ($start -match "presentation/AtaraxiaWindow\.xaml" -and $start -match 'XamlReader') 'GUI composition root does not load the standalone XAML view.'
    Assert-True ($start -match '\$windowIconPath=Join-Path \$projectRoot ''assets/branding/ataraxia-app-icon\.png''' -and $start -match '\$window\.Icon=\[Windows\.Media\.Imaging\.BitmapFrame\]::Create') 'WPF window and taskbar icon do not use the requested PNG asset.'
    Assert-True ($start -notmatch 'loadingSession' -and $start -match 'sessionSelectionState\.is_synchronizing' -and $start -match 'Set-AtaraxiaGuiSessionSelectionSynchronization') 'Session selector synchronization remains an implicit GUI boolean.'
}

Test-Case 'GUI splash view is valid standalone XAML' {
    $splashPath=Join-Path $projectRoot 'scripts/presentation/AtaraxiaSplash.xaml'
    [xml]$splash=[IO.File]::ReadAllText($splashPath)
    $ns=[Xml.XmlNamespaceManager]::new($splash.NameTable);$ns.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')
    $image=$splash.SelectSingleNode('//*[@x:Name="SplashImage"]',$ns)
    Assert-True ($splash.DocumentElement.GetAttribute('Width') -eq '560' -and $splash.DocumentElement.GetAttribute('Height') -eq '315' -and $null -ne $image) 'Standalone splash view lost its size or image target.'
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
    $icons=@{};foreach($role in $contracts.generic_agent.roles){$iconPath=Join-Path (Join-Path $projectRoot 'assets/role-icons') ($role.id+'.svg');$icons[$role.id]=ConvertFrom-AtaraxiaSvgGeometry ([IO.File]::ReadAllText($iconPath))}
    $view=ConvertTo-AtaraxiaConversationView ([pscustomobject]@{entries=@()}) ([pscustomobject]@{history=$history}) $icons
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

Test-Case 'Project names and resolved paths enforce lexical boundaries' {
    . (Join-Path $projectRoot 'scripts/ProjectStore.ps1')
    $root=Join-Path ([IO.Path]::GetTempPath()) 'Ataraxia Projects'
    $valid=Get-AtaraxiaProjectPath ($root+[IO.Path]::DirectorySeparatorChar) 'Project_01-test'
    $normalizedRoot=[IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    Assert-True ($valid -eq (Join-Path $normalizedRoot 'Project_01-test') -and $valid.StartsWith($normalizedRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Project path did not resolve beneath the normalized root.'
    $longName='A'+('x'*63);Assert-True ((Get-AtaraxiaProjectPath $root $longName).EndsWith($longName)) 'Maximum-length project name was rejected.'
    foreach($badName in @('', '..', '../escape', '.hidden', 'with space', 'dot.name', 'slash/name', ('A'+('x'*64)))){$rejected=$false;try{$null=Get-AtaraxiaProjectPath $root $badName}catch{$rejected=$true};Assert-True $rejected "Invalid project name was accepted: '$badName'"}
}

Test-Case 'Session title validation rejects unsafe values without changing metadata' {
    . (Join-Path $projectRoot 'scripts/SessionStore.ps1')
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-title-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $root -Force|Out-Null
    $metadataPath=Join-Path $root 'session.json';[IO.File]::WriteAllText($metadataPath,'{"artifact_type":"session","id":"session-test","title":"Original","title_generated":false,"title_source":"pending","updated_at":"2026-01-01T00:00:00Z"}',[Text.UTF8Encoding]::new($false))
    try{
        $tooLong=[string]::new([char]120,65)
        foreach($badTitle in @('', '   ', $tooLong, "unsafe`0title")){$rejected=$false;try{$null=Set-AtaraxiaSessionTitle $root $badTitle 'user'}catch{$rejected=$true};$current=Read-AgentJsonFile $metadataPath;Assert-True ($rejected -and $current.title -eq 'Original') "Unsafe title changed session metadata: '$badTitle'"}
        $renamed=Set-AtaraxiaSessionTitle $root "  two`n  words  " 'agent'
        Assert-True ($renamed.title -eq 'two words' -and $renamed.title_generated -and $renamed.title_source -eq 'agent' -and ([string]$renamed.updated_at) -match 'Z$') 'Valid session title was not normalized and timestamped in UTC.'
        $rejected=$false;try{$null=Set-AtaraxiaSessionTitle $root 'A title' 'invalid-source'}catch{$rejected=$true};Assert-True $rejected 'Unsupported session title source was accepted.'
    }finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}

Test-Case 'Workspace media discovery enforces type size and ignored directory limits' {
    . (Join-Path $projectRoot 'scripts/AgentHarness.ps1')
    $root='C:\virtual\workspace'
    $tree=[pscustomobject]@{children=@{};bytes=@{};list_calls=0;read_calls=0}
    $tree.children[$root]=@(
        [pscustomobject]@{full_path="$root\a.png";name='a.png';extension='.png';is_directory=$false;is_reparse_point=$false;length=3L},
        [pscustomobject]@{full_path="$root\b.wav";name='b.wav';extension='.wav';is_directory=$false;is_reparse_point=$false;length=3L},
        [pscustomobject]@{full_path="$root\large.jpg";name='large.jpg';extension='.jpg';is_directory=$false;is_reparse_point=$false;length=5L},
        [pscustomobject]@{full_path="$root\.git";name='.git';extension='';is_directory=$true;is_reparse_point=$false;length=0L},
        [pscustomobject]@{full_path="$root\linked";name='linked';extension='';is_directory=$true;is_reparse_point=$true;length=0L}
    )
    $tree.children["$root\.git"]=@([pscustomobject]@{full_path="$root\.git\ignored.png";name='ignored.png';extension='.png';is_directory=$false;is_reparse_point=$false;length=1L})
    $tree.children["$root\linked"]=@([pscustomobject]@{full_path="$root\linked\outside.png";name='outside.png';extension='.png';is_directory=$false;is_reparse_point=$false;length=1L})
    $tree.bytes["$root\a.png"]=[byte[]]@(1,2,3);$tree.bytes["$root\b.wav"]=[byte[]]@(4,5,6);$tree.bytes["$root\large.jpg"]=[byte[]]@(1,2,3,4,5);$tree.bytes["$root\.git\ignored.png"]=[byte[]]@(7);$tree.bytes["$root\linked\outside.png"]=[byte[]]@(8)
    $list={param($Path)$tree.list_calls++;if($tree.children.ContainsKey($Path)){return @($tree.children[$Path])};return @()}.GetNewClosure()
    $read={param($Path)$tree.read_calls++;if(-not $tree.bytes.ContainsKey($Path)){throw "Missing fake file: $Path"};return ,$tree.bytes[$Path]}.GetNewClosure()
    $hash={param($Path)$bytes=$tree.bytes[$Path];$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}}.GetNewClosure()
    $dependencies=New-AgentWorkspaceReaderDependencies -ListDirectory $list -ReadBytes $read -HashFile $hash
    $settings=[pscustomobject]@{workspace=[pscustomobject]@{max_file_bytes=4;max_total_bytes=5;max_media_bytes=4;max_total_media_bytes=5;media_extensions=@('.png','.wav','.jpg');ignored_directories=@('.git')}}
    $snapshot=Get-AgentWorkspaceSnapshot $root $settings -Dependencies $dependencies
    Assert-True ($snapshot.Count -eq 3 -and $snapshot[0].path -eq 'a.png' -and $snapshot[0].content_available -and $snapshot[1].path -eq 'b.wav' -and -not $snapshot[1].content_available -and $snapshot[2].path -eq 'large.jpg' -and -not $snapshot[2].content_available) ("Workspace snapshot did not apply per-file and aggregate size limits while retaining metadata: " + ($snapshot|ConvertTo-Json -Compress))
    $media=Get-AgentWorkspaceMedia $root $settings -Dependencies $dependencies
    Assert-True ($media.Count -eq 1 -and $media[0].path -eq 'a.png' -and $media[0].mime_type -eq 'image/png' -and $media[0].byte_length -eq 3 -and $media[0].sha256 -eq '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81') 'Workspace media scan exceeded a size limit, returned an incorrect hash, or included a reparse/ignored path.'
    $rejected=$false;$badDependencies=New-AgentWorkspaceReaderDependencies -ListDirectory $list -ReadBytes $read -HashFile {param($Path)'invalid'};try{$null=Get-AgentWorkspaceFileHash $badDependencies "$root\a.png"}catch{$rejected=$true};Assert-True $rejected 'Invalid workspace hash adapter output crossed the reader port.'
    $settings.workspace.max_total_media_bytes=6;$allMedia=Get-AgentWorkspaceMedia $root $settings -Dependencies $dependencies
    Assert-True ($allMedia.Count -eq 2 -and $allMedia[1].path -eq 'b.wav' -and $allMedia[1].mime_type -eq 'audio/wav' -and $tree.list_calls -gt 0 -and $tree.read_calls -gt 0) 'Workspace media scan did not include supported audio through the injected reader.'
    $tree.list_calls=0;$context=Get-AgentWorkspaceContext $root $settings $dependencies
    Assert-True ($tree.list_calls -eq 1 -and $context.files.Count -eq 3 -and $context.media.Count -eq 2) 'A combined workspace context performed duplicate directory walks or changed file/media results.'
}

Test-Case 'Workspace file store contract validates adapters and rejected changes have no write effects' {
    . (Join-Path $projectRoot 'scripts/AgentHarness.ps1')
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-store-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $root -Force|Out-Null
    $calls=[pscustomobject]@{writes=0;deletes=0};$exists={param($Path)(Test-Path -LiteralPath $Path -PathType Leaf)}.GetNewClosure();$length={param($Path)(Get-Item -LiteralPath $Path).Length}.GetNewClosure();$read={param($Path),([IO.File]::ReadAllBytes($Path))}.GetNewClosure();$write={param($Path,$Bytes)$calls.writes++;[IO.File]::WriteAllBytes($Path,$Bytes)}.GetNewClosure();$delete={param($Path)$calls.deletes++;Remove-Item -LiteralPath $Path -Force}.GetNewClosure();$ensure={param($Path)New-Item -ItemType Directory -Force -Path $Path|Out-Null}.GetNewClosure();$move={param($Source,$Destination,$Force)if($Force){Move-Item -LiteralPath $Source -Destination $Destination -Force}else{[IO.File]::Move($Source,$Destination)}}.GetNewClosure();$replace={param($Source,$Destination,$Backup)[IO.File]::Replace($Source,$Destination,$Backup)}.GetNewClosure();$store=New-AgentWorkspaceMutationDependencies $exists $length $read $write $delete $ensure $move $replace
    $rejected=$false;try{$bad=@([pscustomobject]@{path='new.txt';action='create';base_hash=(Get-AgentWorkspaceHash '');operations=@([pscustomobject]@{op='insert';count=0;lines=@('valid')})},[pscustomobject]@{path='../escape.txt';action='create';base_hash=(Get-AgentWorkspaceHash '');operations=@()});$null=Apply-AgentWorkspaceChanges $root $bad '' $store}catch{$rejected=$true}
    Assert-True ($rejected -and $calls.writes -eq 0 -and $calls.deletes -eq 0 -and -not(Test-Path (Join-Path $root 'new.txt'))) 'A rejected workspace batch wrote or deleted a file before validation completed.'
    Assert-True ((Get-AgentWorkspaceStoreLength $store (Join-Path $projectRoot 'LICENSE')) -gt 0) 'File store length contract returned an invalid value.'
    $badStore=New-AgentWorkspaceMutationDependencies $exists $length $read $write $delete $ensure $move $replace; $badStore.read_bytes={param($Path)'not bytes'};$contractRejected=$false;try{$null=Read-AgentWorkspaceStoreBytes $badStore (Join-Path $projectRoot 'LICENSE')}catch{$contractRejected=$true};Assert-True $contractRejected 'Invalid file store bytes crossed the adapter boundary.'
    Remove-Item -LiteralPath $root -Recurse -Force
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
        $storeCalls=[System.Collections.Generic.List[string]]::new();$readJson={param($Path,$MaximumBytes)$storeCalls.Add('read');[IO.File]::ReadAllText($Path)|ConvertFrom-Json}.GetNewClosure();$writeJson={param($Path,$Value,$Depth)$storeCalls.Add('write');$json=ConvertTo-Json -InputObject $Value -Depth $Depth;[IO.File]::WriteAllText($Path,$json,[Text.UTF8Encoding]::new($false))}.GetNewClosure();$fileStore=New-AtaraxiaJsonFileStoreDependencies -ReadJson $readJson -WriteJson $writeJson
        Set-AtaraxiaProjectCommonPrompt $project 'Keep all output concise.' $fileStore
        Set-AtaraxiaSessionCommonPrompt $session 'Use the existing terminology.' $fileStore
        $combined=Get-AtaraxiaCommonPromptForTaskDirectory $session $fileStore
        Assert-True ($combined -match 'Keep all output concise\.' -and $combined -match 'Use the existing terminology\.') 'Common prompts were not both resolved for the session.'
        . (Join-Path (Join-Path $projectRoot 'scripts') 'AgentCore.ps1')
        $rolePrompt=Agent-GetRoleSystemPrompt ([pscustomobject]@{resources_root='';resources_user='default-user';agent_common_prompt=$combined}) ([pscustomobject]@{system_prompt='missing-prompt';purpose='Role purpose.'}) 'Role purpose.'
        Assert-True ($rolePrompt -match 'Role purpose\.' -and $rolePrompt -match 'Keep all output concise\.' -and $rolePrompt -match 'Use the existing terminology\.') 'Common prompts are not appended to role system messages.'
        Assert-True ($storeCalls -contains 'read' -and $storeCalls -contains 'write') 'Common prompt storage bypassed the injected JSON store.'
        $sessionOnly=Get-AtaraxiaCommonPromptForTaskDirectory (Join-Path $root 'NoProject/sessions/session-2')
        Assert-True ([string]::IsNullOrEmpty($sessionOnly)) 'Missing common prompts should resolve to empty text.'
    }finally{Remove-Item -LiteralPath $root -Recurse -Force}
}

Test-Case 'Stopped agent run restores workspace diffs and prior task state' {
    . (Join-Path (Join-Path $projectRoot 'scripts') 'WorkspaceDiff.ps1')
    . (Join-Path (Join-Path $projectRoot 'scripts') 'AgentHarness.ps1')
    . (Join-Path (Join-Path $projectRoot 'scripts') 'FileSystemWorkspaceStore.ps1')
    . (Join-Path (Join-Path $projectRoot 'scripts') 'AgentCore.ps1')
    $workspaceFileStore=New-AgentWorkspaceFileStoreDependencies
    $root=Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
    $workspace=Join-Path $root 'workspace';$task=Join-Path $root 'task';New-Item -ItemType Directory -Path $workspace,$task -Force|Out-Null
    $existing=Join-Path $workspace 'existing.txt';$statePath=Join-Path $task 'state.json';$journal=Join-Path $task 'run-changes.json'
    [IO.File]::WriteAllText($existing,'before',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($statePath,'old-state',[Text.UTF8Encoding]::new($false))
    New-AgentChangeJournal $journal $workspace $statePath $workspaceFileStore | Out-Null
    $change=[pscustomobject]@{path='existing.txt';action='modify';base_hash=(Get-AgentWorkspaceHash 'before');operations=@([pscustomobject]@{op='delete';count=0;lines=@('before')},[pscustomobject]@{op='insert';count=0;lines=@('after')})}
    $create=[pscustomobject]@{path='created.txt';action='create';base_hash=(Get-AgentWorkspaceHash '');operations=@([pscustomobject]@{op='insert';count=0;lines=@('new')})}
    Apply-AgentWorkspaceChanges $workspace @($change,$create) $journal $workspaceFileStore | Out-Null
    Agent-SaveState $statePath ([pscustomobject]@{value='new-state'}) $journal $workspaceFileStore
    Assert-True (([IO.File]::ReadAllText($existing) -eq 'after') -and (Test-Path -LiteralPath (Join-Path $workspace 'created.txt'))) 'Diffs were not applied for the rollback test.'
    Restore-AgentRunChanges $workspace $journal $statePath $workspaceFileStore | Out-Null
    Assert-True (([IO.File]::ReadAllText($existing) -eq 'before') -and -not (Test-Path -LiteralPath (Join-Path $workspace 'created.txt')) -and [IO.File]::ReadAllText($statePath) -eq 'old-state') 'Stopping did not restore changed files and prior task state.'
    Remove-Item -LiteralPath $existing -Force;Remove-Item -LiteralPath $statePath -Force;Remove-Item -LiteralPath $workspace -Force;Remove-Item -LiteralPath $task -Force;Remove-Item -LiteralPath $root -Force
}

Test-Case 'Documentation uses Ataraxia and domain independent requirements' {
    $readme=Get-Content -LiteralPath (Join-Path $projectRoot 'README.md') -Raw -Encoding UTF8
    $englishReadmePath=Join-Path $projectRoot 'docs/README/en/README.md'
    Assert-True (Test-Path -LiteralPath $englishReadmePath -PathType Leaf) 'English README is not stored in its language folder.'
    $englishReadme=Get-Content -LiteralPath $englishReadmePath -Raw -Encoding UTF8
    $coverPath=Join-Path (Split-Path $englishReadmePath -Parent) '../../../assets/splash/ataraxia-project-cover.png'
    Assert-True (Test-Path -LiteralPath ([IO.Path]::GetFullPath($coverPath)) -PathType Leaf) 'English README cover image link does not resolve relative to its document.'
    $spec=Get-Content -LiteralPath (Join-Path $projectRoot 'docs/SPECIFICATION.md') -Raw -Encoding UTF8
    $policy=Get-Content -LiteralPath (Join-Path $projectRoot 'AGENTS.md') -Raw -Encoding UTF8
    Assert-True ($readme -match '(?m)^言語: 日本語 \| \[English\]\(docs/README/en/README\.md\)\r?$' -and $readme -match 'Invoke-Agent\.ps1' -and $englishReadme -match '(?m)^Languages: \[日本語\]\(../../../README\.md\) \| English\r?$') 'Japanese and English README files or their language switch links are missing.'
    Assert-True ($spec -match '特定のドメインに限定しない' -and $spec -notmatch 'Invoke-NovelWriter') 'Specification retains domain-specific workflow assumptions.'
    Assert-True ($spec.StartsWith('# Ataraxia 技術仕様書') -and $spec -notmatch '(?m)^## (Purpose|Entry points|Domain-independent workflow|Workspace changes and commands|Context and local resource assumptions|Reports and GUI behavior|Configuration and dependencies|Development requirements)$') 'Technical specification prose and section headings are not Japanese.'
    Assert-True ($spec -match '(?m)^## 用語定義\r?$' -and $spec -match '\| 用語 \| 定義 \| 対応する識別子・保存先 \| 表記規則 \|' -and $spec -match '\| セッション \|' -and $spec -match '\| 作業対象 \|' -and $spec -match '\| ワークフロー段階 \|') 'Project terminology and canonical usage are not defined in a table after the overview.'
    foreach($roleId in @('core','planner','researcher','executor','reviewer','improver','router','verifier','security_reviewer','impact_reviewer','context_compressor','reporter','session_namer')){Assert-True ($spec -match [regex]::Escape($roleId) -and $spec -match ([regex]::Escape($roleId)+'.svg')) "Specification role table is missing detail for $roleId."}
    Assert-True ($policy -match 'テスト駆動開発') 'Development policy no longer states TDD.'
    Assert-True ($spec -match '(?m)^### 単体テスト設計方法論\r?$' -and $spec -match '振る舞いを特定する' -and $spec -match '正常系、境界値、異常系' -and $spec -match 'アダプターとして注入する' -and $spec -match '行カバレッジ' -and $spec -match '(?m)^\| 単体テスト \|' -and $spec -match '(?m)^\| 契約テスト \|' -and $spec -match '(?m)^\| 統合テスト \|') 'Specification is missing the test selection, dependency isolation, coverage, or test-layer methodology.'
    Assert-True ($policy -match '単体テストはヘッドレスで実行する' -and $policy -match '正常系、境界値、拒否・不正入力') 'Agent development instructions do not enforce headless GUI unit tests and behavior-based test cases.'
    Assert-True ($policy -match 'UTF-8 BOM' -and $policy -match 'Windows PowerShell 5\.1') 'Agent development instructions do not preserve PowerShell 5.1 script encoding compatibility.'
    Assert-True ($policy -match 'ウィンドウの可視性' -and $policy -match '成功扱いにせず' -and $policy -match '対話可能なWindowsデスクトップで再検証する') 'Agent development instructions do not define how to handle GUI integration failures caused by the host desktop.'
    Assert-True ($spec -match '(?m)^## 設計原則と段階的再設計\r?$' -and $spec -match '高凝集' -and $spec -match '依存性逆転' -and $spec -match 'composition root' -and $spec -match '大規模な一括書き換えを避ける') 'Architecture policy is missing abstraction, cohesion, dependency inversion, composition, or incremental migration rules.'
    foreach($jsonContract in @('config.example.json','koboldcpp-settings.json','agent-harness.json','role-contracts.json','gui-dialog-contracts.json','gui-themes.json','project.json','session.json','conversation.json','request-transaction.json','state.json','run-changes.json','.task.json','sysprompt/*.json','ja.json','en.json','startup_parameters','request_parameters','response_format','history_entry')){Assert-True ($spec.Contains($jsonContract)) "Technical specification JSON catalog is missing a structure: $jsonContract"}
    Assert-True ($policy -match '高凝集・疎結合' -and $policy -match '依存性逆転' -and $policy -match 'Composition root' -and $policy -match '縦切り') 'Contributor instructions do not enforce the project architecture principles.'
    $architecturePath=Join-Path $projectRoot 'docs/ARCHITECTURE_REDESIGN.md'
    Assert-True (Test-Path -LiteralPath $architecturePath -PathType Leaf) 'Architecture redesign map is missing.'
    $architecture=Get-Content -Raw $architecturePath
    Assert-True ($architecture -match 'scripts/domain/Workflow\.ps1' -and $architecture -match 'scripts/application/AgentRunner\.ps1' -and $architecture -match 'scripts/ports/' -and $architecture -match 'scripts/adapters/' -and $architecture -match 'scripts/presentation/AtaraxiaGui\.ps1' -and $architecture -match '(?m)^## 移行手順\r?$') 'Architecture map does not define cohesive layers and an incremental migration sequence.'
    $requirements=Get-Content -Raw (Join-Path $projectRoot 'docs/REQUIREMENTS.md')
    $knowledge=Get-Content -Raw (Join-Path $projectRoot 'docs/ENGINEERING_KNOWLEDGE.md')
    $policy=Get-Content -Raw (Join-Path $projectRoot 'AGENTS.md')
    Assert-True ($requirements -match '(?m)^\| REQ-[0-9]{3} \|' -and $knowledge -match '(?m)^\| KNW-[0-9]{3} \|' -and $knowledge -notmatch '(?m)^\| K-[0-9]{3} \|' -and $architecture -match '(?m)^\| MIG-[0-9]{2} \|' -and $architecture -match '(?m)^\| IMP-[0-9]{3} \|' -and $policy -match '資料項目の安定識別子' -and $policy -match 'KNW-NNN') 'Cross-document identifiers do not use stable type prefixes.'
    Assert-True ($requirements -match '(?m)^\| REQ-011 \| 重要 \| 受け入れ済み \|' -and $spec -match '(?m)^### 利用者データ JSON の修復\r?$' -and $spec -match '拒否された場合は原本に一切書き込まず' -and $spec -match '原子的に置換' -and $spec -match '差分ジャーナル') 'User-approved JSON recovery requirements do not define safe, schema-aware, information-preserving repair.'
}

Test-Case 'Engineering knowledge is tracked in a structured Markdown table' {
    $knowledgePath=Join-Path $projectRoot 'docs/ENGINEERING_KNOWLEDGE.md'
    Assert-True (Test-Path -LiteralPath $knowledgePath -PathType Leaf) 'Engineering knowledge register is missing.'
    $knowledge=Get-Content -Raw $knowledgePath
    Assert-True ($knowledge -match '\| ID \| 分類 \| 知見・観察 \| 適用条件・根拠 \| 設計への反映 \| 検証方法 \| 関連箇所 \|' -and $knowledge -match '(?m)^\| KNW-[0-9]{3} \|') 'Engineering knowledge table does not include the agreed fields and stable identifiers.'
    $ids=@([regex]::Matches($knowledge,'(?m)^\| (KNW-[0-9]{3}) \|')|ForEach-Object{$_.Groups[1].Value})
    Assert-True ($ids.Count -ge 1 -and @($ids|Select-Object -Unique).Count -eq $ids.Count) 'Knowledge entries are empty or have duplicate identifiers.'
}

if(-not $GuiIntegration){
    Test-Case 'Default unit suite does not load WPF assemblies' {
        $wpfAssemblyNames=@('PresentationFramework','PresentationCore','WindowsBase','UIAutomationClient','UIAutomationTypes','ReachFramework')
        $loadedWpfAssemblies=@([AppDomain]::CurrentDomain.GetAssemblies()|ForEach-Object{$_.GetName().Name}|Where-Object{$wpfAssemblyNames -contains $_})
        Assert-True ($loadedWpfAssemblies.Count -eq 0) "Headless unit tests loaded WPF assemblies: $($loadedWpfAssemblies -join ', ')."
    }
}

Write-Output "Result: $passed passed, $failed failed"
Remove-Item Env:ATARAXIA_USER_DATA_DIRECTORY -ErrorAction SilentlyContinue
if(-not [string]::IsNullOrWhiteSpace($previousUserDataDirectory)){$env:ATARAXIA_USER_DATA_DIRECTORY=$previousUserDataDirectory}
if(Test-Path -LiteralPath $testUserDataDirectory){Remove-Item -LiteralPath $testUserDataDirectory -Recurse -Force -ErrorAction SilentlyContinue}
if ($failed -gt 0) { exit 1 }


