param()

& {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# --- GLOBAL VARIABLES ---
$Global:JsonTempFile = [System.IO.Path]::GetFullPath("$env:TEMP\unified_out_$([guid]::NewGuid().ToString('N')).json")
$Global:RunLogFile = ""
$Global:ExcludeFile = ""
$Global:CurrentProcess = $null
$Global:ActiveTransfer = $null
$Global:TransferUiTimer = $null
$Global:StopTransfer = $false
$Global:LoadingHistory = $false 

# ENGINE FIX: UI Soft-Lock State Tracker
$Global:IsTransferring = $false
$Global:TotalTransferItems = 0

# Sorting States
$Global:SortCol = -1
$Global:SortAsc = $true

# App Data & Persistence
$Global:AppDir = Join-Path $env:APPDATA "DataTransferTool"
if (-not (Test-Path -LiteralPath $Global:AppDir)) { New-Item -ItemType Directory -Path $Global:AppDir | Out-Null }
$Global:DbPath = Join-Path $Global:AppDir "tasks_v1.json"
$Global:SettingsFile = Join-Path $Global:AppDir "settings.json"
$Global:TempConfig = Join-Path $Global:AppDir "rclone_persistent.conf" 
$Global:Tasks = @()
$Global:CurrentTaskId = $null

# Default System Exclusions initialized globally
$Global:DefaultFilters = @(
    "*\desktop.ini",
    "*\System Volume Information\",
    "*\Temporary Internet Files\",
    "*\thumbs.db",
    "\`$RECYCLE.BIN\",
    "\`$SysReset\",
    "\`$Windows.~BT\",
    "\`$Windows.~WS\",
    "\`$WinREAgent\",
    "\hiberfil.sys",
    "\pagefile.sys",
    "\swapfile.sys",
    "\Windows\csc\",
    "\Windows\debug\NtFrs*",
    "\Windows\ntfrs\jet\",
    "\Windows\Prefetch\",
    "\Windows\Registration\*.crmlog",
    "\Windows\sysvol\domain\DO_NOT_REMOVE_NtFrs_PreInstall_Directory\",
    "\Windows\sysvol\domain\NtFrs_PreExisting___See_EventLog\",
    "\Windows\sysvol\staging\domain\NTFRS_*",
    "\Windows\Temp\"
)

# ENGINE FIX: Added TransferThreads to AppSettings (defaulting to 3)
$Global:AppSettings = [PSCustomObject]@{ RclonePath = ""; GCloudPath = ""; IsDarkMode = $true; IsDebugMode = $false; TransferThreads = 3; CustomFilters = @() }

# Dual Engine States
$Global:SrcProvider = ""; $Global:DstProvider = ""
$Global:SrcPath = ""; $Global:DstPath = ""
$Global:SrcLocalPath = ""; $Global:DstLocalPath = ""
$Global:SrcIsFile = $false 
$Global:DriveMap = @{}

$Global:GCloudBin = ""
$Global:RcloneExe = ""
$Global:RemoteName = "GWorkspaceAuth"
$Global:GcsBridgeName = "GCSBridge"

$Global:ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($Global:ScriptDir)) { $Global:ScriptDir = [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }

class TransferCommand {
    [string]$Source
    [string]$Destination
    [string]$ToolPath
    [string]$Arguments
    [string]$WorkingDirectory
    [hashtable]$Environment
    [string]$Description

    TransferCommand() {
        $this.Environment = @{}
    }
}

class TransferJob {
    [string]$Source
    [string]$Destination
    [string]$ToolPath
    [string]$DisplayName
    [int]$TotalItems
    [string]$ExcludeFile
    [TransferCommand[]]$Commands

    TransferJob() {
        $this.TotalItems = -1
        $this.Commands = @()
    }
}

# --- 1. SYSTEM ENVIRONMENT & SETTINGS ---
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\python.exe" -Name "(Default)" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\python3.exe" -Name "(Default)" -ErrorAction SilentlyContinue

function Load-Settings {
    if (Test-Path -LiteralPath $Global:SettingsFile) {
        try { 
            $loaded = Get-Content -Raw -LiteralPath $Global:SettingsFile | ConvertFrom-Json 
            if ($loaded.RclonePath) { $Global:AppSettings.RclonePath = $loaded.RclonePath }
            if ($loaded.GCloudPath) { $Global:AppSettings.GCloudPath = $loaded.GCloudPath }
            if ($null -ne $loaded.IsDarkMode) { $Global:AppSettings.IsDarkMode = [bool]$loaded.IsDarkMode }
            if ($null -ne $loaded.IsDebugMode) { $Global:AppSettings.IsDebugMode = [bool]$loaded.IsDebugMode }
            if ($null -ne $loaded.TransferThreads) { $Global:AppSettings.TransferThreads = [int]$loaded.TransferThreads }
            if ($loaded.CustomFilters) { $Global:AppSettings.CustomFilters = $loaded.CustomFilters }
        } catch {}
    }
}

function Save-Settings { $Global:AppSettings | ConvertTo-Json -Depth 2 | Out-File -LiteralPath $Global:SettingsFile -Encoding utf8 -Force }

Load-Settings
if ($null -eq $Global:AppSettings.CustomFilters -or $Global:AppSettings.CustomFilters.Count -eq 0) {
    $Global:AppSettings.CustomFilters = $Global:DefaultFilters
}
$Global:CustomFilters = $Global:AppSettings.CustomFilters

function Set-RcloneEnvironment {
    $Global:RcloneExe = ""
    if (![string]::IsNullOrWhiteSpace($Global:AppSettings.RclonePath) -and (Test-Path -LiteralPath $Global:AppSettings.RclonePath)) {
        $Global:RcloneExe = $Global:AppSettings.RclonePath
    } else {
        $Global:RcloneExe = Join-Path -Path $Global:ScriptDir -ChildPath "rclone.exe"
        if (-not (Test-Path -LiteralPath $Global:RcloneExe)) { 
            $rCmd = Get-Command "rclone.exe" -ErrorAction SilentlyContinue
            if ($rCmd) { $Global:RcloneExe = $rCmd.Source }
        }
    }
    if ($Global:RcloneExe) {
        $confStr = @"
[$Global:GcsBridgeName]
type = google cloud storage
env_auth = true
"@
        if (-not (Test-Path $Global:TempConfig)) { $confStr | Out-File $Global:TempConfig -Encoding utf8 }
        elseif ((Get-Content $Global:TempConfig -Raw) -notmatch "\[$Global:GcsBridgeName\]") { Add-Content -Path $Global:TempConfig -Value "`n$confStr" }
    }
}

function Set-GCloudEnvironment {
    $Global:GCloudBin = ""
    if (![string]::IsNullOrWhiteSpace($Global:AppSettings.GCloudPath) -and (Test-Path -LiteralPath $Global:AppSettings.GCloudPath)) {
        $Global:GCloudBin = $Global:AppSettings.GCloudPath
        $env:Path += ";$Global:GCloudBin"
    } else {
        $gcloudCmd = Get-Command "gcloud.cmd" -ErrorAction SilentlyContinue
        if (!$gcloudCmd) {
            $defaultPaths = @("$env:LocalAppData\Google\Cloud SDK\google-cloud-sdk\bin", "${env:ProgramFiles(x86)}\Google\Cloud SDK\google-cloud-sdk\bin")
            foreach ($p in $defaultPaths) { if (Test-Path -LiteralPath "$p\gcloud.cmd") { $env:Path += ";$p"; $gcloudCmd = Get-Command "gcloud.cmd"; break } }
        }
        if ($gcloudCmd) { $Global:GCloudBin = Split-Path $gcloudCmd.Source }
    }
    if ($Global:GCloudBin) {
        $sdkRoot = Split-Path $Global:GCloudBin
        $BundledPython = Join-Path $sdkRoot "platform\bundledpython\python.exe"
        if (Test-Path -LiteralPath $BundledPython) { $env:CLOUDSDK_PYTHON = $BundledPython }
    }
    
    $adcPath = Join-Path $env:APPDATA "gcloud\application_default_credentials.json"
    if (Test-Path $adcPath) { $env:GOOGLE_APPLICATION_CREDENTIALS = $adcPath }
}

Set-RcloneEnvironment; Set-GCloudEnvironment

function Load-Tasks {
    if (Test-Path -LiteralPath $Global:DbPath) {
        try { $Global:Tasks = (Get-Content -Raw -LiteralPath $Global:DbPath | ConvertFrom-Json) } catch { $Global:Tasks = @() }
        if ($null -eq $Global:Tasks) { $Global:Tasks = @() }
        if ($Global:Tasks -isnot [array]) { $Global:Tasks = @($Global:Tasks) }
    }
}
function Save-Tasks { $Global:Tasks | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $Global:DbPath -Encoding utf8 -Force }

# --- 2. GUI INITIALIZATION (SIDE-BY-SIDE LAYOUT) ---
$Form = New-Object System.Windows.Forms.Form
$Form.Text = "Data Transfer Tool v1.1.29"
$ScreenArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$AppWidth = 1250; $AppHeight = if ($ScreenArea.Height -lt 850) { [math]::Max(750, $ScreenArea.Height - 50) } else { 850 }
$Form.ClientSize = New-Object System.Drawing.Size($AppWidth, $AppHeight)
$Form.MinimumSize = New-Object System.Drawing.Size(1100, 750)
$Form.StartPosition = "CenterScreen"

$BgColor = [System.Drawing.Color]::FromArgb(255, 30, 30, 30); $PanelColor = [System.Drawing.Color]::FromArgb(255, 45, 45, 48)    
$InputColor = [System.Drawing.Color]::FromArgb(255, 37, 37, 38); $TextColor = [System.Drawing.Color]::White                         
$BorderColor = [System.Drawing.Color]::FromArgb(255, 85, 85, 85)   
$Form.BackColor = $BgColor; $Form.ForeColor = $TextColor

$BoldFont = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$LogFont = New-Object System.Drawing.Font("Consolas", 8, [System.Drawing.FontStyle]::Regular)

function Set-FlatButton ($btn) {
    $btn.FlatStyle = "Flat"; $btn.FlatAppearance.BorderSize = 1; $btn.FlatAppearance.BorderColor = $BorderColor
    $btn.BackColor = $PanelColor; $btn.ForeColor = $TextColor
}

$SplitterMain = New-Object System.Windows.Forms.SplitContainer
$SplitterMain.Dock = "Fill"; $SplitterMain.BorderStyle = "FixedSingle"; $SplitterMain.SplitterWidth = 6
$Form.Controls.Add($SplitterMain); $SplitterMain.SplitterDistance = 380   

# --- LEFT PANEL (History & Options) ---
$LeftPanel = $SplitterMain.Panel1
$LblTasks = New-Object System.Windows.Forms.Label; $LblTasks.Text = "Transfer History:"; $LblTasks.Font = $BoldFont; $LblTasks.Location = New-Object System.Drawing.Point(10, 15); $LblTasks.AutoSize = $true; $LeftPanel.Controls.Add($LblTasks)

$LvwTasks = New-Object System.Windows.Forms.ListView
$LvwTasks.View = "Details"; $LvwTasks.FullRowSelect = $true; $LvwTasks.MultiSelect = $false; $LvwTasks.GridLines = $false; $LvwTasks.HideSelection = $false 
$LvwTasks.Location = New-Object System.Drawing.Point(10, 40); $LvwTasks.Size = New-Object System.Drawing.Size(355, ($AppHeight - 140))
$LvwTasks.Anchor = "Top, Bottom, Left, Right"; $LvwTasks.BackColor = $InputColor; $LvwTasks.ForeColor = $TextColor; $LvwTasks.BorderStyle = "FixedSingle"
[void]$LvwTasks.Columns.Add("Name", 110); [void]$LvwTasks.Columns.Add("Status", 75); [void]$LvwTasks.Columns.Add("Started", 100); [void]$LvwTasks.Columns.Add("Completed", 100)
$LeftPanel.Controls.Add($LvwTasks)

$row1Y = $AppHeight - 90; $row2Y = $AppHeight - 45
$BtnNewTask = New-Object System.Windows.Forms.Button; $BtnNewTask.Text = "New Transfer"; $BtnNewTask.Location = New-Object System.Drawing.Point(10, $row1Y); $BtnNewTask.Size = New-Object System.Drawing.Size(100, 30); $BtnNewTask.Anchor = "Bottom, Left"; Set-FlatButton $BtnNewTask; $LeftPanel.Controls.Add($BtnNewTask)
$BtnDelTask = New-Object System.Windows.Forms.Button; $BtnDelTask.Text = "Delete"; $BtnDelTask.Location = New-Object System.Drawing.Point(115, $row1Y); $BtnDelTask.Size = New-Object System.Drawing.Size(75, 30); $BtnDelTask.Anchor = "Bottom, Left"; Set-FlatButton $BtnDelTask; $LeftPanel.Controls.Add($BtnDelTask)
$BtnClearAll = New-Object System.Windows.Forms.Button; $BtnClearAll.Text = "Clear All"; $BtnClearAll.Location = New-Object System.Drawing.Point(195, $row1Y); $BtnClearAll.Size = New-Object System.Drawing.Size(85, 30); $BtnClearAll.Anchor = "Bottom, Left"; Set-FlatButton $BtnClearAll; $LeftPanel.Controls.Add($BtnClearAll)

$BtnDuplicate = New-Object System.Windows.Forms.Button; $BtnDuplicate.Text = "Duplicate"; $BtnDuplicate.Location = New-Object System.Drawing.Point(10, $row2Y); $BtnDuplicate.Size = New-Object System.Drawing.Size(100, 30); $BtnDuplicate.Anchor = "Bottom, Left"; Set-FlatButton $BtnDuplicate; $LeftPanel.Controls.Add($BtnDuplicate)
$BtnSettings = New-Object System.Windows.Forms.Button; $BtnSettings.Text = "Settings"; $BtnSettings.Location = New-Object System.Drawing.Point(115, $row2Y); $BtnSettings.Size = New-Object System.Drawing.Size(75, 30); $BtnSettings.Anchor = "Bottom, Left"; Set-FlatButton $BtnSettings; $LeftPanel.Controls.Add($BtnSettings)
$BtnDarkMode = New-Object System.Windows.Forms.Button; $BtnDarkMode.Location = New-Object System.Drawing.Point(195, $row2Y); $BtnDarkMode.Size = New-Object System.Drawing.Size(85, 30); $BtnDarkMode.Font = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Regular); $BtnDarkMode.Anchor = "Bottom, Left"; $LeftPanel.Controls.Add($BtnDarkMode)

# --- RIGHT PANEL (Outer Split: Top=Browsers, Bottom=Logs) ---
$SplitRightOuter = New-Object System.Windows.Forms.SplitContainer
$SplitRightOuter.Orientation = [System.Windows.Forms.Orientation]::Horizontal
$SplitRightOuter.Dock = "Fill"; $SplitRightOuter.BorderStyle = "FixedSingle"; $SplitRightOuter.SplitterWidth = 6
$SplitterMain.Panel2.Controls.Add($SplitRightOuter)

# --- BROWSERS (Inner Split: Left=Source, Right=Dest) ---
$SplitBrowsers = New-Object System.Windows.Forms.SplitContainer
$SplitBrowsers.Orientation = [System.Windows.Forms.Orientation]::Vertical
$SplitBrowsers.Dock = "Fill"; $SplitBrowsers.BorderStyle = "FixedSingle"; $SplitBrowsers.SplitterWidth = 6
$SplitRightOuter.Panel1.Controls.Add($SplitBrowsers)

# Helper for generic Provider UI creation 
function Build-BrowserPanel($Panel, $TitleStr, $Prefix) {
    $PTop = New-Object System.Windows.Forms.Panel; $PTop.Dock = "Top"; $PTop.Height = 145; $Panel.Controls.Add($PTop)
    
    $yOff = 35 
    
    if ($Prefix -eq "Src") {
        $LblTName = New-Object System.Windows.Forms.Label; $LblTName.Text = "Transfer Name:"; $LblTName.Font = $BoldFont; $LblTName.Location = New-Object System.Drawing.Point(5, 10); $LblTName.AutoSize = $true; $PTop.Controls.Add($LblTName)
        $TxtTName = New-Object System.Windows.Forms.TextBox; $TxtTName.Location = New-Object System.Drawing.Point(115, 7); $TxtTName.Size = New-Object System.Drawing.Size(260, 25); $TxtTName.Anchor = "Top, Left"; $TxtTName.BackColor = $InputColor; $TxtTName.ForeColor = $TextColor; $TxtTName.BorderStyle = "FixedSingle"; $PTop.Controls.Add($TxtTName)
        Set-Variable -Name "TxtTaskName" -Value $TxtTName -Scope Global
    }

    $LblTitle = New-Object System.Windows.Forms.Label; $LblTitle.Text = $TitleStr; $LblTitle.Font = $BoldFont; $LblTitle.Location = New-Object System.Drawing.Point(5, $yOff); $LblTitle.AutoSize = $true; $PTop.Controls.Add($LblTitle)
    
    $CmbProv = New-Object System.Windows.Forms.ComboBox; $CmbProv.Location = New-Object System.Drawing.Point(115, ($yOff - 3)); $CmbProv.Size = New-Object System.Drawing.Size(260, 25); $CmbProv.DropDownStyle = "DropDownList"; $CmbProv.BackColor = $InputColor; $CmbProv.ForeColor = $TextColor; $CmbProv.FlatStyle = "Flat"; [void]$CmbProv.Items.AddRange(@("--- Select Storage ---", "Google Cloud Storage", "Google Drive", "Local Storage")); $CmbProv.SelectedIndex = 0; $CmbProv.Anchor = "Top, Left"; $PTop.Controls.Add($CmbProv)
    
    $BtnAu = New-Object System.Windows.Forms.Button; $BtnAu.Text = "Login/Auth"; $BtnAu.Location = New-Object System.Drawing.Point(5, ($yOff + 25)); $BtnAu.Size = New-Object System.Drawing.Size(100, 25); $BtnAu.Enabled = $false; Set-FlatButton $BtnAu; $PTop.Controls.Add($BtnAu)
    $LblStat = New-Object System.Windows.Forms.Label; $LblStat.Text = "Not Connected"; $LblStat.ForeColor = "LightCoral"; $LblStat.Location = New-Object System.Drawing.Point(115, ($yOff + 30)); $LblStat.AutoSize = $true; $PTop.Controls.Add($LblStat)
    
    $CmbProj = New-Object System.Windows.Forms.ComboBox; $CmbProj.Location = New-Object System.Drawing.Point(5, ($yOff + 55)); $CmbProj.Size = New-Object System.Drawing.Size(160, 25); $CmbProj.DropDownStyle = "DropDownList"; $CmbProj.FlatStyle = "Flat"; $CmbProj.Visible = $false; $CmbProj.Anchor = "Top, Left"; $PTop.Controls.Add($CmbProj)
    $CmbBuc = New-Object System.Windows.Forms.ComboBox; $CmbBuc.Location = New-Object System.Drawing.Point(175, ($yOff + 55)); $CmbBuc.Size = New-Object System.Drawing.Size(200, 25); $CmbBuc.DropDownStyle = "DropDownList"; $CmbBuc.FlatStyle = "Flat"; $CmbBuc.Visible = $false; $CmbBuc.Anchor = "Top, Left"; $PTop.Controls.Add($CmbBuc)
    
    $BtnLoc = New-Object System.Windows.Forms.Button; $BtnLoc.Text = "Select Folder"; $BtnLoc.Location = New-Object System.Drawing.Point(5, ($yOff + 55)); $BtnLoc.Size = New-Object System.Drawing.Size(100, 25); Set-FlatButton $BtnLoc; $BtnLoc.Visible = $false; $PTop.Controls.Add($BtnLoc)
    
    if ($Prefix -eq "Src") {
        $BtnFile = New-Object System.Windows.Forms.Button; $BtnFile.Text = "Select File"; $BtnFile.Location = New-Object System.Drawing.Point(110, ($yOff + 55)); $BtnFile.Size = New-Object System.Drawing.Size(90, 25); Set-FlatButton $BtnFile; $BtnFile.Visible = $false; $PTop.Controls.Add($BtnFile)
        Set-Variable -Name "BtnSrcFile" -Value $BtnFile -Scope Global
        
        $BtnFilter = New-Object System.Windows.Forms.Button; $BtnFilter.Text = "Filters"; $BtnFilter.Location = New-Object System.Drawing.Point(205, ($yOff + 55)); $BtnFilter.Size = New-Object System.Drawing.Size(75, 25); Set-FlatButton $BtnFilter; $BtnFilter.Visible = $false; $PTop.Controls.Add($BtnFilter)
        Set-Variable -Name "BtnSrcFilter" -Value $BtnFilter -Scope Global
    }

    $LblPth = New-Object System.Windows.Forms.Label; $LblPth.Text = "Path: /"; $LblPth.Location = New-Object System.Drawing.Point(5, ($yOff + 85)); $LblPth.Size = New-Object System.Drawing.Size(390, 20); $LblPth.Anchor = "Top, Left, Right"; $LblPth.AutoSize = $false; $LblPth.AutoEllipsis = $true; $PTop.Controls.Add($LblPth)

    if ($Prefix -eq "Src") {
        
        # UI TWEAK: Replace static bottom panel with a flexible horizontal SplitContainer
        $Global:SplitSrc = New-Object System.Windows.Forms.SplitContainer
        $Global:SplitSrc.Orientation = [System.Windows.Forms.Orientation]::Horizontal
        $Global:SplitSrc.Dock = "Fill"
        $Global:SplitSrc.BorderStyle = "FixedSingle"
        $Global:SplitSrc.SplitterWidth = 6
        $Global:SplitSrc.FixedPanel = [System.Windows.Forms.FixedPanel]::Panel1
        $Panel.Controls.Add($Global:SplitSrc)
        $Global:SplitSrc.BringToFront()

        $PBot = New-Object System.Windows.Forms.Panel; $PBot.Dock = "Fill"; $Global:SplitSrc.Panel2.Controls.Add($PBot)
        
        $PBotTop = New-Object System.Windows.Forms.Panel; $PBotTop.Dock = "Top"; $PBotTop.Height = 35; $PBot.Controls.Add($PBotTop)
        
        $LblExc = New-Object System.Windows.Forms.Label; $LblExc.Text = "Include:"; $LblExc.Font = $BoldFont; $LblExc.Location = New-Object System.Drawing.Point(5, 8); $LblExc.AutoSize = $true; $PBotTop.Controls.Add($LblExc)
        
        $BtnCAll = New-Object System.Windows.Forms.Button; $BtnCAll.Text = "Check All"; $BtnCAll.Location = New-Object System.Drawing.Point(65, 5); $BtnCAll.Size = New-Object System.Drawing.Size(75, 25); Set-FlatButton $BtnCAll; $PBotTop.Controls.Add($BtnCAll)
        $BtnUAll = New-Object System.Windows.Forms.Button; $BtnUAll.Text = "Uncheck All"; $BtnUAll.Location = New-Object System.Drawing.Point(145, 5); $BtnUAll.Size = New-Object System.Drawing.Size(85, 25); Set-FlatButton $BtnUAll; $PBotTop.Controls.Add($BtnUAll)
        
        $LblSrcSort = New-Object System.Windows.Forms.Label; $LblSrcSort.Text = "Sort:"; $LblSrcSort.Font = $BoldFont; $LblSrcSort.Location = New-Object System.Drawing.Point(240, 8); $LblSrcSort.AutoSize = $true; $PBotTop.Controls.Add($LblSrcSort)
        $CmbSrcSrt = New-Object System.Windows.Forms.ComboBox; $CmbSrcSrt.Location = New-Object System.Drawing.Point(280, 5); $CmbSrcSrt.Size = New-Object System.Drawing.Size(85, 25); $CmbSrcSrt.DropDownStyle = "DropDownList"; $CmbSrcSrt.FlatStyle = "Flat"; [void]$CmbSrcSrt.Items.AddRange(@("Name (A-Z)", "Name (Z-A)", "Date (New)", "Date (Old)")); $CmbSrcSrt.SelectedIndex = 0; $PBotTop.Controls.Add($CmbSrcSrt)
        
        Set-Variable -Name "BtnCheckAll" -Value $BtnCAll -Scope Global
        Set-Variable -Name "BtnUncheckAll" -Value $BtnUAll -Scope Global
        Set-Variable -Name "CmbSrcSort" -Value $CmbSrcSrt -Scope Global

        $ChkList = New-Object System.Windows.Forms.CheckedListBox; $ChkList.Dock = "Fill"; $ChkList.IntegralHeight = $false; $ChkList.CheckOnClick = $true; $ChkList.BackColor = $InputColor; $ChkList.ForeColor = $TextColor; $ChkList.BorderStyle = "FixedSingle"; $PBot.Controls.Add($ChkList)
        $ChkList.BringToFront()
        Set-Variable -Name "ChkExclusions" -Value $ChkList -Scope Global
    } else {
        $PBot = New-Object System.Windows.Forms.Panel; $PBot.Dock = "Bottom"; $PBot.Height = 35; $Panel.Controls.Add($PBot)
        
        $LblSort = New-Object System.Windows.Forms.Label; $LblSort.Text = "Sort:"; $LblSort.Font = $BoldFont; $LblSort.Location = New-Object System.Drawing.Point(5, 8); $LblSort.AutoSize = $true; $PBot.Controls.Add($LblSort)
        $CmbSrt = New-Object System.Windows.Forms.ComboBox; $CmbSrt.Location = New-Object System.Drawing.Point(45, 5); $CmbSrt.Size = New-Object System.Drawing.Size(100, 25); $CmbSrt.DropDownStyle = "DropDownList"; $CmbSrt.FlatStyle = "Flat"; [void]$CmbSrt.Items.AddRange(@("Name (A-Z)", "Name (Z-A)", "Date (New)", "Date (Old)")); $CmbSrt.SelectedIndex = 0; $PBot.Controls.Add($CmbSrt)
        Set-Variable -Name "CmbSort" -Value $CmbSrt -Scope Global
        
        $BtnRef = New-Object System.Windows.Forms.Button; $BtnRef.Text = "Refresh"; $BtnRef.Location = New-Object System.Drawing.Point(150, 5); $BtnRef.Size = New-Object System.Drawing.Size(70, 25); $BtnRef.Enabled = $false; Set-FlatButton $BtnRef; $PBot.Controls.Add($BtnRef)
        $BtnNFolder = New-Object System.Windows.Forms.Button; $BtnNFolder.Text = "New Folder"; $BtnNFolder.Location = New-Object System.Drawing.Point(225, 5); $BtnNFolder.Size = New-Object System.Drawing.Size(80, 25); $BtnNFolder.Enabled = $false; Set-FlatButton $BtnNFolder; $PBot.Controls.Add($BtnNFolder)
        
        Set-Variable -Name "BtnDstRef" -Value $BtnRef -Scope Global
        Set-Variable -Name "BtnDstNewF" -Value $BtnNFolder -Scope Global
    }

    $Lbx = New-Object System.Windows.Forms.ListBox; $Lbx.Dock = "Fill"; $Lbx.IntegralHeight = $false; $Lbx.Font = $LogFont; $Lbx.Enabled = $false; $Lbx.BackColor = $InputColor; $Lbx.ForeColor = $TextColor; $Lbx.BorderStyle = "FixedSingle"; 
    if ($Prefix -eq "Src") {
        $Global:SplitSrc.Panel1.Controls.Add($Lbx)
    } else {
        $Panel.Controls.Add($Lbx)
    }
    $Lbx.BringToFront()
    
    Set-Variable -Name "Cmb${Prefix}Provider" -Value $CmbProv -Scope Global
    Set-Variable -Name "Btn${Prefix}Auth" -Value $BtnAu -Scope Global
    Set-Variable -Name "Lbl${Prefix}AuthStatus" -Value $LblStat -Scope Global
    Set-Variable -Name "Cmb${Prefix}ProjList" -Value $CmbProj -Scope Global
    Set-Variable -Name "Cmb${Prefix}BucList" -Value $CmbBuc -Scope Global
    Set-Variable -Name "Btn${Prefix}Loc" -Value $BtnLoc -Scope Global
    Set-Variable -Name "Lbl${Prefix}Path" -Value $LblPth -Scope Global
    Set-Variable -Name "Lbx${Prefix}Dir" -Value $Lbx -Scope Global
}

Build-BrowserPanel $SplitBrowsers.Panel1 "Source Storage:" "Src"
Build-BrowserPanel $SplitBrowsers.Panel2 "Target Storage:" "Dst"

# --- BOTTOM PANEL (Action & Logs) ---
$PBotOuter = $SplitRightOuter.Panel2

$PAction = New-Object System.Windows.Forms.Panel; $PAction.Dock = "Top"; $PAction.Height = 40; $PBotOuter.Controls.Add($PAction)
$BtnTable = New-Object System.Windows.Forms.TableLayoutPanel; $BtnTable.ColumnCount = 2; [void]$BtnTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50))); [void]$BtnTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50))); $BtnTable.RowCount = 1; [void]$BtnTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))); $BtnTable.Dock = "Fill"; $BtnTable.Margin = New-Object System.Windows.Forms.Padding(0)
$BtnUpload = New-Object System.Windows.Forms.Button; $BtnUpload.Text = "START TRANSFER"; $BtnUpload.Font = $BoldFont; $BtnUpload.Enabled = $false; $BtnUpload.Dock = "Fill"; $BtnUpload.Margin = New-Object System.Windows.Forms.Padding(2); $BtnUpload.FlatStyle = "Flat"; $BtnUpload.FlatAppearance.BorderSize = 0; $BtnUpload.BackColor = "MediumSeaGreen"; $BtnUpload.ForeColor = "Black"
$BtnStop = New-Object System.Windows.Forms.Button; $BtnStop.Text = "STOP TRANSFER"; $BtnStop.Font = $BoldFont; $BtnStop.Enabled = $false; $BtnStop.Dock = "Fill"; $BtnStop.Margin = New-Object System.Windows.Forms.Padding(2); $BtnStop.FlatStyle = "Flat"; $BtnStop.FlatAppearance.BorderSize = 0; $BtnStop.BackColor = "IndianRed"; $BtnStop.ForeColor = "White"
$BtnTable.Controls.Add($BtnUpload, 0, 0); $BtnTable.Controls.Add($BtnStop, 1, 0); $PAction.Controls.Add($BtnTable)

$PLogTop = New-Object System.Windows.Forms.Panel; $PLogTop.Dock = "Top"; $PLogTop.Height = 30; $PBotOuter.Controls.Add($PLogTop)
$LblFolderCount = New-Object System.Windows.Forms.Label; $LblFolderCount.Text = "Item(s): 0 out of 0"; $LblFolderCount.Font = $BoldFont; $LblFolderCount.AutoSize = $true; $LblFolderCount.Location = New-Object System.Drawing.Point(5, 7); $LblFolderCount.Anchor = "Top, Left"; $PLogTop.Controls.Add($LblFolderCount)

$BtnOpenLog = New-Object System.Windows.Forms.Button
$BtnOpenLog.Text = "Open Log in Notepad"
$BtnOpenLog.Size = New-Object System.Drawing.Size(130, 22)
$BtnOpenLog.Location = New-Object System.Drawing.Point(260, 4)
$BtnOpenLog.Anchor = "Top, Left"
Set-FlatButton $BtnOpenLog
$PLogTop.Controls.Add($BtnOpenLog)

$LblProgress = New-Object System.Windows.Forms.Label; $LblProgress.Text = "Overall Progress (0%):"; $LblProgress.Font = $BoldFont; $LblProgress.AutoSize = $false; $LblProgress.Size = New-Object System.Drawing.Size(260, 20); $LblProgress.TextAlign = [System.Drawing.ContentAlignment]::TopRight; $LblProgress.Location = New-Object System.Drawing.Point(400, 7); $LblProgress.Anchor = "Top, Right"; $PLogTop.Controls.Add($LblProgress)
$PrgTotal = New-Object System.Windows.Forms.ProgressBar; $PrgTotal.Location = New-Object System.Drawing.Point(665, 5); $PrgTotal.Size = New-Object System.Drawing.Size(150, 20); $PrgTotal.Anchor = "Top, Right"; $PrgTotal.Style = "Continuous"; $PLogTop.Controls.Add($PrgTotal)

$RtbLog = New-Object System.Windows.Forms.RichTextBox; $RtbLog.Dock = "Fill"; $RtbLog.BackColor = "Black"; $RtbLog.ForeColor = "LightGray"; $RtbLog.Font = $LogFont; $RtbLog.ReadOnly = $true; $RtbLog.BorderStyle = "FixedSingle"; $PBotOuter.Controls.Add($RtbLog)
$PAction.BringToFront(); $PLogTop.BringToFront(); $RtbLog.BringToFront()

# --- INITIALIZE UI STYLES ---
$AllDropdowns = @($CmbSrcProvider, $CmbSrcProjList, $CmbSrcBucList, $CmbDstProvider, $CmbDstProjList, $CmbDstBucList, $CmbSort, $CmbSrcSort)
foreach ($cb in $AllDropdowns) { $cb.FlatStyle = "Flat" }

function Update-Theme {
    $bg = if ($Global:AppSettings.IsDarkMode) { [System.Drawing.Color]::FromArgb(255, 30, 30, 30) } else { [System.Drawing.Color]::WhiteSmoke }
    $fg = if ($Global:AppSettings.IsDarkMode) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::Black }
    $panelBg = if ($Global:AppSettings.IsDarkMode) { [System.Drawing.Color]::FromArgb(255, 45, 45, 48) } else { [System.Drawing.Color]::LightGray }
    $inputBg = if ($Global:AppSettings.IsDarkMode) { [System.Drawing.Color]::FromArgb(255, 37, 37, 38) } else { [System.Drawing.Color]::White }
    $dropdownBg = [System.Drawing.ColorTranslator]::FromHtml("#E0E0E0"); $dropdownFg = [System.Drawing.Color]::Black

    $Form.BackColor = $bg; $Form.ForeColor = $fg; $LeftPanel.BackColor = $bg
    
    $LvwTasks.BackColor = $inputBg; $LvwTasks.ForeColor = $fg
    $TxtTaskName.BackColor = $inputBg; $TxtTaskName.ForeColor = $fg
    $ChkExclusions.BackColor = $inputBg; $ChkExclusions.ForeColor = $fg
    $LbxSrcDir.BackColor = $inputBg; $LbxSrcDir.ForeColor = $fg
    $LbxDstDir.BackColor = $inputBg; $LbxDstDir.ForeColor = $fg
    
    $RtbLog.BackColor = if ($Global:AppSettings.IsDarkMode) { "Black" } else { "White" }
    $RtbLog.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightGray" } else { "Black" }

    foreach ($cb in $AllDropdowns) { $cb.BackColor = $dropdownBg; $cb.ForeColor = $dropdownFg }
    
    $ThemeBtns = @($BtnNewTask, $BtnDuplicate, $BtnDelTask, $BtnClearAll, $BtnSettings, $BtnSrcAuth, $BtnSrcLoc, $BtnSrcFile, $BtnSrcFilter, $BtnDstAuth, $BtnDstLoc, $BtnDstRef, $BtnDstNewF, $BtnCheckAll, $BtnUncheckAll, $BtnOpenLog)
    foreach ($btn in $ThemeBtns) { if($btn) { $btn.BackColor = $panelBg; $btn.ForeColor = $fg } }

    if ($Global:AppSettings.IsDarkMode) {
        $BtnDarkMode.BackColor = [System.Drawing.Color]::DodgerBlue; $BtnDarkMode.ForeColor = [System.Drawing.Color]::White; $BtnDarkMode.Text = "Dark Mode: ON"
    } else {
        $BtnDarkMode.BackColor = $panelBg; $BtnDarkMode.ForeColor = $fg; $BtnDarkMode.Text = "Dark Mode: OFF"
    }
}
Update-Theme

# --- BACKEND HELPERS ---
function Log-Message([string]$msg, [string]$color = "LightGray") {
    $RtbLog.SelectionStart = $RtbLog.TextLength
    if (-not $Global:AppSettings.IsDarkMode -and $color -eq "LightGray") { $color = "Black" }
    if (-not $Global:AppSettings.IsDarkMode -and $color -eq "White") { $color = "DarkGray" }
    $RtbLog.SelectionColor = [System.Drawing.Color]::$color
    $RtbLog.AppendText("$msg`n"); $RtbLog.ScrollToCaret()
}

function Execute-Cli-Json($cmdArgs, [bool]$isRclone = $false) {
    if (Test-Path -LiteralPath $Global:JsonTempFile) { Remove-Item -LiteralPath $Global:JsonTempFile -Force -ErrorAction SilentlyContinue }
    
    if ($isRclone) { Invoke-Expression "& `"$Global:RcloneExe`" $cmdArgs > `"$Global:JsonTempFile`" 2> `$null" }
    else { Invoke-Expression "$cmdArgs > `"$Global:JsonTempFile`" 2> `$null" }
    
    if (Test-Path -LiteralPath $Global:JsonTempFile) {
        $raw = Get-Content -Raw -LiteralPath $Global:JsonTempFile
        if (![string]::IsNullOrWhiteSpace($raw)) { try { return (ConvertFrom-Json -InputObject $raw) } catch { return $null } }
    }
    return $null
}

function ConvertTo-ProcessArgument([string]$value) {
    if ($null -eq $value -or $value.Length -eq 0) { return '""' }
    if ($value -notmatch '[\s"]') { return $value }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashCount = 0

    foreach ($char in $value.ToCharArray()) {
        if ($char -eq '\') {
            $backslashCount++
            continue
        }

        if ($char -eq '"') {
            if ($backslashCount -gt 0) { [void]$builder.Append(('\' * ($backslashCount * 2))) }
            [void]$builder.Append('\"')
            $backslashCount = 0
            continue
        }

        if ($backslashCount -gt 0) {
            [void]$builder.Append(('\' * $backslashCount))
            $backslashCount = 0
        }

        [void]$builder.Append($char)
    }

    if ($backslashCount -gt 0) { [void]$builder.Append(('\' * ($backslashCount * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-ProcessArguments([string[]]$arguments) {
    if ($null -eq $arguments -or $arguments.Count -eq 0) { return "" }
    return (($arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
}

function New-TransferCommand {
    param(
        [string]$ToolPath,
        [string]$Source,
        [string]$Destination,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory = "",
        [hashtable]$Environment = @{},
        [string]$Description = ""
    )

    $command = [TransferCommand]::new()
    $command.Source = $Source
    $command.Destination = $Destination
    $command.ToolPath = $ToolPath
    $command.Arguments = Join-ProcessArguments $ArgumentList
    $command.WorkingDirectory = $WorkingDirectory
    $command.Environment = @{}
    if ($Environment) {
        foreach ($key in $Environment.Keys) { $command.Environment[$key] = [string]$Environment[$key] }
    }
    $command.Description = $Description
    return $command
}

function Invoke-TransferJob {
    param([TransferJob]$TransferJob)

    $queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $state = [hashtable]::Synchronized(@{
        StopRequested = $false
        Completed = $false
        ExitCode = $null
        ProcessId = $null
        ErrorMessage = $null
    })

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()

    $ps = [PowerShell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript({
        param($job, $queueRef, $stateRef)

        foreach ($command in $job.Commands) {
            if ($stateRef.StopRequested) { break }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $command.ToolPath
            $psi.Arguments = $command.Arguments
            if (-not [string]::IsNullOrWhiteSpace($command.WorkingDirectory)) { $psi.WorkingDirectory = $command.WorkingDirectory }
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

            if ($command.Environment) {
                foreach ($name in $command.Environment.Keys) {
                    $psi.EnvironmentVariables[$name] = [string]$command.Environment[$name]
                }
            }

            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $psi
            $process.EnableRaisingEvents = $true

            $queueCopy = $queueRef
            $descCopy = $command.Description

            $stdOutHandler = [System.Diagnostics.DataReceivedEventHandler]{
                param($sender, $eventArgs)
                if (-not [string]::IsNullOrWhiteSpace($eventArgs.Data)) {
                    $queueCopy.Enqueue([PSCustomObject]@{
                        Type = "log"
                        Stream = "stdout"
                        Text = $eventArgs.Data
                        ProcessId = $sender.Id
                        Description = $descCopy
                    })
                }
            }.GetNewClosure()

            $stdErrHandler = [System.Diagnostics.DataReceivedEventHandler]{
                param($sender, $eventArgs)
                if (-not [string]::IsNullOrWhiteSpace($eventArgs.Data)) {
                    $queueCopy.Enqueue([PSCustomObject]@{
                        Type = "log"
                        Stream = "stderr"
                        Text = $eventArgs.Data
                        ProcessId = $sender.Id
                        Description = $descCopy
                    })
                }
            }.GetNewClosure()

            $process.add_OutputDataReceived($stdOutHandler)
            $process.add_ErrorDataReceived($stdErrHandler)

            try {
                if (-not $process.Start()) { throw "Failed to start $($command.ToolPath)." }
            } catch {
                $stateRef.ErrorMessage = $_.Exception.Message
                $stateRef.ExitCode = -1
                $queueRef.Enqueue([PSCustomObject]@{
                    Type = "log"
                    Stream = "stderr"
                    Text = $_.Exception.Message
                    ProcessId = 0
                    Description = $descCopy
                })
                break
            }

            $stateRef.ProcessId = $process.Id
            $queueRef.Enqueue([PSCustomObject]@{
                Type = "process-started"
                Stream = ""
                Text = $descCopy
                ProcessId = $process.Id
                Description = $descCopy
            })

            $process.BeginOutputReadLine()
            $process.BeginErrorReadLine()

            $stopIssued = $false
            while (-not $process.WaitForExit(200)) {
                if ($stateRef.StopRequested -and -not $stopIssued) {
                    $stopIssued = $true
                    try { Start-Process "taskkill.exe" -ArgumentList "/PID $($process.Id) /T /F" -WindowStyle Hidden -Wait | Out-Null } catch {}
                }
            }

            $process.WaitForExit()
            $stateRef.ProcessId = $null
            $stateRef.ExitCode = $process.ExitCode

            $queueRef.Enqueue([PSCustomObject]@{
                Type = "process-exited"
                Stream = ""
                Text = $descCopy
                ProcessId = $process.Id
                ExitCode = $process.ExitCode
                Description = $descCopy
            })

            $process.remove_OutputDataReceived($stdOutHandler)
            $process.remove_ErrorDataReceived($stdErrHandler)
            $process.Dispose()

            if ($stateRef.StopRequested -or $stateRef.ExitCode -notin @(0, 1, 9)) { break }
        }

        $stateRef.Completed = $true
        $finalExitCode = if ($null -ne $stateRef.ExitCode) { [int]$stateRef.ExitCode } elseif ($stateRef.StopRequested) { 9 } else { 0 }
        $queueRef.Enqueue([PSCustomObject]@{
            Type = "complete"
            Stream = ""
            Text = $stateRef.ErrorMessage
            ProcessId = 0
            ExitCode = $finalExitCode
            Stopped = [bool]$stateRef.StopRequested
        })
    }).AddArgument($TransferJob).AddArgument($queue).AddArgument($state)

    $asyncResult = $ps.BeginInvoke()

    return [PSCustomObject]@{
        Queue = $queue
        State = $state
        Runspace = $runspace
        PowerShell = $ps
        AsyncResult = $asyncResult
    }
}

function Restore-TransferUiState {
    $Global:IsTransferring = $false

    $LvwTasks.BackColor = $InputColor
    $ChkExclusions.BackColor = $InputColor
    $LbxSrcDir.BackColor = $InputColor
    $LbxDstDir.BackColor = $InputColor

    $BtnNewTask.Enabled = $true; $BtnDelTask.Enabled = $true; $BtnClearAll.Enabled = $true; $BtnDuplicate.Enabled = $true
    $BtnSrcLoc.Enabled = $true; $BtnSrcFilter.Enabled = $true; $BtnDstLoc.Enabled = $true; $BtnDstNewF.Enabled = $true; $BtnDstRef.Enabled = $true
    $BtnUpload.Enabled = $true; $BtnCheckAll.Enabled = $true; $BtnUncheckAll.Enabled = $true
    $BtnStop.Enabled = $false
}

function Stop-ActiveTransferProcess {
    $context = $Global:ActiveTransfer
    if (-not $context) { return }

    $Global:StopTransfer = $true
    if ($context.State) { $context.State.StopRequested = $true }

    $processId = $null
    if ($Global:CurrentProcess) {
        try {
            if (-not $Global:CurrentProcess.HasExited) { $processId = $Global:CurrentProcess.Id }
        } catch {}
    }
    if (-not $processId -and $context.State) { $processId = $context.State.ProcessId }

    if ($processId) {
        try { Start-Process "taskkill.exe" -ArgumentList "/PID $processId /T /F" -WindowStyle Hidden -Wait | Out-Null } catch {}
    }
}

function Update-TransferUiFromLine {
    param(
        [pscustomobject]$Context,
        [string]$Line,
        [string]$Stream = "stdout"
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return }

    $trimmedLine = $Line.Trim()
    $logColor = if ($Stream -eq "stderr") { "LightCoral" } else { "White" }
    Log-Message $trimmedLine $logColor

    if ($Context.RunLogFile) {
        [System.IO.File]::AppendAllText($Context.RunLogFile, $trimmedLine + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding $false))
    }

    $isUpdate = $false

    if ($trimmedLine -match "(?i)userRateLimitExceeded|upload limit error|quota exceeded|RATE_LIMIT_EXCEEDED|rateLimitExceeded") {
        if (-not $Context.QuotaReached) {
            Log-Message "QUOTA LIMIT REACHED. Transfer safely stopped." "Yellow"
            $Context.QuotaReached = $true
            Stop-ActiveTransferProcess
        }
    }

    if ($trimmedLine -match 'Transferred:.*?,\s*(\d{1,3})%,\s*([\d\.]+\s*[kKMGT]?i?B/s)') {
        $pct = [int]$Matches[1]
        $Global:TransferSpeed = $Matches[2]
        if ($pct -ge 0 -and $pct -le 100) {
            $PrgTotal.Style = "Continuous"
            if ($pct -lt 100 -and $pct -gt 0) { $PrgTotal.Value = $pct + 1; $PrgTotal.Value = $pct } else { $PrgTotal.Value = $pct }
            $LblProgress.Text = "Progress ($($Context.DisplayName)): $pct%"
        }
    }

    if ($trimmedLine -match '^Transferred:\s+(\d+)\s*/\s*(\d+),\s*\d{1,3}%$') {
        $LblFolderCount.Text = "Item(s): $($Matches[1]) out of $($Matches[2])"
    }

    if ($trimmedLine -match "(?i)INFO\s+:\s+(.+?):\s+Copied" -or $trimmedLine -match "Copying file://(.+?)\s+to\s+(gs://[^\s]+)" -or $trimmedLine -match "Copying gs://(.+?)\s+to\s+(.+)") {
        $Context.RegCopied++
        [void]$Context.ReportLog.Add("[COPIED]  $($Matches[1])")
        $isUpdate = $true
    }
    elseif ($trimmedLine -match "(?i)INFO\s+:\s+(.+?):\s+Unchanged skipping" -or $trimmedLine -match "Skipping existing(?: destination)? item\s+(.+)") {
        $isUpdate = $true
    }
    elseif ($trimmedLine -match "(?i)ERROR\s+:\s+(.+?):\s+(.+)") {
        $Context.RegFailed++
        [void]$Context.ReportLog.Add("[FAILED]  $($Matches[1]) -> $($Matches[2])")
        $isUpdate = $true
    }
    elseif ($trimmedLine -match "ERROR:\s+(.+)") {
        $Context.RegFailed++
        [void]$Context.ReportLog.Add("[FAILED]  $($Matches[1])")
        $isUpdate = $true
    }
    elseif ($trimmedLine -match "(?i)CRITICAL(.*?):\s+(.+)") {
        $Context.RegFailed++
        [void]$Context.ReportLog.Add("[CRITICAL] $($Matches[2])")
        $isUpdate = $true
    }

    if ($isUpdate) {
        $totalProcessed = $Context.RegCopied + $Context.RegFailed
        if ($Context.TotalSourceItems -gt 0) {
            $pct = [math]::Round(($totalProcessed / $Context.TotalSourceItems) * 100)
            if ($pct -gt 100) { $pct = 100 }
            $PrgTotal.Style = "Continuous"
            if ($pct -lt 100 -and $pct -gt 0) { $PrgTotal.Value = $pct + 1; $PrgTotal.Value = $pct } else { $PrgTotal.Value = $pct }
            $LblProgress.Text = "Progress ($($Context.DisplayName)): $pct%"
            $LblFolderCount.Text = "Item(s): $totalProcessed out of $($Context.TotalSourceItems)"
        } else {
            $LblFolderCount.Text = "Item(s) Processed: $totalProcessed"
        }
    }
}

function Complete-TransferJob {
    param([pscustomobject]$Context)

    if (-not $Context -or $Context.Finalized) { return }
    $Context.Finalized = $true

    if ($Global:TransferUiTimer) { $Global:TransferUiTimer.Stop() }

    if ($Context.AsyncResult) {
        try { $null = $Context.PowerShell.EndInvoke($Context.AsyncResult) } catch {
            $Context.ProcessFailed = $true
            if (-not $Context.QuotaReached) { Log-Message "Transfer worker failed: $($_.Exception.Message)" "LightCoral" }
        }
    }

    if ($Context.PowerShell) { $Context.PowerShell.Dispose() }
    if ($Context.Runspace) {
        $Context.Runspace.Close()
        $Context.Runspace.Dispose()
    }

    $exitCode = if ($null -ne $Context.ExitCode) { [int]$Context.ExitCode } elseif ($Context.State -and $null -ne $Context.State.ExitCode) { [int]$Context.State.ExitCode } elseif ($Global:StopTransfer) { 9 } else { 0 }
    if ($exitCode -notin @(0, 1, 9)) {
        $Context.ProcessFailed = $true
        if (-not $Context.QuotaReached) { Log-Message "Process finished with errors (Exit Code: $exitCode). Review log above." "LightCoral" }
    }

    $PrgTotal.Style = "Continuous"
    if ($Global:StopTransfer) {
        if ($PrgTotal.Value -gt 100) { $PrgTotal.Value = 100 }
        $LblProgress.Text = "Transfer Aborted"
    } else {
        $PrgTotal.Value = 100
        $LblProgress.Text = "Progress (Complete) ================= 100%"
    }

    $totalSourceItems = $Context.TotalSourceItems
    $regSkipped = if ($totalSourceItems -gt 0) { [math]::Max(0, ($totalSourceItems - $Context.RegCopied - $Context.RegFailed)) } else { 0 }
    $totalProcessed = $Context.RegCopied + $Context.RegFailed
    if ($LblFolderCount.Text -match "Calculating" -or $totalSourceItems -gt 0) {
        $LblFolderCount.Text = "Item(s) Processed: $totalProcessed"
    }

    $Context.Stopwatch.Stop()

    $cleanTaskName = $TxtTaskName.Text -replace '[\\/:*?"<>|]', '_'
    $logDir = "C:\data_transfer_log\"
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logPath = Join-Path $logDir "${cleanTaskName}_$($Context.StartTimeSafe).txt"

    $cleanLogString = $Context.ReportLog -join [Environment]::NewLine
    $finalStatus = if ($Context.QuotaReached) { "Error" } elseif ($Global:StopTransfer) { "Aborted" } elseif ($Context.RegFailed -gt 0 -or $Context.ProcessFailed) { "Error" } else { "Completed" }

    $summary = @"
=================================================
AUDIT SUMMARY: Data Transfer Tool
=================================================
Task Name: $($TxtTaskName.Text)
Status: $finalStatus
Duration: $($Context.Stopwatch.Elapsed.ToString("hh\:mm\:ss"))
Source: $Global:SrcProvider | Dest: $Global:DstProvider
Exit Code: $exitCode
Average Speed: $Global:TransferSpeed

METRICS:
- Total Items in Source: $totalSourceItems
- Copied: $($Context.RegCopied)
- Skipped: $regSkipped
- Failed: $($Context.RegFailed)

=================================================
DETAILED TRANSFER LOG:
=================================================
$cleanLogString
"@

    $summary | Out-File -LiteralPath $logPath -Encoding utf8
    Log-Message "`r`nSummary File Saved: $logPath" "Cyan"

    if ($Global:CurrentTaskId) {
        for ($i = 0; $i -lt $Global:Tasks.Count; $i++) {
            if ($Global:Tasks[$i].Id -eq $Global:CurrentTaskId) {
                $Global:Tasks[$i].Status = $finalStatus
                $Global:Tasks[$i].CompleteDate = (Get-Date -Format "MM/dd/yyyy HH:mm")
                $Global:Tasks[$i].LogData = $RtbLog.Text
                $Global:Tasks[$i].LogFilePath = $logPath
                break
            }
        }
        Save-Tasks
        Sync-TasksToUI
    }

    try {
        if ($Context.Job -and $Context.Job.ExcludeFile -and (Test-Path -LiteralPath $Context.Job.ExcludeFile)) {
            Remove-Item -LiteralPath $Context.Job.ExcludeFile -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    $Global:CurrentProcess = $null
    $Global:ActiveTransfer = $null
    Restore-TransferUiState
}

$Global:TransferUiTimer = New-Object System.Windows.Forms.Timer
$Global:TransferUiTimer.Interval = 150
$Global:TransferUiTimer.Add_Tick({
    $context = $Global:ActiveTransfer
    if (-not $context) {
        $Global:TransferUiTimer.Stop()
        return
    }

    $entry = $null
    $processed = 0
    while ($processed -lt 250 -and $context.Queue.TryDequeue([ref]$entry)) {
        $processed++

        switch ($entry.Type) {
            "process-started" {
                try { $Global:CurrentProcess = [System.Diagnostics.Process]::GetProcessById($entry.ProcessId) } catch { $Global:CurrentProcess = $null }
            }
            "process-exited" {
                $context.ExitCode = $entry.ExitCode
                $Global:CurrentProcess = $null
            }
            "log" {
                Update-TransferUiFromLine -Context $context -Line $entry.Text -Stream $entry.Stream
            }
            "complete" {
                $context.ExitCode = $entry.ExitCode
                if ($entry.Stopped) { $Global:StopTransfer = $true }
                if (-not [string]::IsNullOrWhiteSpace($entry.Text) -and -not $context.QuotaReached) {
                    Log-Message $entry.Text "LightCoral"
                }
            }
        }
    }

    if ($context.State.Completed -and $context.Queue.IsEmpty -and -not $context.Finalized) {
        Complete-TransferJob -Context $context
    }
})

function Is-Filtered([string]$name) {
    $sysRegex = '(?i)^(desktop\.ini|thumbs\.db|\$RECYCLE\.BIN|System Volume Information|pagefile\.sys|hiberfil\.sys|swapfile\.sys|\$SysReset|\$Windows\.~BT|\$Windows\.~WS|\$WinREAgent)$'
    if ($name -match $sysRegex) { return $true }
    
    if ($Global:CustomFilters -and $Global:CustomFilters.Count -gt 0) {
        foreach ($cf in $Global:CustomFilters) {
            if ([string]::IsNullOrWhiteSpace($cf)) { continue }
            $leafFilter = ($cf -split '[\\/]' | Where-Object { $_ -ne "" })[-1]
            if ($leafFilter) {
                $rx = '^' + ([regex]::Escape($leafFilter) -replace '\\\*', '.*' -replace '\\\?', '.') + '$'
                if ($name -match "(?i)$rx") { return $true }
            }
        }
    }
    return $false
}

function Show-FilterDialog {
    $FF = New-Object System.Windows.Forms.Form
    $FF.Text = "Exclusion Filters"
    $FF.Size = New-Object System.Drawing.Size(350, 450)
    $FF.StartPosition = "CenterParent"
    $FF.FormBorderStyle = "FixedDialog"
    $FF.MaximizeBox = $false; $FF.MinimizeBox = $false
    $FF.BackColor = $Form.BackColor; $FF.ForeColor = $Form.ForeColor

    $lblF = New-Object System.Windows.Forms.Label
    $lblF.Text = "Files/folders NOT to copy (Glob patterns):"
    $lblF.Location = New-Object System.Drawing.Point(10, 10)
    $lblF.Font = $BoldFont
    $lblF.AutoSize = $true
    $FF.Controls.Add($lblF)

    $lbxF = New-Object System.Windows.Forms.ListBox
    $lbxF.Location = New-Object System.Drawing.Point(10, 35)
    $lbxF.Size = New-Object System.Drawing.Size(310, 300)
    $lbxF.BackColor = $InputColor; $lbxF.ForeColor = $TextColor
    $lbxF.BorderStyle = "FixedSingle"
    foreach ($f in $Global:CustomFilters) { [void]$lbxF.Items.Add($f) }
    $FF.Controls.Add($lbxF)

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = "+ Add"
    $btnAdd.Location = New-Object System.Drawing.Point(10, 345)
    $btnAdd.Size = New-Object System.Drawing.Size(80, 25)
    Set-FlatButton $btnAdd
    $FF.Controls.Add($btnAdd)

    $btnRem = New-Object System.Windows.Forms.Button
    $btnRem.Text = "- Remove"
    $btnRem.Location = New-Object System.Drawing.Point(100, 345)
    $btnRem.Size = New-Object System.Drawing.Size(80, 25)
    Set-FlatButton $btnRem
    $FF.Controls.Add($btnRem)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "OK"
    $btnOk.Location = New-Object System.Drawing.Point(150, 380)
    $btnOk.Size = New-Object System.Drawing.Size(80, 30)
    Set-FlatButton $btnOk
    $FF.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(240, 380)
    $btnCancel.Size = New-Object System.Drawing.Size(80, 30)
    Set-FlatButton $btnCancel
    $FF.Controls.Add($btnCancel)

    $btnAdd.Add_Click({
        $newF = [Microsoft.VisualBasic.Interaction]::InputBox("Enter exclusion pattern (e.g. *.tmp, \System Volume Information\):", "Add Filter", "")
        if (![string]::IsNullOrWhiteSpace($newF)) { [void]$lbxF.Items.Add($newF.Trim()) }
    })
    
    $lbxF.Add_DoubleClick({
        if ($lbxF.SelectedIndex -ge 0) {
            $current = $lbxF.SelectedItem
            $edited = [Microsoft.VisualBasic.Interaction]::InputBox("Edit exclusion pattern:", "Edit Filter", $current)
            if (![string]::IsNullOrWhiteSpace($edited)) {
                $lbxF.Items[$lbxF.SelectedIndex] = $edited.Trim()
            }
        }
    })

    $btnRem.Add_Click({
        if ($lbxF.SelectedIndex -ge 0) { $lbxF.Items.RemoveAt($lbxF.SelectedIndex) }
    })

    $btnOk.Add_Click({
        $Global:CustomFilters = @()
        foreach ($item in $lbxF.Items) { $Global:CustomFilters += $item }
        
        $Global:AppSettings.CustomFilters = $Global:CustomFilters
        Save-Settings
        
        $FF.DialogResult = "OK"
        $FF.Close()
        
        if ($Global:SrcProvider -ne "" -and $Global:SrcPath -ne $null) { Update-Directory $true }
    })

    $btnCancel.Add_Click({ $FF.DialogResult = "Cancel"; $FF.Close() })

    $FF.ShowDialog() | Out-Null
}

$BtnSrcFilter.Add_Click({ Show-FilterDialog })

function Show-SettingsDialog {
    $SF = New-Object System.Windows.Forms.Form
    $SF.Text = "Configuration Settings"
    $SF.Size = New-Object System.Drawing.Size(530, 320); $SF.StartPosition = "CenterParent"; $SF.FormBorderStyle = "FixedDialog"; $SF.MaximizeBox = $false; $SF.MinimizeBox = $false
    $SF.BackColor = $Form.BackColor; $SF.ForeColor = $Form.ForeColor
    
    $lblR = New-Object System.Windows.Forms.Label; $lblR.Text = "Rclone.exe Path:"; $lblR.Location = New-Object System.Drawing.Point(15, 20); $lblR.AutoSize = $true; $SF.Controls.Add($lblR)
    $txtR = New-Object System.Windows.Forms.TextBox; $txtR.Location = New-Object System.Drawing.Point(120, 17); $txtR.Size = New-Object System.Drawing.Size(290, 20); $txtR.Text = $Global:AppSettings.RclonePath; $txtR.BackColor = $TxtTaskName.BackColor; $txtR.ForeColor = $TxtTaskName.ForeColor; $txtR.BorderStyle = "FixedSingle"; $SF.Controls.Add($txtR)
    $btnBR = New-Object System.Windows.Forms.Button; $btnBR.Text = "Browse"; $btnBR.Location = New-Object System.Drawing.Point(420, 15); $btnBR.FlatStyle="Flat"; $btnBR.FlatAppearance.BorderSize=1; $btnBR.FlatAppearance.BorderColor=[System.Drawing.Color]::Gray; $btnBR.BackColor = $BtnSettings.BackColor; $btnBR.ForeColor = $BtnSettings.ForeColor; $SF.Controls.Add($btnBR)
    
    $lblG = New-Object System.Windows.Forms.Label; $lblG.Text = "GCloud Bin Dir:"; $lblG.Location = New-Object System.Drawing.Point(15, 55); $lblG.AutoSize = $true; $SF.Controls.Add($lblG)
    $txtG = New-Object System.Windows.Forms.TextBox; $txtG.Location = New-Object System.Drawing.Point(120, 52); $txtG.Size = New-Object System.Drawing.Size(290, 20); $txtG.Text = $Global:AppSettings.GCloudPath; $txtG.BackColor = $TxtTaskName.BackColor; $txtG.ForeColor = $TxtTaskName.ForeColor; $txtG.BorderStyle = "FixedSingle"; $SF.Controls.Add($txtG)
    $btnBG = New-Object System.Windows.Forms.Button; $btnBG.Text = "Browse"; $btnBG.Location = New-Object System.Drawing.Point(420, 50); $btnBG.FlatStyle="Flat"; $btnBG.FlatAppearance.BorderSize=1; $btnBG.FlatAppearance.BorderColor=[System.Drawing.Color]::Gray; $btnBG.BackColor = $BtnSettings.BackColor; $btnBG.ForeColor = $BtnSettings.ForeColor; $SF.Controls.Add($btnBG)
    
    $lblNote = New-Object System.Windows.Forms.Label; $lblNote.Text = "Note: These paths are optional. If you have already added Google Cloud SDK and Rclone to your System Environment Variables (PATH), you can leave these blank."; $lblNote.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic); $lblNote.ForeColor = if ($Global:AppSettings.IsDarkMode) { [System.Drawing.Color]::LightGray } else { [System.Drawing.Color]::DimGray }; $lblNote.Location = New-Object System.Drawing.Point(15, 85); $lblNote.Size = New-Object System.Drawing.Size(485, 40); $SF.Controls.Add($lblNote)

    $chkDebug = New-Object System.Windows.Forms.CheckBox
    $chkDebug.Text = "Enable Verbose Debug Logging (Requires extra pre-scan time)"
    $chkDebug.Location = New-Object System.Drawing.Point(15, 130)
    $chkDebug.Size = New-Object System.Drawing.Size(485, 20)
    $chkDebug.Checked = $Global:AppSettings.IsDebugMode
    $SF.Controls.Add($chkDebug)

    $lblT = New-Object System.Windows.Forms.Label; $lblT.Text = "Rclone Transfer Threads (1-6):"; $lblT.Location = New-Object System.Drawing.Point(15, 160); $lblT.AutoSize = $true; $SF.Controls.Add($lblT)
    
    $cmbT = New-Object System.Windows.Forms.ComboBox; $cmbT.Location = New-Object System.Drawing.Point(200, 157); $cmbT.Size = New-Object System.Drawing.Size(50, 20); $cmbT.DropDownStyle = "DropDownList"; $cmbT.FlatStyle = "Flat"; [void]$cmbT.Items.AddRange(@(1,2,3,4,5,6)); $cmbT.SelectedItem = $Global:AppSettings.TransferThreads; $cmbT.BackColor = $TxtTaskName.BackColor; $cmbT.ForeColor = $TxtTaskName.ForeColor; $SF.Controls.Add($cmbT)

    $lblTWarn = New-Object System.Windows.Forms.Label; $lblTWarn.Text = "Note: Using 4 or more threads on Google Drive may trigger 403 Rate Limit Quota Exceeded errors. 4+ threads are recommended for Local-to-Local transfers only."; $lblTWarn.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic); $lblTWarn.ForeColor = if ($Global:AppSettings.IsDarkMode) { [System.Drawing.Color]::LightCoral } else { [System.Drawing.Color]::IndianRed }; $lblTWarn.Location = New-Object System.Drawing.Point(15, 185); $lblTWarn.Size = New-Object System.Drawing.Size(485, 30); $SF.Controls.Add($lblTWarn)

    $btnSave = New-Object System.Windows.Forms.Button; $btnSave.Text = "Save & Apply"; $btnSave.Location = New-Object System.Drawing.Point(120, 230); $btnSave.Size = New-Object System.Drawing.Size(120, 30); $btnSave.FlatStyle="Flat"; $btnSave.FlatAppearance.BorderSize=1; $btnSave.FlatAppearance.BorderColor=[System.Drawing.Color]::Gray; $btnSave.BackColor = $BtnSettings.BackColor; $btnSave.ForeColor = $BtnSettings.ForeColor; $SF.Controls.Add($btnSave)
    
    $btnHelp = New-Object System.Windows.Forms.Button; $btnHelp.Text = "Help / Guide"; $btnHelp.Location = New-Object System.Drawing.Point(260, 230); $btnHelp.Size = New-Object System.Drawing.Size(120, 30); $btnHelp.FlatStyle="Flat"; $btnHelp.FlatAppearance.BorderSize=1; $btnHelp.FlatAppearance.BorderColor=[System.Drawing.Color]::Gray; $btnHelp.BackColor = $BtnSettings.BackColor; $btnHelp.ForeColor = $BtnSettings.ForeColor; $SF.Controls.Add($btnHelp)
    
    $btnBR.Add_Click({ $fd = New-Object System.Windows.Forms.OpenFileDialog; $fd.Filter = "Executable (*.exe)|*.exe"; if ($fd.ShowDialog() -eq "OK") { $txtR.Text = $fd.FileName } })
    $btnBG.Add_Click({ $fb = New-Object System.Windows.Forms.FolderBrowserDialog; if ($fb.ShowDialog() -eq "OK") { $txtG.Text = $fb.SelectedPath } })
    $btnHelp.Add_Click({ [System.Diagnostics.Process]::Start("https://docs.google.com/document/d/1Hm5I8qBpaZQ3gEyMJzXjGdOEZCYV5gNFaeLhKkFZ-u8/edit?usp=sharing") | Out-Null })
    $btnSave.Add_Click({ 
        $Global:AppSettings.RclonePath = $txtR.Text
        $Global:AppSettings.GCloudPath = $txtG.Text
        $Global:AppSettings.IsDebugMode = $chkDebug.Checked
        $Global:AppSettings.TransferThreads = $cmbT.SelectedItem
        Save-Settings; Set-RcloneEnvironment; Set-GCloudEnvironment
        [System.Windows.Forms.MessageBox]::Show("Settings saved.", "Settings Saved") | Out-Null; $SF.Close() 
    })
    $SF.ShowDialog() | Out-Null
}

function Get-CloudItems([string]$Prov, [string]$Buc, [string]$Pth, [bool]$DirOnly=$false) {
    $parsed = @(); $seen = @{}
    if ($Prov -eq "GCS") {
        $fullUri = "gs://$Buc/$Pth"
        $result = Execute-Cli-Json -cmdArgs "gcloud.cmd storage ls `"$fullUri*`" --json" -isRclone $false
        if ($result) {
            foreach ($obj in $result) {
                $pathStr = if ($obj.name) { $obj.name } else { $obj.url }
                $clean = $pathStr -replace "^gs://$Buc/", ""
                if ($clean -eq $Pth) { continue }
                $relativePath = $clean; if (![string]::IsNullOrEmpty($Pth)) { $relativePath = $clean -replace "^$([regex]::Escape($Pth))", "" }
                $upd = if ($obj.metadata.updated) { $obj.metadata.updated } elseif ($obj.updated) { $obj.updated } else { $null }
                $rawDate = if ($upd) { try { [DateTime]::Parse($upd) } catch { [DateTime]::MinValue } } else { [DateTime]::MinValue }
                $dateStr = if ($upd -and $rawDate -ne [DateTime]::MinValue) { $rawDate.ToString("yyyy-MM-dd HH:mm") } else { "---" }
                
                if ($relativePath -match '/') {
                    $leaf = ($relativePath -split '/')[0] + "/"
                    if (-not $seen[$leaf]) { $seen[$leaf] = $true; $parsed += [PSCustomObject]@{ Type = 0; Name = $leaf; RawDate = $rawDate; DisplayString = ("[DIR]  {0,-30} | {1}" -f $leaf, $dateStr) } }
                } else {
                    if ($DirOnly) { continue }
                    $leaf = ($relativePath -split '#')[0] 
                    if ($leaf -eq ".placeholder") { continue }
                    if (-not $seen[$leaf]) { $seen[$leaf] = $true; $parsed += [PSCustomObject]@{ Type = 1; Name = $leaf; RawDate = $rawDate; DisplayString = ("[FILE] {0,-30} | {1}" -f $leaf, $dateStr) } }
                }
            }
        }
    } elseif ($Prov -eq "GDRIVE") {
        $target = "${Global:RemoteName}:${Pth}"
        $args = "lsjson `"$target`" --config `"$Global:TempConfig`" --tpslimit 8 --fast-list --drive-use-trash=false --drive-skip-shortcuts --drive-list-chunk=1000"
        if ($Buc) { $args += " --drive-team-drive=`"$($Global:DriveMap[$Buc])`"" }
        if ($DirOnly) { $args += " --dirs-only" }
        $result = Execute-Cli-Json -cmdArgs $args -isRclone $true
        if ($result) { 
            foreach ($item in $result) { 
                $rawDate = if ($item.ModTime) { try { [DateTime]::Parse($item.ModTime) } catch { [DateTime]::MinValue } } else { [DateTime]::MinValue }
                $dateStr = if ($item.ModTime -and $rawDate -ne [DateTime]::MinValue) { $rawDate.ToString("yyyy-MM-dd HH:mm") } else { "---" }
                if ($item.IsDir) { 
                    $leaf = "$($item.Name)/"
                    if (-not $seen[$leaf]) { $seen[$leaf] = $true; $parsed += [PSCustomObject]@{ Type = 0; Name = $leaf; RawDate = $rawDate; DisplayString = ("[DIR]  {0,-30} | {1}" -f $leaf, $dateStr) } }
                } else { 
                    $leaf = $item.Name
                    if (-not $seen[$leaf]) { $seen[$leaf] = $true; $parsed += [PSCustomObject]@{ Type = 1; Name = $leaf; RawDate = $rawDate; DisplayString = ("[FILE] {0,-30} | {1}" -f $leaf, $dateStr) } }
                }
            } 
        }
    }
    return $parsed
}

function Update-Directory([bool]$IsSrc) {
    $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    
    $Prov = if ($IsSrc) { $Global:SrcProvider } else { $Global:DstProvider }
    $Pth  = if ($IsSrc) { $Global:SrcPath } else { $Global:DstPath }
    $LocP = if ($IsSrc) { $Global:SrcLocalPath } else { $Global:DstLocalPath }
    $Buc  = if ($IsSrc) { $CmbSrcBucList.Text } else { $CmbDstBucList.Text }
    
    $Lbx  = if ($IsSrc) { $LbxSrcDir } else { $LbxDstDir }
    $LblP = if ($IsSrc) { $LblSrcPath } else { $LblDstPath }

    $Lbx.Items.Clear()
    if (![string]::IsNullOrEmpty($Pth) -or ($Prov -eq "LOCAL" -and ![string]::IsNullOrEmpty($LocP) -and $LocP.Contains("\"))) { [void]$Lbx.Items.Add(".. [Go Up] | ---") }

    $rawParsedItems = @()
    if ($Prov -eq "GCS" -or $Prov -eq "GDRIVE") {
        if ($Prov -eq "GCS" -and ([string]::IsNullOrWhiteSpace($Buc) -or $Buc -match "Select Bucket" -or $Buc -match "--- Bucket ---" -or $Buc -match "Type Bucket")) { $Form.Cursor = [System.Windows.Forms.Cursors]::Default; return }
        $LblP.Text = if ($Prov -eq "GCS") { "Path: gs://$Buc/$Pth" } else { "Path: /$Pth" }
        $rawParsedItems = Get-CloudItems $Prov $Buc $Pth $false
    } elseif ($Prov -eq "LOCAL") {
        $LblP.Text = "Path: $LocP"
        if (![string]::IsNullOrWhiteSpace($LocP) -and (Test-Path -LiteralPath $LocP)) {
            $items = Get-ChildItem -LiteralPath $LocP -Force -ErrorAction SilentlyContinue
            if ($null -ne $items) {
                foreach ($item in $items) {
                    $rawDate = $item.LastWriteTime; $dateStr = $rawDate.ToString("yyyy-MM-dd HH:mm")
                    if ($item.PSIsContainer) {
                        $leaf = "$($item.Name)/"
                        $rawParsedItems += [PSCustomObject]@{ Type = 0; Name = $leaf; RawDate = $rawDate; DisplayString = ("[DIR]  {0,-30} | {1}" -f $leaf, $dateStr) }
                    } else {
                        $rawParsedItems += [PSCustomObject]@{ Type = 1; Name = $item.Name; RawDate = $rawDate; DisplayString = ("[FILE] {0,-30} | {1}" -f $item.Name, $dateStr) }
                    }
                }
            }
        }
    }

    $parsedItems = @()
    foreach ($pItem in $rawParsedItems) {
        $rawName = $pItem.Name -replace '/$', ''
        if (-not ($IsSrc -and (Is-Filtered $rawName))) {
            $parsedItems += $pItem
        }
    }

    if ($parsedItems.Count -gt 0) {
        $srt = if ($IsSrc) { $CmbSrcSort.SelectedItem } else { $CmbSort.SelectedItem }
        switch ($srt) {
            "Name (A-Z)" { $parsedItems = $parsedItems | Sort-Object Type, Name }
            "Name (Z-A)" { $parsedItems = $parsedItems | Sort-Object Type, @{Expression='Name'; Descending=$true} }
            "Date (New)" { $parsedItems = $parsedItems | Sort-Object Type, @{Expression='RawDate'; Descending=$true} }
            "Date (Old)" { $parsedItems = $parsedItems | Sort-Object Type, RawDate }
            default { $parsedItems = $parsedItems | Sort-Object Type, Name }
        }
        foreach ($pItem in $parsedItems) { [void]$Lbx.Items.Add($pItem.DisplayString) }
    }
    
    if ($IsSrc) {
        $ChkExclusions.Items.Clear()
        if ($Prov -eq "LOCAL") {
            if (Test-Path $LocP) { 
                $subs = Get-ChildItem $LocP -Force -ErrorAction SilentlyContinue 
                foreach($d in $subs){ 
                    if (-not (Is-Filtered $d.Name)) {
                        $prefix = if ($d.PSIsContainer) { "[DIR]  " } else { "[FILE] " }
                        [void]$ChkExclusions.Items.Add("$prefix$($d.Name)", $true) 
                    }
                } 
            }
        } else {
            $subCloud = Get-CloudItems $Prov $Buc $Pth $false
            foreach($d in $subCloud){ 
                $rawName = $d.Name -replace '/$', ''
                if (-not (Is-Filtered $rawName)) {
                    $prefix = if ($d.Type -eq 0) { "[DIR]  " } else { "[FILE] " }
                    [void]$ChkExclusions.Items.Add("$prefix$rawName", $true) 
                }
            }
        }
    }
    
    if ($Global:SrcProvider -ne "" -and $Global:DstProvider -ne "") { 
        if (-not $Global:LoadingHistory) { $BtnUpload.Enabled = $true } 
    }
    $Form.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Sync-TasksToUI {
    $LvwTasks.Items.Clear()
    foreach ($t in $Global:Tasks) {
        $tName = if ($t.Name) { $t.Name } else { "Unnamed Task" }
        $tStatus = if ($t.Status) { $t.Status } else { "Unknown" }
        $tStart = if ($t.StartDate) { $t.StartDate } else { "---" }
        $tComplete = if ($t.CompleteDate) { $t.CompleteDate } else { "---" }
        
        $item = New-Object System.Windows.Forms.ListViewItem($tName); $item.Tag = $t.Id
        [void]$item.SubItems.Add($tStatus); [void]$item.SubItems.Add($tStart); [void]$item.SubItems.Add($tComplete)
        
        if ($tStatus -eq "Active" -or $tStatus -eq "Resuming") { $item.ForeColor = if ($Global:AppSettings.IsDarkMode) { [System.Drawing.Color]::Cyan } else { [System.Drawing.Color]::Blue } }
        elseif ($tStatus -eq "Completed") { $item.ForeColor = if ($Global:AppSettings.IsDarkMode) { [System.Drawing.Color]::LightGreen } else { [System.Drawing.Color]::Green } }
        elseif ($tStatus -eq "Error") { $item.ForeColor = if ($Global:AppSettings.IsDarkMode) { [System.Drawing.Color]::LightCoral } else { [System.Drawing.Color]::Red } }
        elseif ($tStatus -eq "Aborted") { $item.ForeColor = if ($Global:AppSettings.IsDarkMode) { [System.Drawing.Color]::Orange } else { [System.Drawing.Color]::DarkOrange } }
        [void]$LvwTasks.Items.Add($item)
    }
}

function Load-TaskToUI($taskId, [bool]$IsReadOnly) {
    $t = $Global:Tasks | Where-Object { $_.Id -eq $taskId } | Select-Object -First 1
    if (!$t) { return }
    
    $Global:LoadingHistory = $true 
    $Global:CurrentTaskId = $t.Id; $TxtTaskName.Text = $t.Name
    
    if ($t.CustomFilters) { $Global:CustomFilters = $t.CustomFilters -split "\|" } else { $Global:CustomFilters = $Global:DefaultFilters }
    
    $CmbSrcProvider.SelectedIndex = $t.SrcProvIdx; $Global:SrcProvider = $t.SrcProvider; $Global:SrcPath = $t.SrcPath; $Global:SrcLocalPath = $t.SrcLocal
    if ($t.SrcProvider -eq "GCS") { 
        if($t.SrcProj){
            if (-not $CmbSrcProjList.Items.Contains($t.SrcProj)) { [void]$CmbSrcProjList.Items.Add($t.SrcProj) } 
            $CmbSrcProjList.SelectedItem=$t.SrcProj
        }
        if($t.SrcBuc){
            if ($t.SrcProj -eq "[ No Project ID (Manual) ]") {
                $CmbSrcBucList.Text = $t.SrcBuc
            } else {
                if (-not $CmbSrcBucList.Items.Contains($t.SrcBuc)) { [void]$CmbSrcBucList.Items.Add($t.SrcBuc) } 
                $CmbSrcBucList.SelectedItem=$t.SrcBuc
            }
        } 
    } elseif ($t.SrcProvider -eq "GDRIVE") { 
        $CmbSrcProjList.SelectedIndex = $t.SrcDriveType
        if($t.SrcBuc){
            if (-not $CmbSrcBucList.Items.Contains($t.SrcBuc)) { [void]$CmbSrcBucList.Items.Add($t.SrcBuc) } 
            $CmbSrcBucList.SelectedItem=$t.SrcBuc
        } 
    }
    
    $CmbDstProvider.SelectedIndex = $t.DstProvIdx; $Global:DstProvider = $t.DstProvider; $Global:DstPath = $t.DstPath; $Global:DstLocalPath = $t.DstLocal
    if ($t.DstProvider -eq "GCS") { 
        if($t.DstProj){
            if (-not $CmbDstProjList.Items.Contains($t.DstProj)) { [void]$CmbDstProjList.Items.Add($t.DstProj) } 
            $CmbDstProjList.SelectedItem=$t.DstProj
        }
        if($t.DstBuc){
            if ($t.DstProj -eq "[ No Project ID (Manual) ]") {
                $CmbDstBucList.Text = $t.DstBuc
            } else {
                if (-not $CmbDstBucList.Items.Contains($t.DstBuc)) { [void]$CmbDstBucList.Items.Add($t.DstBuc) } 
                $CmbDstBucList.SelectedItem=$t.DstBuc
            }
        } 
    } elseif ($t.DstProvider -eq "GDRIVE") { 
        $CmbDstProjList.SelectedIndex = $t.DstDriveType
        if($t.DstBuc){
            if (-not $CmbDstBucList.Items.Contains($t.DstBuc)) { [void]$CmbDstBucList.Items.Add($t.DstBuc) } 
            $CmbDstBucList.SelectedItem=$t.DstBuc
        } 
    }
    
    $RtbLog.Text = if ($t.LogData) { $t.LogData } else { "" }
    
    $ShouldLoadStorages = (-not $IsReadOnly -and $t.Status -ne "Completed")

    if ($ShouldLoadStorages) {
        Update-Directory $true; Update-Directory $false
        
        $savedExclusions = if ($t.Exclusions) { $t.Exclusions -split "\|" } else { @() }
        for ($i = 0; $i -lt $ChkExclusions.Items.Count; $i++) { 
            $rawItem = $ChkExclusions.Items[$i] -replace '^\[DIR\]\s+|^\[FILE\]\s+', ''
            if ($savedExclusions -contains $rawItem) { $ChkExclusions.SetItemChecked($i, $false) } 
        }

        if ($Global:SrcProvider -ne "" -and $Global:DstProvider -ne "") { $BtnUpload.Enabled = $true }
        $BtnDstRef.Enabled = $true
        $BtnDstNewF.Enabled = $true
        Log-Message "`r`n*** Task loaded in RESUME/EDIT mode. Storages connected and ready to start. ***" "Cyan"
    } else {
        $LbxSrcDir.Items.Clear()
        $LbxDstDir.Items.Clear()
        $ChkExclusions.Items.Clear()
        [void]$LbxSrcDir.Items.Add("--- Storage not loaded (Read-Only Mode) ---")
        [void]$LbxDstDir.Items.Add("--- Storage not loaded (Read-Only Mode) ---")
        
        $BtnUpload.Enabled = $false
        $BtnDstRef.Enabled = $false
        $BtnDstNewF.Enabled = $false

        if ($t.Status -ne "Completed" -and $IsReadOnly) {
            Log-Message "`r`n*** NOTE: Double-click on this Task in the history list to resume transfer and load storages. ***" "Yellow"
        }
    }
    
    $Global:LoadingHistory = $false 
}

function Update-TaskStatus($taskId, $status) {
    $t = $Global:Tasks | Where-Object { $_.Id -eq $taskId }
    if ($t) { $t.Status = $status; $t.LogData = $RtbLog.Text; Save-Tasks; Sync-TasksToUI }
}

# --- 4. EVENT HANDLERS ---
$Form.Add_Shown({ 
    Load-Tasks; Sync-TasksToUI; 
    $PThird = [math]::Floor($SplitRightOuter.Height / 2); $SplitRightOuter.SplitterDistance = $PThird; 
    $SplitBrowsers.SplitterDistance = [math]::Floor($SplitBrowsers.Width / 2)
    # UI TWEAK: Set Source Splitter to precisely 50/50 balance by default upon startup
    if ($Global:SplitSrc) { $Global:SplitSrc.SplitterDistance = [math]::Floor($Global:SplitSrc.Height / 2) }
})
$BtnSettings.Add_Click({ Show-SettingsDialog })
$BtnDarkMode.Add_Click({ $Global:AppSettings.IsDarkMode = -not $Global:AppSettings.IsDarkMode; Save-Settings; Update-Theme; Sync-TasksToUI })
$BtnClearAll.Add_Click({ if ([System.Windows.Forms.MessageBox]::Show("Delete all?", "Confirm", "YesNo") -eq "Yes") { $Global:Tasks = @(); Save-Tasks; Sync-TasksToUI; $BtnNewTask.PerformClick() } })
$BtnDelTask.Add_Click({ if ($LvwTasks.SelectedItems.Count -gt 0) { $id = $LvwTasks.SelectedItems[0].Tag; $Global:Tasks = @($Global:Tasks | Where-Object { $_.Id -ne $id }); Save-Tasks; Sync-TasksToUI; $BtnNewTask.PerformClick() } })

$LvwTasks.Add_ColumnClick({
    param($sender, $e)
    $col = $e.Column
    if ($Global:SortCol -eq $col) { $Global:SortAsc = -not $Global:SortAsc } else { $Global:SortCol = $col; $Global:SortAsc = $true }
    
    if ($col -eq 0) { $prop = "Name" } elseif ($col -eq 1) { $prop = "Status" } elseif ($col -eq 2) { $prop = "StartDate" } elseif ($col -eq 3) { $prop = "CompleteDate" }

    if ($prop -match "Date") {
        $Global:Tasks = $Global:Tasks | Sort-Object -Property @{
            Expression = { if ([string]::IsNullOrWhiteSpace($_.$prop) -or $_.$prop -eq "---") { [DateTime]::MinValue } else { [DateTime]::ParseExact($_.$prop, "MM/dd/yyyy HH:mm", $null) } }
            Descending = (-not $Global:SortAsc)
        }
    } else {
        $Global:Tasks = $Global:Tasks | Sort-Object -Property @{ Expression = { $_.$prop }; Descending = (-not $Global:SortAsc) }
    }
    Sync-TasksToUI
})

$LvwTasks.Add_SelectedIndexChanged({ 
    if ($Global:IsTransferring) { return }
    if ($LvwTasks.SelectedItems.Count -gt 0) { 
        Load-TaskToUI $LvwTasks.SelectedItems[0].Tag $true 
    } 
})

$LvwTasks.Add_DoubleClick({ 
    if ($Global:IsTransferring) { return }
    if ($LvwTasks.SelectedItems.Count -gt 0) { 
        Load-TaskToUI $LvwTasks.SelectedItems[0].Tag $false 
    } 
})

$CmbSrcSort.Add_SelectedIndexChanged({ if ($LbxSrcDir.Enabled -and -not $Global:IsTransferring) { Update-Directory $true } })
$CmbSort.Add_SelectedIndexChanged({ if ($LbxDstDir.Enabled -and -not $Global:IsTransferring) { Update-Directory $false } })

$ChkExclusions.Add_ItemCheck({
    param($sender, $e)
    if ($Global:IsTransferring) { $e.NewValue = $e.CurrentValue }
})

$BtnCheckAll.Add_Click({ for ($i=0; $i -lt $ChkExclusions.Items.Count; $i++) { $ChkExclusions.SetItemChecked($i, $true) } })
$BtnUncheckAll.Add_Click({ for ($i=0; $i -lt $ChkExclusions.Items.Count; $i++) { $ChkExclusions.SetItemChecked($i, $false) } })
$BtnDstRef.Add_Click({ Update-Directory $false })

$BtnNewTask.Add_Click({
    $Global:CurrentTaskId = $null; $TxtTaskName.Clear(); $ChkExclusions.Items.Clear(); $RtbLog.Clear(); $LvwTasks.SelectedItems.Clear(); $PrgTotal.Value = 0; $LblProgress.Text = "Overall Progress (0%):"; $LblFolderCount.Text = "Item(s): 0 out of 0"
    $Global:CustomFilters = $Global:AppSettings.CustomFilters
    
    if ($CmbSrcProvider.Items.Count -gt 0) { $CmbSrcProvider.SelectedIndex = 0 }
    if ($CmbDstProvider.Items.Count -gt 0) { $CmbDstProvider.SelectedIndex = 0 }
    
    $Global:SrcPath = ""; $Global:DstPath = ""; $Global:SrcLocalPath = ""; $Global:DstLocalPath = ""; $Global:SrcIsFile = $false
})

$BtnDuplicate.Add_Click({
    if ($Global:CurrentTaskId) {
        $oldId = $Global:CurrentTaskId
        Load-TaskToUI $oldId $false
        
        $Global:CurrentTaskId = $null
        $TxtTaskName.Text = "$($TxtTaskName.Text) (Copy)"
        $RtbLog.Clear()
        $PrgTotal.Value = 0
        $LblProgress.Text = "Overall Progress (0%):"
        $LvwTasks.SelectedItems.Clear()
        Log-Message "`r`n*** Task duplicated and ready to start. ***" "Cyan"
    }
})

$BtnOpenLog.Add_Click({
    $foundPath = $null
    
    if ($RtbLog.Text -match 'Summary File Saved:\s*([A-Za-z]:\\[^\r\n]+)') {
        $foundPath = $Matches[1].Trim()
    } elseif ($Global:CurrentTaskId) {
        $t = $Global:Tasks | Where-Object { $_.Id -eq $Global:CurrentTaskId } | Select-Object -First 1
        if ($t.LogFilePath) { $foundPath = $t.LogFilePath }
    }

    if ($foundPath -and (Test-Path -LiteralPath $foundPath)) {
        [System.Diagnostics.Process]::Start("notepad.exe", "`"$foundPath`"") | Out-Null
    } elseif ($Global:CurrentProcess -and -not $Global:CurrentProcess.HasExited -and $Global:RunLogFile -and (Test-Path -LiteralPath $Global:RunLogFile)) {
        [System.Diagnostics.Process]::Start("notepad.exe", "`"$Global:RunLogFile`"") | Out-Null
    } elseif (![string]::IsNullOrWhiteSpace($RtbLog.Text)) {
        $tmp = [System.IO.Path]::GetFullPath((Join-Path $env:TEMP "display_log_$([guid]::NewGuid().ToString('N')).txt"))
        $RtbLog.Text | Out-File -LiteralPath $tmp -Encoding utf8
        [System.Diagnostics.Process]::Start("notepad.exe", "`"$tmp`"") | Out-Null
    } else {
        [System.Windows.Forms.MessageBox]::Show("No log data available to open.", "Log Empty") | Out-Null
    }
})

function Handle-AuthClick([bool]$IsSrc) {
    $Prov = if($IsSrc){$Global:SrcProvider}else{$Global:DstProvider}
    $ProvCmb = if($IsSrc){$CmbSrcProvider}else{$CmbDstProvider}
    if ($Prov -eq "GCS") {
        if ((Start-Process gcloud.cmd -ArgumentList "auth login" -Wait -PassThru).ExitCode -eq 0) { 
            Start-Process gcloud.cmd -ArgumentList "auth application-default login" -Wait -NoNewWindow
            $ProvCmb.SelectedIndex = 0; $ProvCmb.SelectedIndex = 1 
        }
    } else {
        $authArgs = "config create $Global:RemoteName drive scope=drive team_drive=`"`" --config `"$Global:TempConfig`""
        if ((Start-Process $Global:RcloneExe -ArgumentList $authArgs -Wait -NoNewWindow -PassThru).ExitCode -eq 0) { $ProvCmb.SelectedIndex = 0; $ProvCmb.SelectedIndex = 2 }
    }
}
$BtnSrcAuth.Add_Click({ Handle-AuthClick $true })
$BtnDstAuth.Add_Click({ Handle-AuthClick $false })

function Handle-ProviderChange([bool]$IsSrc) {
    $ProvCmb = if($IsSrc){$CmbSrcProvider}else{$CmbDstProvider}; $ProvList = @("", "GCS", "GDRIVE", "LOCAL"); $Prov = $ProvList[$ProvCmb.SelectedIndex]
    if($IsSrc){$Global:SrcProvider=$Prov; $Global:SrcPath=""; $Global:SrcIsFile=$false}else{$Global:DstProvider=$Prov; $Global:DstPath=""}
    
    $BtnAuth = if($IsSrc){$BtnSrcAuth}else{$BtnDstAuth}; $LblStat = if($IsSrc){$LblSrcAuthStatus}else{$LblDstAuthStatus}
    $CmbProj = if($IsSrc){$CmbSrcProjList}else{$CmbDstProjList}; $CmbBuc = if($IsSrc){$CmbSrcBucList}else{$CmbDstBucList}
    $BtnLoc = if($IsSrc){$BtnSrcLoc}else{$BtnDstLoc}; $Lbx = if($IsSrc){$LbxSrcDir}else{$LbxDstDir}
    
    $Lbx.Items.Clear(); $Lbx.Enabled = $false; $BtnUpload.Enabled = $false
    $CmbProj.Visible=($Prov -eq "GCS" -or $Prov -eq "GDRIVE"); 
    
    $CmbBuc.Visible=($Prov -eq "GCS") 
    $BtnLoc.Visible=($Prov -eq "LOCAL")
    
    if ($IsSrc) { 
        $BtnSrcFilter.Visible = ($Prov -eq "LOCAL") 
    }

    if ($Prov -eq "GCS") { 
        $CmbProj.Items.Clear(); [void]$CmbProj.Items.Add("Project"); $CmbProj.SelectedIndex=0; $CmbProj.Enabled=$false 
    } elseif ($Prov -eq "GDRIVE") { 
        $CmbProj.Items.Clear(); [void]$CmbProj.Items.AddRange(@("My Drive", "Shared Drive")); $CmbProj.SelectedIndex=0; $CmbProj.Enabled=$true 
    }

    if ($Prov -eq "") { 
        $LblStat.Text = "Not Connected"; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightCoral" } else { "Red" }; $BtnAuth.Enabled = $false; 
        return 
    } 

    if ($Global:LoadingHistory) {
        if ($Prov -eq "GCS") { $LblStat.Text = "Auth (GCS)"; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightGreen" } else { "Green" } }
        elseif ($Prov -eq "GDRIVE") { $LblStat.Text = "Auth (GDrive)"; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightGreen" } else { "Green" } }
        elseif ($Prov -eq "LOCAL") { $LblStat.Text = "Local Active"; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightGreen" } else { "Green" } }
        $Lbx.Enabled = $true
        return
    }

    if ($Prov -eq "LOCAL") {
        $BtnAuth.Enabled = $false; $LblStat.Text = "Local Active"; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightGreen" } else { "Green" }
        $Lbx.Enabled = $true; 
        if (-not $IsSrc -and -not $Global:LoadingHistory) { $BtnDstNewF.Enabled = $true; $BtnDstRef.Enabled = $true } 
        if (($IsSrc -and $Global:SrcLocalPath) -or (!$IsSrc -and $Global:DstLocalPath)) { Update-Directory $IsSrc }
    } else {
        $BtnAuth.Enabled = $false; $LblStat.Text = "Checking..."; $LblStat.ForeColor = "Orange"
        if ($Prov -eq "GCS") {
            $data = Execute-Cli-Json -cmdArgs "gcloud.cmd projects list --format='json'"
            
            if ($data) { 
                $LblStat.Text = "Auth (GCS)"; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightGreen" } else { "Green" }
                $CmbProj.Items.Clear(); [void]$CmbProj.Items.Add("--- Project ---"); [void]$CmbProj.Items.Add("[ No Project ID (Manual) ]")
                $data | Select-Object -ExpandProperty projectId -ErrorAction SilentlyContinue | ForEach-Object { [void]$CmbProj.Items.Add($_) }
                $CmbProj.Enabled = $true; $CmbProj.SelectedIndex = 0 
                if (-not $IsSrc -and -not $Global:LoadingHistory) { $BtnDstRef.Enabled = $true } 
            } else { 
                $LblStat.Text = "Auth (Manual)"; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightGreen" } else { "Green" }
                $CmbProj.Items.Clear(); [void]$CmbProj.Items.Add("[ No Project ID (Manual) ]")
                $CmbProj.Enabled = $true; $CmbProj.SelectedIndex = 0 
            }
        } elseif ($Prov -eq "GDRIVE") {
            $d = Execute-Cli-Json -cmdArgs "about `"${Global:RemoteName}:`" --config `"$Global:TempConfig`" --json" -isRclone $true
            if ($d) { 
                $LblStat.Text = "Auth (GDrive)"; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightGreen" } else { "Green" }; 
                $Lbx.Enabled = $true; 
                if (-not $IsSrc -and -not $Global:LoadingHistory) { $BtnDstNewF.Enabled = $true; $BtnDstRef.Enabled = $true } 
                Update-Directory $IsSrc 
            } else { $LblStat.Text = "Not Connected"; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightCoral" } else { "Red" }; $BtnAuth.Enabled = $true }
        }
    }
}
$CmbSrcProvider.Add_SelectedIndexChanged({ Handle-ProviderChange $true })
$CmbDstProvider.Add_SelectedIndexChanged({ Handle-ProviderChange $false })

function Handle-ProjChange([bool]$IsSrc) {
    if ($Global:LoadingHistory) { return }
    $Prov = if($IsSrc){$Global:SrcProvider}else{$Global:DstProvider}
    $CmbProj = if($IsSrc){$CmbSrcProjList}else{$CmbDstProjList}; $CmbBuc = if($IsSrc){$CmbSrcBucList}else{$CmbDstBucList}
    
    if($Prov -eq "GCS") {
        if ($CmbProj.SelectedItem -eq "[ No Project ID (Manual) ]") {
            $CmbBuc.DropDownStyle = "DropDown"
            $CmbBuc.Items.Clear()
            $CmbBuc.Text = "Type Bucket & Press Enter..."
            $CmbBuc.Enabled = $true
            $CmbBuc.Visible = $true
        } elseif ($CmbProj.SelectedIndex -gt 0) {
            $CmbBuc.DropDownStyle = "DropDownList"
            $buckets = Execute-Cli-Json -cmdArgs "gcloud.cmd storage buckets list --project=`"$($CmbProj.SelectedItem)`" --format='json'"
            $CmbBuc.Items.Clear(); [void]$CmbBuc.Items.Add("--- Bucket ---")
            $buckets | Select-Object -ExpandProperty name -ErrorAction SilentlyContinue | ForEach-Object{ [void]$CmbBuc.Items.Add($_) }
            $CmbBuc.Enabled = $true; $CmbBuc.SelectedIndex = 0
            $CmbBuc.Visible = $true
        }
    } elseif ($Prov -eq "GDRIVE") {
        $CmbBuc.DropDownStyle = "DropDownList"
        if($IsSrc){$Global:SrcPath=""}else{$Global:DstPath=""}
        if($CmbProj.SelectedItem -eq "Shared Drive"){
            $d = Execute-Cli-Json -cmdArgs "backend drives `"${Global:RemoteName}:`" --config `"$Global:TempConfig`"" -isRclone $true; $CmbBuc.Items.Clear()
            if ($d) { foreach($i in $d){ [void]$CmbBuc.Items.Add($i.name); $Global:DriveMap[$i.name]=$i.id }; $CmbBuc.Enabled = $true; $CmbBuc.Visible = $true; if($CmbBuc.Items.Count -gt 0){ $CmbBuc.SelectedIndex = 0 } }
        } else { $CmbBuc.Enabled = $false; $CmbBuc.Visible = $false; Update-Directory $IsSrc }
    }
}
$CmbSrcProjList.Add_SelectedIndexChanged({ Handle-ProjChange $true }); $CmbDstProjList.Add_SelectedIndexChanged({ Handle-ProjChange $false })
$CmbSrcBucList.Add_SelectedIndexChanged({ if($Global:LoadingHistory){return}; if($CmbSrcBucList.SelectedIndex -gt 0 -or $CmbSrcBucList.Items.Count -eq 0){ $LbxSrcDir.Enabled=$true; $Global:SrcPath=""; Update-Directory $true } })
$CmbDstBucList.Add_SelectedIndexChanged({ 
    if($Global:LoadingHistory){return}; 
    if($CmbDstBucList.SelectedIndex -gt 0 -or $CmbDstBucList.Items.Count -eq 0){ 
        $LbxDstDir.Enabled=$true; $BtnDstNewF.Enabled=$true; 
        $BtnDstRef.Enabled=$true; 
        $Global:DstPath=""; Update-Directory $false 
    } 
})

function Handle-LbxDClick([bool]$IsSrc) {
    if ($Global:IsTransferring) { return }
    $Lbx = if($IsSrc){$LbxSrcDir}else{$LbxDstDir}; $sel = $Lbx.SelectedItem; if (!$sel) { return }
    $Prov = if($IsSrc){$Global:SrcProvider}else{$Global:DstProvider}
    $LocP = if($IsSrc){$Global:SrcLocalPath}else{$Global:DstLocalPath}
    $CPath = if($IsSrc){$Global:SrcPath}else{$Global:DstPath}

    if ($sel -match "^\.\.\s\[Go\sUp\]") {
        if ($Prov -eq "LOCAL") { 
            $parent = Split-Path $LocP
            if (-not [string]::IsNullOrEmpty($parent)) { $LocP = $parent } 
        } else { 
            $parts = $CPath.TrimEnd('/') -split '/'
            $CPath = if ($parts.Count -le 1) {""} else {($parts[0..($parts.Count-2)] -join '/') + "/"} 
        }
        if ($IsSrc -and $Global:SrcIsFile) { $Global:SrcIsFile = $false }
    } elseif ($sel -match '^\[DIR\]\s+(.*?)\s+\|') { 
        if ($Prov -eq "LOCAL") { $LocP = Join-Path $LocP $Matches[1].Trim().TrimEnd('/') } else { $CPath += $Matches[1].Trim() }
    } elseif ($sel -match '^\[FILE\]\s+(.*?)\s+\|') {
        if ($IsSrc) { $Global:SrcIsFile = $true; if ($Prov -eq "LOCAL") { $LocP = Join-Path $LocP $Matches[1].Trim() } else { $CPath += $Matches[1].Trim() } } else { return }
    } else { return }
    
    if($IsSrc){$Global:SrcLocalPath=$LocP; $Global:SrcPath=$CPath}else{$Global:DstLocalPath=$LocP; $Global:DstPath=$CPath}
    Update-Directory $IsSrc
}
$LbxSrcDir.Add_DoubleClick({ Handle-LbxDClick $true }); $LbxDstDir.Add_DoubleClick({ Handle-LbxDClick $false })

$BtnSrcLoc.Add_Click({ $diag = New-Object System.Windows.Forms.FolderBrowserDialog; if ($diag.ShowDialog() -eq "OK") { $Global:SrcLocalPath = $diag.SelectedPath; $Global:SrcIsFile = $false; Update-Directory $true } })
$BtnDstLoc.Add_Click({ $diag = New-Object System.Windows.Forms.FolderBrowserDialog; if ($diag.ShowDialog() -eq "OK") { $Global:DstLocalPath = $diag.SelectedPath; Update-Directory $false } })

$BtnDstNewF.Add_Click({
    $fName = [Microsoft.VisualBasic.Interaction]::InputBox("Enter new folder name:", "Create Folder", ""); if ([string]::IsNullOrWhiteSpace($fName)) { return }; $fName = $fName.Trim('/') 
    $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    if ($Global:DstProvider -eq "LOCAL" -and $Global:DstLocalPath) { New-Item -ItemType Directory -Path (Join-Path $Global:DstLocalPath $fName) | Out-Null }
    elseif ($Global:DstProvider -eq "GCS") {
        $tempPh = Join-Path $Global:AppDir ".placeholder"; if (-not (Test-Path $tempPh)) { $null | Out-File -FilePath $tempPh -Encoding utf8 }
        $destUri = if ($Global:DstPath) { "gs://$($CmbDstBucList.Text)/$($Global:DstPath.Trim('/'))/$fName/.placeholder" } else { "gs://$($CmbDstBucList.Text)/$fName/.placeholder" }
        [System.Diagnostics.Process]::Start((New-Object System.Diagnostics.ProcessStartInfo -Property @{FileName="gcloud.cmd"; Arguments="storage cp `"$tempPh`" `"$destUri`""; WorkingDirectory=$Global:GCloudBin; WindowStyle="Hidden"; CreateNoWindow=$true})).WaitForExit()
    } elseif ($Global:DstProvider -eq "GDRIVE") {
        $args = "mkdir `"${Global:RemoteName}:${Global:DstPath}$fName`" --config `"$Global:TempConfig`""; if ($CmbDstProjList.SelectedItem -eq "Shared Drive") { $args += " --drive-team-drive=$($Global:DriveMap[$CmbDstBucList.Text])" }
        [System.Diagnostics.Process]::Start((New-Object System.Diagnostics.ProcessStartInfo -Property @{FileName=$Global:RcloneExe; Arguments=$args; WindowStyle="Hidden"; CreateNoWindow=$true})).WaitForExit()
    }
    $Form.Cursor = [System.Windows.Forms.Cursors]::Default; Update-Directory $false
})

# --- 5. ENGINE REWRITE (UNIFIED TARGETED ITERATION) ---

$BtnUpload.Add_Click({
    if ($Global:SrcProvider -eq "LOCAL" -and !$Global:SrcLocalPath) { Log-Message "Source Local path not selected." "LightCoral"; return }
    if ($Global:DstProvider -eq "LOCAL" -and !$Global:DstLocalPath) { Log-Message "Target Local path not selected." "LightCoral"; return }
    
    if ($Global:SrcProvider -eq "GCS" -and ([string]::IsNullOrWhiteSpace($CmbSrcBucList.Text) -or $CmbSrcBucList.Text -match "--- Bucket ---" -or $CmbSrcBucList.Text -match "Type Bucket")) { Log-Message "Source Bucket not selected." "LightCoral"; return }
    if ($Global:DstProvider -eq "GCS" -and ([string]::IsNullOrWhiteSpace($CmbDstBucList.Text) -or $CmbDstBucList.Text -match "--- Bucket ---" -or $CmbDstBucList.Text -match "Type Bucket")) { Log-Message "Target Bucket not selected." "LightCoral"; return }

    if ([string]::IsNullOrWhiteSpace($TxtTaskName.Text)) { $TxtTaskName.Text = "Transfer $(Get-Date -Format 'MM-dd HH:mm')" }
    
    $startTimeSafe = Get-Date -Format "yyyyMMdd_HHmm"
    $taskId = if ($Global:CurrentTaskId) { $Global:CurrentTaskId } else { [Guid]::NewGuid().ToString() }
    $existing = $Global:Tasks | Where-Object { $_.Id -eq $taskId } | Select-Object -First 1
    $startStatus = if ($existing -and ($existing.Status -eq "Error" -or $existing.Status -eq "Aborted")) { "Resuming" } else { "Active" }
    
    $excList = @(); $incItems = @()
    for ($i = 0; $i -lt $ChkExclusions.Items.Count; $i++) { 
        $rawItem = $ChkExclusions.Items[$i] -replace '^\[DIR\]\s+|^\[FILE\]\s+', ''
        $isDir = $ChkExclusions.Items[$i].StartsWith("[DIR]")
        if (-not $ChkExclusions.GetItemChecked($i)) { 
            $excList += $rawItem 
        } else { 
            $incItems += [PSCustomObject]@{ Name = $rawItem; IsDir = $isDir } 
        }
    }
    $totCount = $ChkExclusions.Items.Count
    $selCount = $incItems.Count

    $newTask = [PSCustomObject]@{ 
        Id = $taskId; Status = $startStatus; Name = $TxtTaskName.Text; Exclusions = ($excList -join "|")
        SrcProvIdx = $CmbSrcProvider.SelectedIndex; SrcProvider = $Global:SrcProvider; SrcPath = $Global:SrcPath; SrcLocal = $Global:SrcLocalPath; SrcIsFile = $Global:SrcIsFile
        SrcProj = if($CmbSrcProjList.Visible){$CmbSrcProjList.SelectedItem}else{""}; SrcBuc = if($CmbSrcBucList.Visible){$CmbSrcBucList.Text}else{""}; SrcDriveType = $CmbSrcProjList.SelectedIndex
        DstProvIdx = $CmbDstProvider.SelectedIndex; DstProvider = $Global:DstProvider; DstPath = $Global:DstPath; DstLocal = $Global:DstLocalPath
        DstProj = if($CmbDstProjList.Visible){$CmbDstProjList.SelectedItem}else{""}; DstBuc = if($CmbDstBucList.Visible){$CmbDstBucList.Text}else{""}; DstDriveType = $CmbDstProjList.SelectedIndex
        LogData = ""; StartDate = (Get-Date -Format "MM/dd/yyyy HH:mm"); CompleteDate = ""; LogFilePath = ""; CustomFilters = ($Global:CustomFilters -join "|")                                  
    }
    
    if ($existing) { 
        for ($i = 0; $i -lt $Global:Tasks.Count; $i++) { 
            if ($Global:Tasks[$i].Id -eq $taskId) { 
                if ($Global:Tasks[$i].LogFilePath) { $newTask.LogFilePath = $Global:Tasks[$i].LogFilePath }
                $Global:Tasks[$i] = $newTask; break 
            } 
        } 
    } else { 
        $Global:Tasks += $newTask
        $Global:CurrentTaskId = $taskId 
    }
    Save-Tasks; Sync-TasksToUI

    $Global:IsTransferring = $true
    
    $FreezeColor = if ($Global:AppSettings.IsDarkMode) { [System.Drawing.Color]::FromArgb(255, 60, 60, 60) } else { [System.Drawing.Color]::FromArgb(255, 230, 230, 230) }
    $LvwTasks.BackColor = $FreezeColor
    $ChkExclusions.BackColor = $FreezeColor
    $LbxSrcDir.BackColor = $FreezeColor
    $LbxDstDir.BackColor = $FreezeColor
    
    $BtnNewTask.Enabled = $false; $BtnDelTask.Enabled = $false; $BtnClearAll.Enabled = $false; $BtnDuplicate.Enabled = $false
    $BtnSrcLoc.Enabled = $false; $BtnSrcFilter.Enabled = $false; $BtnDstLoc.Enabled = $false; $BtnDstNewF.Enabled = $false; $BtnDstRef.Enabled = $false
    $BtnUpload.Enabled = $false; $BtnCheckAll.Enabled = $false; $BtnUncheckAll.Enabled = $false
    
    $RtbLog.Enabled = $true; $BtnStop.Enabled = $true; $Global:StopTransfer = $false; $RtbLog.Clear()

    $ReportLog = New-Object System.Collections.ArrayList; [void]$ReportLog.Add("--- TRANSFER STARTED ---"); Log-Message "--- TRANSFER STARTED ---" "Cyan"

    $UseGCloud = (($Global:SrcProvider -eq "LOCAL" -and $Global:DstProvider -eq "GCS") -or 
                  ($Global:SrcProvider -eq "GCS" -and $Global:DstProvider -eq "LOCAL") -or 
                  ($Global:SrcProvider -eq "GCS" -and $Global:DstProvider -eq "GCS"))

    if (($Global:SrcProvider -eq "GCS" -or $Global:DstProvider -eq "GCS") -and -not $UseGCloud) {
        $adcPath = Join-Path $env:APPDATA "gcloud\application_default_credentials.json"
        if (-not (Test-Path $adcPath)) {
            Log-Message "Missing Application Default Credentials for cross-Cloud connection. Requesting..." "Yellow"
            
            $p = Start-Process gcloud.cmd -ArgumentList "auth application-default login" -Wait -PassThru
            if ($p.ExitCode -ne 0 -or -not (Test-Path $adcPath)) {
                Log-Message "Failed to acquire ADC credentials. Rclone requires this to bridge to GCS. Transfer aborted." "LightCoral"
                $Global:StopTransfer = $true
            }
        }
        if (Test-Path $adcPath) { $env:GOOGLE_APPLICATION_CREDENTIALS = $adcPath }
    }

    if ($Global:StopTransfer -eq $false) {
        
        $singleCheckedItem = ""
        if ($selCount -eq 1 -and $totCount -gt 0) {
            $singleCheckedItem = $incItems[0].Name
        }
        
        $srcName = if ($Global:SrcIsFile) { Split-Path $Global:SrcLocalPath -Leaf } elseif ($singleCheckedItem -ne "") { $singleCheckedItem } elseif ($selCount -gt 1) { "Multiple Items ($selCount)" } elseif ($Global:SrcPath) { ($Global:SrcPath.TrimEnd('/') -split '/')[-1] } else { "Root Directory" }
        $displayName = if ($srcName.Length -gt 25) { $srcName.Substring(0, 22) + "..." } else { $srcName }
        
        $transferStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $Global:TransferSpeed = "N/A"

        $PrgTotal.Maximum = 100; $PrgTotal.Value = 0; $PrgTotal.Style = "Marquee"

        $Global:RunLogFile = [System.IO.Path]::GetFullPath((Join-Path $env:TEMP "transfer_run_$([guid]::NewGuid().ToString('N')).log"))
        if (Test-Path -LiteralPath $Global:RunLogFile) { Remove-Item -LiteralPath $Global:RunLogFile -Force -ErrorAction SilentlyContinue }
        $null | Out-File -LiteralPath $Global:RunLogFile -Encoding utf8

        $rSrcBase = if($Global:SrcProvider -eq "LOCAL"){$Global:SrcLocalPath}elseif($Global:SrcProvider -eq "GCS"){"${Global:GcsBridgeName}:$($CmbSrcBucList.Text)/$Global:SrcPath"}else{"${Global:RemoteName}:${Global:SrcPath}"}
        $rDstBase = if($Global:DstProvider -eq "LOCAL"){$Global:DstLocalPath}elseif($Global:DstProvider -eq "GCS"){"${Global:GcsBridgeName}:$($CmbDstBucList.Text)/$Global:DstPath"}else{"${Global:RemoteName}:${Global:DstPath}"}
        $rSrcBase = $rSrcBase -replace '(?<!:)/{2,}', '/'
        $rDstBase = $rDstBase -replace '(?<!:)/{2,}', '/'

        $gSrcBase = if($Global:SrcProvider -eq "GCS"){"gs://$($CmbSrcBucList.Text)/$($Global:SrcPath.Trim('/'))"}else{$Global:SrcLocalPath}
        $gDstBase = if($Global:DstProvider -eq "GCS"){"gs://$($CmbDstBucList.Text)/$($Global:DstPath.Trim('/'))"}else{$Global:DstLocalPath}
        $gSrcBase = $gSrcBase -replace '(?<!gs:)/{2,}', '/'
        $gDstBase = $gDstBase -replace '(?<!gs:)/{2,}', '/'

        $Global:TotalTransferItems = -1
        $LblFolderCount.Text = "Item(s): Waiting for tool output..."
        $LblProgress.Text = "Progress ($displayName): Starting..."

        $transferCommands = New-Object 'System.Collections.Generic.List[TransferCommand]'
        $gcloudToolPath = if ($Global:GCloudBin) { Join-Path $Global:GCloudBin "gcloud.cmd" } else { "gcloud.cmd" }
        $gcloudEnvironment = @{}
        if ($env:CLOUDSDK_PYTHON) { $gcloudEnvironment["CLOUDSDK_PYTHON"] = $env:CLOUDSDK_PYTHON }

        $Global:ExcludeFile = ""
        if (-not $UseGCloud) {
            $excludeLines = New-Object System.Collections.ArrayList
            if ($incItems.Count -gt 0 -and $totCount -gt 0) {
                foreach ($cf in $Global:CustomFilters) {
                    $rcFilter = $cf -replace '\\', '/'
                    [void]$excludeLines.Add($rcFilter)
                }
            } else {
                foreach ($exc in $excList) {
                    [void]$excludeLines.Add("/$exc/**")
                    [void]$excludeLines.Add("/$exc")
                }
                foreach ($cf in $Global:CustomFilters) {
                    $rcFilter = $cf -replace '\\', '/'
                    [void]$excludeLines.Add($rcFilter)
                }
            }

            if ($excludeLines.Count -gt 0) {
                $Global:ExcludeFile = [System.IO.Path]::GetFullPath((Join-Path $env:TEMP "excludes_$([guid]::NewGuid().ToString('N')).txt"))
                [System.IO.File]::WriteAllLines($Global:ExcludeFile, $excludeLines.ToArray(), (New-Object System.Text.UTF8Encoding $false))
            }
        }

        if ($incItems.Count -gt 0 -and $totCount -gt 0) {
            foreach ($incObj in $incItems) {
                $incName = $incObj.Name
                
                if ($UseGCloud) {
                    $srcTarget = if ($Global:SrcProvider -eq "LOCAL") { Join-Path $gSrcBase $incName } else { "$gSrcBase/$incName" -replace '(?<!gs:)/{2,}', '/' }
                    $dstTarget = if ($Global:DstProvider -eq "LOCAL") { Join-Path $gDstBase $incName } else { "$gDstBase/$incName" -replace '(?<!gs:)/{2,}', '/' }
                    
                    $srcTargetSafe = if ($Global:SrcProvider -eq "LOCAL" -and $srcTarget.EndsWith('\')) { $srcTarget + '\' } else { $srcTarget }
                    $dstTargetSafe = if ($Global:DstProvider -eq "LOCAL" -and $dstTarget.EndsWith('\')) { $dstTarget + '\' } else { $dstTarget }
                    
                    if ($incObj.IsDir) {
                        if ($Global:SrcProvider -eq "LOCAL" -and (Test-Path -LiteralPath $srcTargetSafe)) {
                            try {
                                $allDirs = Get-ChildItem -LiteralPath $srcTargetSafe -Recurse -Directory -Force -ErrorAction SilentlyContinue
                                foreach ($dir in $allDirs) {
                                    $items = Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
                                    if ($null -eq $items -or $items.Count -eq 0) { $null | Out-File -FilePath (Join-Path $dir.FullName ".placeholder") -Encoding utf8 }
                                }
                                $rootItems = Get-ChildItem -LiteralPath $srcTargetSafe -Force -ErrorAction SilentlyContinue
                                if ($null -eq $rootItems -or $rootItems.Count -eq 0) { $null | Out-File -FilePath (Join-Path $srcTargetSafe ".placeholder") -Encoding utf8 }
                            } catch {}
                        }
                        
                        $gArgs = @("storage", "rsync", $srcTargetSafe, $dstTargetSafe, "--recursive")
                        
                        $gcloudExcludes = @()
                        if ($Global:CustomFilters.Count -gt 0) {
                            foreach ($cf in $Global:CustomFilters) {
                                $norm = $cf -replace '\\', '/'
                                $regexFilter = [regex]::Escape($norm) -replace '\\\*', '.*' -replace '\\\?', '.' -replace '\\ ', ' '
                                $gcloudExcludes += '.*' + $regexFilter + '.*'
                            }
                        }
                        if ($gcloudExcludes.Count -gt 0) {
                            $regex = '(?i)(' + ($gcloudExcludes -join '|') + ')'
                            $gArgs += "-x"
                            $gArgs += $regex
                        }
                    } else {
                        $gArgs = @("storage", "cp", $srcTargetSafe, $dstTargetSafe)
                    }
                    if ($Global:AppSettings.IsDebugMode) { $gArgs += "--verbosity=debug" }
                    $null = $transferCommands.Add((New-TransferCommand -ToolPath $gcloudToolPath -Source $srcTargetSafe -Destination $dstTargetSafe -ArgumentList $gArgs -WorkingDirectory $Global:GCloudBin -Environment $gcloudEnvironment -Description "$srcTargetSafe -> $dstTargetSafe"))
                    
                } else {
                    $srcTarget = if ($Global:SrcProvider -eq "LOCAL") { Join-Path $rSrcBase $incName } else { "$rSrcBase/$incName" -replace '(?<!:)/{2,}', '/' }
                    $dstTarget = if ($Global:DstProvider -eq "LOCAL") { Join-Path $rDstBase $incName } else { "$rDstBase/$incName" -replace '(?<!:)/{2,}', '/' }
                    
                    $srcTargetSafe = if ($Global:SrcProvider -eq "LOCAL" -and $srcTarget.EndsWith('\')) { $srcTarget + '\' } else { $srcTarget }
                    $dstTargetSafe = if ($Global:DstProvider -eq "LOCAL" -and $dstTarget.EndsWith('\')) { $dstTarget + '\' } else { $dstTarget }

                    $tThreads = $Global:AppSettings.TransferThreads
                    
                    if ($incObj.IsDir) {
                        $rcloneArgs = @("copy", $srcTargetSafe, $dstTargetSafe, "--create-empty-src-dirs", "-v", "--stats", "30s", "--config", $Global:TempConfig, "--retries", "3", "--low-level-retries", "3", "--contimeout", "30s", "--tpslimit", "$tThreads", "--checkers", "$tThreads", "--transfers", "$tThreads", "--drive-pacer-min-sleep", "50ms")
                        
                        if ($Global:SrcProvider -eq "GDRIVE" -and $CmbSrcProjList.SelectedItem -eq "Shared Drive") { $rcloneArgs += "--drive-team-drive=$($Global:DriveMap[$CmbSrcBucList.Text])" }
                        if ($Global:DstProvider -eq "GDRIVE" -and $CmbDstProjList.SelectedItem -eq "Shared Drive") { $rcloneArgs += "--drive-team-drive=$($Global:DriveMap[$CmbDstBucList.Text])" }
                        $gcsProj = if ($Global:SrcProvider -eq "GCS") { $CmbSrcProjList.SelectedItem } elseif ($Global:DstProvider -eq "GCS") { $CmbDstProjList.SelectedItem } else { "" }
                        if ($gcsProj -and $gcsProj -notmatch "No Project") { $rcloneArgs += "--gcs-project-number=$gcsProj" }
                        if ($Global:SrcProvider -eq "GCS" -or $Global:DstProvider -eq "GCS") { $rcloneArgs += "--gcs-bucket-policy-only" }
                    } else {
                        $rcloneArgs = @("copyto", $srcTargetSafe, $dstTargetSafe, "-v", "--stats", "30s", "--config", $Global:TempConfig, "--retries", "3", "--low-level-retries", "3", "--contimeout", "30s", "--tpslimit", "$tThreads", "--checkers", "$tThreads", "--transfers", "$tThreads", "--drive-pacer-min-sleep", "50ms")
                        
                        if ($Global:SrcProvider -eq "GDRIVE" -and $CmbSrcProjList.SelectedItem -eq "Shared Drive") { $rcloneArgs += "--drive-team-drive=$($Global:DriveMap[$CmbSrcBucList.Text])" }
                        if ($Global:DstProvider -eq "GDRIVE" -and $CmbDstProjList.SelectedItem -eq "Shared Drive") { $rcloneArgs += "--drive-team-drive=$($Global:DriveMap[$CmbDstBucList.Text])" }
                        $gcsProj = if ($Global:SrcProvider -eq "GCS") { $CmbSrcProjList.SelectedItem } elseif ($Global:DstProvider -eq "GCS") { $CmbDstProjList.SelectedItem } else { "" }
                        if ($gcsProj -and $gcsProj -notmatch "No Project") { $rcloneArgs += "--gcs-project-number=$gcsProj" }
                        if ($Global:SrcProvider -eq "GCS" -or $Global:DstProvider -eq "GCS") { $rcloneArgs += "--gcs-bucket-policy-only" }
                    }
                    
                    if ($Global:ExcludeFile) {
                        $rcloneArgs += "--exclude-from"
                        $rcloneArgs += $Global:ExcludeFile
                    }

                    $null = $transferCommands.Add((New-TransferCommand -ToolPath $Global:RcloneExe -Source $srcTargetSafe -Destination $dstTargetSafe -ArgumentList $rcloneArgs -WorkingDirectory (Split-Path -Path $Global:RcloneExe -Parent) -Description "$srcTargetSafe -> $dstTargetSafe"))
                }
            }
        } else {
            
            if ($UseGCloud) {
                $srcTargetSafe = if ($Global:SrcProvider -eq "LOCAL" -and $gSrcBase.EndsWith('\')) { $gSrcBase + '\' } else { $gSrcBase }
                $dstTargetSafe = if ($Global:DstProvider -eq "LOCAL" -and $gDstBase.EndsWith('\')) { $gDstBase + '\' } else { $gDstBase }
                
                if ($Global:SrcProvider -eq "LOCAL" -and (Test-Path -LiteralPath $srcTargetSafe) -and (-not $Global:SrcIsFile)) {
                    try {
                        $allDirs = Get-ChildItem -LiteralPath $srcTargetSafe -Recurse -Directory -Force -ErrorAction SilentlyContinue
                        foreach ($dir in $allDirs) {
                            $items = Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
                            if ($null -eq $items -or $items.Count -eq 0) { $null | Out-File -FilePath (Join-Path $dir.FullName ".placeholder") -Encoding utf8 }
                        }
                        $rootItems = Get-ChildItem -LiteralPath $srcTargetSafe -Force -ErrorAction SilentlyContinue
                        if ($null -eq $rootItems -or $rootItems.Count -eq 0) { $null | Out-File -FilePath (Join-Path $srcTargetSafe ".placeholder") -Encoding utf8 }
                    } catch {}
                }
                
                if ($Global:SrcIsFile) {
                    $gArgs = @("storage", "cp", $srcTargetSafe, $dstTargetSafe)
                } else {
                    $gArgs = @("storage", "rsync", $srcTargetSafe, $dstTargetSafe, "--recursive")
                    $gcloudExcludes = @()
                    if ($Global:CustomFilters.Count -gt 0) {
                        foreach ($cf in $Global:CustomFilters) {
                            $norm = $cf -replace '\\', '/'
                            $regexFilter = [regex]::Escape($norm) -replace '\\\*', '.*' -replace '\\\?', '.' -replace '\\ ', ' '
                            $gcloudExcludes += '.*' + $regexFilter + '.*'
                        }
                    }
                    if ($gcloudExcludes.Count -gt 0) {
                        $regex = '(?i)(' + ($gcloudExcludes -join '|') + ')'
                        $gArgs += "-x"
                        $gArgs += $regex
                    }
                }
                if ($Global:AppSettings.IsDebugMode) { $gArgs += "--verbosity=debug" }
                $null = $transferCommands.Add((New-TransferCommand -ToolPath $gcloudToolPath -Source $srcTargetSafe -Destination $dstTargetSafe -ArgumentList $gArgs -WorkingDirectory $Global:GCloudBin -Environment $gcloudEnvironment -Description "$srcTargetSafe -> $dstTargetSafe"))
            } else {
                $rDst = $rDstBase
                if ($srcName -and $srcName -ne "Root Directory" -and $srcName -notmatch "Multiple Items") {
                    $rDst = if ($Global:DstProvider -eq "LOCAL") { Join-Path $rDstBase $srcName } else { "$rDstBase/$srcName" -replace '(?<!:)/{2,}', '/' }
                }
                $srcTargetSafe = if ($Global:SrcProvider -eq "LOCAL" -and $rSrcBase.EndsWith('\')) { $rSrcBase + '\' } else { $rSrcBase }
                $dstTargetSafe = if ($Global:DstProvider -eq "LOCAL" -and $rDst.EndsWith('\')) { $rDst + '\' } else { $rDst }
                
                $tThreads = $Global:AppSettings.TransferThreads
                
                $rcloneArgs = @("copy", $srcTargetSafe, $dstTargetSafe, "--create-empty-src-dirs", "-v", "--stats", "30s", "--config", $Global:TempConfig, "--retries", "3", "--low-level-retries", "3", "--contimeout", "30s", "--tpslimit", "$tThreads", "--checkers", "$tThreads", "--transfers", "$tThreads", "--drive-pacer-min-sleep", "50ms")
                
                if ($Global:SrcProvider -eq "GDRIVE" -and $CmbSrcProjList.SelectedItem -eq "Shared Drive") { $rcloneArgs += "--drive-team-drive=$($Global:DriveMap[$CmbSrcBucList.Text])" }
                if ($Global:DstProvider -eq "GDRIVE" -and $CmbDstProjList.SelectedItem -eq "Shared Drive") { $rcloneArgs += "--drive-team-drive=$($Global:DriveMap[$CmbDstBucList.Text])" }
                $gcsProj = if ($Global:SrcProvider -eq "GCS") { $CmbSrcProjList.SelectedItem } elseif ($Global:DstProvider -eq "GCS") { $CmbDstProjList.SelectedItem } else { "" }
                if ($gcsProj -and $gcsProj -notmatch "No Project") { $rcloneArgs += "--gcs-project-number=$gcsProj" }
                if ($Global:SrcProvider -eq "GCS" -or $Global:DstProvider -eq "GCS") { $rcloneArgs += "--gcs-bucket-policy-only" }

                if ($Global:ExcludeFile) {
                    $rcloneArgs += "--exclude-from"
                    $rcloneArgs += $Global:ExcludeFile
                }

                $null = $transferCommands.Add((New-TransferCommand -ToolPath $Global:RcloneExe -Source $srcTargetSafe -Destination $dstTargetSafe -ArgumentList $rcloneArgs -WorkingDirectory (Split-Path -Path $Global:RcloneExe -Parent) -Description "$srcTargetSafe -> $dstTargetSafe"))
            }
        }

        if ($transferCommands.Count -eq 0) {
            Log-Message "No transfer commands were generated. Review the current selection." "LightCoral"
            Restore-TransferUiState
            return
        }

        $transferJob = [TransferJob]::new()
        $transferJob.Source = if ($UseGCloud) { $gSrcBase } else { $rSrcBase }
        $transferJob.Destination = if ($UseGCloud) { $gDstBase } else { $rDstBase }
        $transferJob.ToolPath = if ($UseGCloud) { $gcloudToolPath } else { $Global:RcloneExe }
        $transferJob.DisplayName = $displayName
        $transferJob.TotalItems = $Global:TotalTransferItems
        $transferJob.ExcludeFile = $Global:ExcludeFile
        $transferJob.Commands = $transferCommands.ToArray()

        $runtime = Invoke-TransferJob -TransferJob $transferJob
        $Global:ActiveTransfer = [PSCustomObject]@{
            Job = $transferJob
            Queue = $runtime.Queue
            State = $runtime.State
            Runspace = $runtime.Runspace
            PowerShell = $runtime.PowerShell
            AsyncResult = $runtime.AsyncResult
            Stopwatch = $transferStopwatch
            ReportLog = $ReportLog
            DisplayName = $displayName
            StartTimeSafe = $startTimeSafe
            RegCopied = 0
            RegFailed = 0
            QuotaReached = $false
            ProcessFailed = $false
            ExitCode = $null
            Finalized = $false
            TotalSourceItems = $Global:TotalTransferItems
            RunLogFile = $Global:RunLogFile
        }

        $Global:TransferUiTimer.Start()
        return
    }

    if ($Global:CurrentTaskId) {
        for ($i = 0; $i -lt $Global:Tasks.Count; $i++) {
            if ($Global:Tasks[$i].Id -eq $Global:CurrentTaskId) {
                $Global:Tasks[$i].Status = "Error"
                $Global:Tasks[$i].LogData = $RtbLog.Text
                break
            }
        }
        Save-Tasks
        Sync-TasksToUI
    }

    Restore-TransferUiState
})

$Form.Add_FormClosing({
    Stop-ActiveTransferProcess
    try {
        if (![string]::IsNullOrEmpty($Global:JsonTempFile) -and (Test-Path -LiteralPath $Global:JsonTempFile)) { Remove-Item -LiteralPath $Global:JsonTempFile -Force -ErrorAction SilentlyContinue }
        if (![string]::IsNullOrEmpty($Global:RunLogFile) -and (Test-Path -LiteralPath $Global:RunLogFile)) { Remove-Item -LiteralPath $Global:RunLogFile -Force -ErrorAction SilentlyContinue }
        if (![string]::IsNullOrEmpty($Global:ExcludeFile) -and (Test-Path -LiteralPath $Global:ExcludeFile)) { Remove-Item -LiteralPath $Global:ExcludeFile -Force -ErrorAction SilentlyContinue }
    } catch {}
})

$BtnStop.Add_Click({ 
    if ($Global:ActiveTransfer) { 
        if ([System.Windows.Forms.MessageBox]::Show("Are you sure you want to abort the current transfer?", "Confirm Abort", "YesNo", "Warning") -eq "Yes") { 
            Stop-ActiveTransferProcess
        } 
    } 
})

$Form.ShowDialog() | Out-Null
}
