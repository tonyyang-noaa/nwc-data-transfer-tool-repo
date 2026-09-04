param()

& {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# --- GLOBAL VARIABLES ---
$Global:JsonTempFile = [System.IO.Path]::GetFullPath("$env:TEMP\unified_out_$([guid]::NewGuid().ToString('N')).json")
$Global:RunLogFile = ""
$Global:ExcludeFile = ""
$Global:BatFile = ""
$Global:CurrentProcess = $null
$Global:StopTransfer = $false
$Global:LoadingHistory = $false 
$Global:FullLogLines = New-Object System.Collections.ArrayList

# ENGINE FIX: UI Soft-Lock State Tracker
$Global:IsTransferring = $false
$Global:TotalTransferItems = 0

# Sorting States
$Global:SortCol = -1
$Global:SortAsc = $true

# App Data & Persistence
$Global:AppDir = Join-Path $env:APPDATA "DataTransferTool"
if (-not (Test-Path -LiteralPath $Global:AppDir)) { 
    try { New-Item -ItemType Directory -Path $Global:AppDir -ErrorAction Stop | Out-Null } catch {} 
}
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

# UI FIX 1: Set Default Theme to Light Mode (IsDarkMode = $false)
$Global:AppSettings = [PSCustomObject]@{ RclonePath = ""; GCloudPath = ""; IsDarkMode = $false; IsDebugMode = $false; TransferThreads = 3; CustomFilters = @(); DriveClientId = ""; DriveClientSecret = ""; GcsAuthType = "UserOAuth"; GcsServiceAccountKeyPath = ""; ForceRcloneGcs = $false }

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

# --- 1. SYSTEM ENVIRONMENT & SETTINGS ---
try { Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\python.exe" -Name "(Default)" -ErrorAction Stop } catch {}
try { Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\python3.exe" -Name "(Default)" -ErrorAction Stop } catch {}

function Load-Settings {
    # Self-heal missing properties to prevent silent save failures
    if (-not (Get-Member -InputObject $Global:AppSettings -Name "ForceRcloneGcs" -ErrorAction SilentlyContinue)) {
        $Global:AppSettings | Add-Member -MemberType NoteProperty -Name "ForceRcloneGcs" -Value $false
    }
    
    try {
        if (Test-Path -LiteralPath $Global:SettingsFile -ErrorAction Stop) {
            $loaded = Get-Content -Raw -LiteralPath $Global:SettingsFile | ConvertFrom-Json 
            if ($loaded.RclonePath) { $Global:AppSettings.RclonePath = $loaded.RclonePath }
            if ($loaded.GCloudPath) { $Global:AppSettings.GCloudPath = $loaded.GCloudPath }
            if ($null -ne $loaded.IsDarkMode) { $Global:AppSettings.IsDarkMode = [bool]$loaded.IsDarkMode }
            if ($null -ne $loaded.IsDebugMode) { $Global:AppSettings.IsDebugMode = [bool]$loaded.IsDebugMode }
            if ($null -ne $loaded.TransferThreads) { $Global:AppSettings.TransferThreads = [int]$loaded.TransferThreads }
            if ($loaded.CustomFilters) { $Global:AppSettings.CustomFilters = $loaded.CustomFilters }
            if ($loaded.DriveClientId) { $Global:AppSettings.DriveClientId = $loaded.DriveClientId }
            if ($loaded.DriveClientSecret) { $Global:AppSettings.DriveClientSecret = $loaded.DriveClientSecret }
            if ($loaded.GcsAuthType) { $Global:AppSettings.GcsAuthType = $loaded.GcsAuthType }
            if ($loaded.GcsServiceAccountKeyPath) { $Global:AppSettings.GcsServiceAccountKeyPath = $loaded.GcsServiceAccountKeyPath }
            if ($null -ne $loaded.ForceRcloneGcs) { $Global:AppSettings.ForceRcloneGcs = [bool]$loaded.ForceRcloneGcs }
        }
    } catch {}
}

function Save-Settings { $Global:AppSettings | ConvertTo-Json -Depth 2 | Out-File -LiteralPath $Global:SettingsFile -Encoding utf8 -Force }

Load-Settings
if ($null -eq $Global:AppSettings.CustomFilters -or $Global:AppSettings.CustomFilters.Count -eq 0) {
    $Global:AppSettings.CustomFilters = $Global:DefaultFilters
}
$Global:CustomFilters = $Global:AppSettings.CustomFilters

function Get-GcsServiceAccountInfo([string]$KeyPath) {
    if ([string]::IsNullOrWhiteSpace($KeyPath) -or -not (Test-Path -LiteralPath $KeyPath)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $KeyPath -Raw -ErrorAction Stop
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($json.type -eq "service_account" -and $json.client_email) {
            return [PSCustomObject]@{
                client_email = $json.client_email
                project_id   = $json.project_id
                private_key_id = $json.private_key_id
            }
        }
    } catch {}
    return $null
}

function Activate-GcsServiceAccount([string]$KeyPath) {
    if ([string]::IsNullOrWhiteSpace($KeyPath) -or -not (Test-Path -LiteralPath $KeyPath)) { return $false }
    $info = Get-GcsServiceAccountInfo $KeyPath
    if (-not $info) { return $false }

    $gcmd = if ($Global:GCloudBin) { Join-Path $Global:GCloudBin "gcloud.cmd" } else { "gcloud.cmd" }
    try {
        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName = "cmd.exe"
        $pInfo.Arguments = "/c `"`"$gcmd`" auth activate-service-account --key-file=`"$KeyPath`"`""
        $pInfo.UseShellExecute = $false
        $pInfo.CreateNoWindow = $true
        $pInfo.WorkingDirectory = $env:TEMP
        $p = [System.Diagnostics.Process]::Start($pInfo)
        $p.WaitForExit()
        if ($p.ExitCode -eq 0) {
            $Global:AppSettings.GcsAuthType = "ServiceAccount"
            $Global:AppSettings.GcsServiceAccountKeyPath = $KeyPath
            $env:GOOGLE_APPLICATION_CREDENTIALS = $KeyPath
            Save-Settings
            Set-RcloneEnvironment
            return $true
        }
    } catch {}
    return $false
}

function Revoke-GcsServiceAccount {
    $gcmd = if ($Global:GCloudBin) { Join-Path $Global:GCloudBin "gcloud.cmd" } else { "gcloud.cmd" }
    try {
        $info = Get-GcsServiceAccountInfo $Global:AppSettings.GcsServiceAccountKeyPath
        $acc = if ($info -and $info.client_email) { $info.client_email } else { "" }
        $arg = if ($acc) { "auth revoke `"$acc`" --quiet" } else { "auth revoke --all --quiet" }
        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName = "cmd.exe"
        $pInfo.Arguments = "/c `"`"$gcmd`" $arg`""
        $pInfo.UseShellExecute = $false
        $pInfo.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($pInfo)
        $p.WaitForExit()
    } catch {}

    $Global:AppSettings.GcsServiceAccountKeyPath = ""
    try { Remove-Item Env:GOOGLE_APPLICATION_CREDENTIALS -ErrorAction SilentlyContinue } catch {}
    Save-Settings
    Set-RcloneEnvironment
    Set-GCloudEnvironment
}

function Set-RcloneEnvironment {
    $Global:RcloneExe = ""
    $customRcloneValid = $false
    try {
        if (![string]::IsNullOrWhiteSpace($Global:AppSettings.RclonePath) -and (Test-Path -LiteralPath $Global:AppSettings.RclonePath -ErrorAction Stop)) {
            $customRcloneValid = $true
        }
    } catch {}

    if ($customRcloneValid) {
        $Global:RcloneExe = $Global:AppSettings.RclonePath
    } else {
        $Global:RcloneExe = Join-Path -Path $Global:ScriptDir -ChildPath "rclone.exe"
        $localRcloneExists = $false
        try {
            if (Test-Path -LiteralPath $Global:RcloneExe -ErrorAction Stop) { $localRcloneExists = $true }
        } catch {}

        if (-not $localRcloneExists) { 
            try {
                $rCmd = Get-Command "rclone.exe" -ErrorAction Stop
                if ($rCmd) { $Global:RcloneExe = $rCmd.Source }
            } catch {
            }
        }
    }
    
    if ($Global:RcloneExe) {
        $saKeyOption = ""
        if ($Global:AppSettings.GcsAuthType -eq "ServiceAccount" -and !([string]::IsNullOrWhiteSpace($Global:AppSettings.GcsServiceAccountKeyPath)) -and (Test-Path -LiteralPath $Global:AppSettings.GcsServiceAccountKeyPath -ErrorAction SilentlyContinue)) {
            $escapedKey = $Global:AppSettings.GcsServiceAccountKeyPath -replace '\\', '/'
            $saKeyOption = "`nservice_account_file = $escapedKey"
        }
        if ($Global:AppSettings.ForceRcloneGcs -and $Global:AppSettings.GcsAuthType -eq "UserOAuth") {
        # Let Rclone manage its own OAuth token
    } else {
        $confStr = "[$Global:GcsBridgeName]`ntype = google cloud storage`nenv_auth = true`nbucket_policy_only = true$saKeyOption`n"
        try {
            if (-not (Test-Path -LiteralPath $Global:TempConfig -ErrorAction Stop)) { 
                $confStr | Out-File -LiteralPath $Global:TempConfig -Encoding utf8 -Force
            } else {
                $currentCfg = Get-Content -LiteralPath $Global:TempConfig -Raw
                $newCfg = [regex]::Replace($currentCfg, "(?ms)\[$([regex]::Escape($Global:GcsBridgeName))\].*?(?=(\[[^\]]+\]|\z))", "")
                $newCfg = $newCfg.Trim() + "`n`n" + $confStr.Trim() + "`n"
                $newCfg | Out-File -LiteralPath $Global:TempConfig -Encoding utf8 -Force
            }
        } catch {}
    }
    }
}

function Set-GCloudEnvironment {
    $Global:GCloudBin = ""
    $customGcloudValid = $false
    try {
        if (![string]::IsNullOrWhiteSpace($Global:AppSettings.GCloudPath) -and (Test-Path -LiteralPath $Global:AppSettings.GCloudPath -ErrorAction Stop)) {
            $customGcloudValid = $true
        }
    } catch {}

    if ($customGcloudValid) {
        $Global:GCloudBin = $Global:AppSettings.GCloudPath
        $env:Path += ";$Global:GCloudBin"
    } else {
        try {
            $gcloudCmd = Get-Command "gcloud.cmd" -ErrorAction Stop
            if ($gcloudCmd) { $Global:GCloudBin = Split-Path $gcloudCmd.Source }
        } catch {}

        if (!$Global:GCloudBin) {
            $defaultPaths = @("$env:LocalAppData\Google\Cloud SDK\google-cloud-sdk\bin", "${env:ProgramFiles(x86)}\Google\Cloud SDK\google-cloud-sdk\bin")
            foreach ($p in $defaultPaths) { 
                try {
                    if (Test-Path -LiteralPath "$p\gcloud.cmd" -ErrorAction Stop) { 
                        $env:Path += ";$p"
                        $Global:GCloudBin = $p
                        break 
                    }
                } catch {}
            }
        }
    }
    
    if ($Global:GCloudBin) {
        $sdkRoot = Split-Path $Global:GCloudBin
        $BundledPython = Join-Path $sdkRoot "platform\bundledpython\python.exe"
        try {
            if (Test-Path -LiteralPath $BundledPython -ErrorAction Stop) { $env:CLOUDSDK_PYTHON = $BundledPython }
        } catch {}
    }
    
    if ($Global:AppSettings.GcsAuthType -eq "ServiceAccount" -and !([string]::IsNullOrWhiteSpace($Global:AppSettings.GcsServiceAccountKeyPath)) -and (Test-Path -LiteralPath $Global:AppSettings.GcsServiceAccountKeyPath -ErrorAction SilentlyContinue)) {
        $env:GOOGLE_APPLICATION_CREDENTIALS = $Global:AppSettings.GcsServiceAccountKeyPath
    } else {
        $adcPath = Join-Path $env:APPDATA "gcloud\application_default_credentials.json"
        try {
            if (Test-Path $adcPath -ErrorAction Stop) { $env:GOOGLE_APPLICATION_CREDENTIALS = $adcPath }
        } catch {}
    }
}

Set-RcloneEnvironment; Set-GCloudEnvironment

function Load-Tasks {
    try {
        if (Test-Path -LiteralPath $Global:DbPath -ErrorAction Stop) {
            $Global:Tasks = (Get-Content -Raw -LiteralPath $Global:DbPath | ConvertFrom-Json)
        }
    } catch { 
        $Global:Tasks = @() 
    }
    if ($null -eq $Global:Tasks) { $Global:Tasks = @() }
    if ($Global:Tasks -isnot [array]) { $Global:Tasks = @($Global:Tasks) }
}
function Save-Tasks { $Global:Tasks | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $Global:DbPath -Encoding utf8 -Force }

# --- 2. GUI INITIALIZATION (SIDE-BY-SIDE LAYOUT) ---
$Form = New-Object System.Windows.Forms.Form
$Form.Text = "Data Transfer Tool v1.1.50"
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
    if ($Prefix -eq "Src") {
        $Global:SplitSrc = New-Object System.Windows.Forms.SplitContainer
        $Global:SplitSrc.Orientation = [System.Windows.Forms.Orientation]::Horizontal
        $Global:SplitSrc.Dock = "Fill"; $Global:SplitSrc.BorderStyle = "FixedSingle"; $Global:SplitSrc.SplitterWidth = 6
        $Global:SplitSrc.FixedPanel = [System.Windows.Forms.FixedPanel]::Panel1
        $Panel.Controls.Add($Global:SplitSrc)
        $Global:SplitSrc.BringToFront()
        $TargetPanelTop = $Global:SplitSrc.Panel1
        $TargetPanelBot = $Global:SplitSrc.Panel2
    } else {
        $TargetPanelTop = $Panel
        $TargetPanelBot = $Panel
    }

    $PTop = New-Object System.Windows.Forms.Panel; $PTop.Dock = "Top"; $PTop.Height = 145; $TargetPanelTop.Controls.Add($PTop)
    
    $yOff = 38 
    
    if ($Prefix -eq "Src") {
        $LblTName = New-Object System.Windows.Forms.Label; $LblTName.Text = "Transfer Name:"; $LblTName.Font = $BoldFont; $LblTName.Location = New-Object System.Drawing.Point(5, 10); $LblTName.AutoSize = $true; $PTop.Controls.Add($LblTName)
        $TxtTName = New-Object System.Windows.Forms.TextBox; $TxtTName.Location = New-Object System.Drawing.Point(125, 7); $TxtTName.Size = New-Object System.Drawing.Size(250, 25); $TxtTName.Anchor = "Top, Left"; $TxtTName.BackColor = $InputColor; $TxtTName.ForeColor = $TextColor; $TxtTName.BorderStyle = "FixedSingle"; $PTop.Controls.Add($TxtTName)
        Set-Variable -Name "TxtTaskName" -Value $TxtTName -Scope Global
    }

    $LblTitle = New-Object System.Windows.Forms.Label; $LblTitle.Text = $TitleStr; $LblTitle.Font = $BoldFont; $LblTitle.Location = New-Object System.Drawing.Point(5, $yOff); $LblTitle.AutoSize = $true; $PTop.Controls.Add($LblTitle)
    
    $CmbProv = New-Object System.Windows.Forms.ComboBox; $CmbProv.Location = New-Object System.Drawing.Point(125, ($yOff - 3)); $CmbProv.Size = New-Object System.Drawing.Size(250, 25); $CmbProv.DropDownStyle = "DropDownList"; $CmbProv.BackColor = $InputColor; $CmbProv.ForeColor = $TextColor; $CmbProv.FlatStyle = "Flat"; [void]$CmbProv.Items.AddRange(@("--- Select Storage ---", "Google Cloud Storage", "Google Drive", "Local Storage")); $CmbProv.SelectedIndex = 0; $CmbProv.Anchor = "Top, Left"; $PTop.Controls.Add($CmbProv)
    
    $CmbAuth = New-Object System.Windows.Forms.ComboBox; $CmbAuth.Location = New-Object System.Drawing.Point(5, ($yOff + 26)); $CmbAuth.Size = New-Object System.Drawing.Size(160, 25); $CmbAuth.DropDownStyle = "DropDownList"; $CmbAuth.BackColor = $InputColor; $CmbAuth.ForeColor = $TextColor; $CmbAuth.FlatStyle = "Flat"; [void]$CmbAuth.Items.AddRange(@("User Account (OAuth)", "Service Account (.json)")); $CmbAuth.SelectedIndex = 0; $CmbAuth.Visible = $false; $CmbAuth.Anchor = "Top, Left"; $PTop.Controls.Add($CmbAuth)
    $BtnAu = New-Object System.Windows.Forms.Button; $BtnAu.Text = "Login/Auth"; $BtnAu.Location = New-Object System.Drawing.Point(5, ($yOff + 26)); $BtnAu.Size = New-Object System.Drawing.Size(95, 25); $BtnAu.Enabled = $false; Set-FlatButton $BtnAu; $PTop.Controls.Add($BtnAu)
    $BtnOut = New-Object System.Windows.Forms.Button; $BtnOut.Text = "Sign Out"; $BtnOut.Location = New-Object System.Drawing.Point(105, ($yOff + 26)); $BtnOut.Size = New-Object System.Drawing.Size(85, 25); $BtnOut.Enabled = $false; $BtnOut.Visible = $false; Set-FlatButton $BtnOut; $PTop.Controls.Add($BtnOut)
    $LblStat = New-Object System.Windows.Forms.Label; $LblStat.Text = "Not Connected"; $LblStat.ForeColor = "LightCoral"; $LblStat.Location = New-Object System.Drawing.Point(195, ($yOff + 30)); $LblStat.AutoSize = $true; $PTop.Controls.Add($LblStat)
    
    $CmbProj = New-Object System.Windows.Forms.ComboBox; $CmbProj.Location = New-Object System.Drawing.Point(5, ($yOff + 55)); $CmbProj.Size = New-Object System.Drawing.Size(160, 25); $CmbProj.DropDownStyle = "DropDownList"; $CmbProj.FlatStyle = "Flat"; $CmbProj.Visible = $false; $CmbProj.Anchor = "Top, Left"; $PTop.Controls.Add($CmbProj)
    $CmbBuc = New-Object System.Windows.Forms.ComboBox; $CmbBuc.Location = New-Object System.Drawing.Point(175, ($yOff + 55)); $CmbBuc.Size = New-Object System.Drawing.Size(200, 25); $CmbBuc.DropDownStyle = "DropDownList"; $CmbBuc.FlatStyle = "Flat"; $CmbBuc.Visible = $false; $CmbBuc.Anchor = "Top, Left"; $PTop.Controls.Add($CmbBuc)
    
    $BtnLoc = New-Object System.Windows.Forms.Button; $BtnLoc.Text = "Select Folder"; $BtnLoc.Location = New-Object System.Drawing.Point(5, ($yOff + 55)); $BtnLoc.Size = New-Object System.Drawing.Size(100, 25); Set-FlatButton $BtnLoc; $BtnLoc.Visible = $false; $PTop.Controls.Add($BtnLoc)
    
    if ($Prefix -eq "Src") {
        $BtnFilter = New-Object System.Windows.Forms.Button; $BtnFilter.Text = "Filters"; $BtnFilter.Location = New-Object System.Drawing.Point(110, ($yOff + 55)); $BtnFilter.Size = New-Object System.Drawing.Size(90, 25); Set-FlatButton $BtnFilter; $BtnFilter.Visible = $false; $PTop.Controls.Add($BtnFilter)
        Set-Variable -Name "BtnSrcFilter" -Value $BtnFilter -Scope Global
    }

    $LblPth = New-Object System.Windows.Forms.Label; $LblPth.Text = "Path: /"; $LblPth.Location = New-Object System.Drawing.Point(5, ($yOff + 85)); $LblPth.Size = New-Object System.Drawing.Size(390, 20); $LblPth.Anchor = "Top, Left, Right"; $LblPth.AutoSize = $false; $LblPth.AutoEllipsis = $true; $PTop.Controls.Add($LblPth)

    if ($Prefix -eq "Src") {
        $PBot = New-Object System.Windows.Forms.Panel; $PBot.Dock = "Fill"; $TargetPanelBot.Controls.Add($PBot)
        
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
        $PBot = New-Object System.Windows.Forms.Panel; $PBot.Dock = "Bottom"; $PBot.Height = 35; $TargetPanelBot.Controls.Add($PBot)
        
        $LblSort = New-Object System.Windows.Forms.Label; $LblSort.Text = "Sort:"; $LblSort.Font = $BoldFont; $LblSort.Location = New-Object System.Drawing.Point(5, 8); $LblSort.AutoSize = $true; $PBot.Controls.Add($LblSort)
        $CmbSrt = New-Object System.Windows.Forms.ComboBox; $CmbSrt.Location = New-Object System.Drawing.Point(45, 5); $CmbSrt.Size = New-Object System.Drawing.Size(100, 25); $CmbSrt.DropDownStyle = "DropDownList"; $CmbSrt.FlatStyle = "Flat"; [void]$CmbSrt.Items.AddRange(@("Name (A-Z)", "Name (Z-A)", "Date (New)", "Date (Old)")); $CmbSrt.SelectedIndex = 0; $PBot.Controls.Add($CmbSrt)
        Set-Variable -Name "CmbSort" -Value $CmbSrt -Scope Global
        
        $BtnRef = New-Object System.Windows.Forms.Button; $BtnRef.Text = "Refresh"; $BtnRef.Location = New-Object System.Drawing.Point(150, 5); $BtnRef.Size = New-Object System.Drawing.Size(70, 25); $BtnRef.Enabled = $false; Set-FlatButton $BtnRef; $PBot.Controls.Add($BtnRef)
        $BtnNFolder = New-Object System.Windows.Forms.Button; $BtnNFolder.Text = "New Folder"; $BtnNFolder.Location = New-Object System.Drawing.Point(225, 5); $BtnNFolder.Size = New-Object System.Drawing.Size(80, 25); $BtnNFolder.Enabled = $false; Set-FlatButton $BtnNFolder; $PBot.Controls.Add($BtnNFolder)
        
        Set-Variable -Name "BtnDstRef" -Value $BtnRef -Scope Global
        Set-Variable -Name "BtnDstNewF" -Value $BtnNFolder -Scope Global
    }

    $Lbx = New-Object System.Windows.Forms.ListBox; $Lbx.Dock = "Fill"; $Lbx.IntegralHeight = $false; $Lbx.Font = $LogFont; $Lbx.Enabled = $false; $Lbx.BackColor = $InputColor; $Lbx.ForeColor = $TextColor; $Lbx.BorderStyle = "FixedSingle"; $Lbx.DisplayMember = "DisplayString"; $TargetPanelTop.Controls.Add($Lbx)
    $Lbx.BringToFront()
    
    $CmbBuc.Add_Enter({ if ($this.Text -match "Type Bucket") { $this.Text = "" } })
    $CmbBuc.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq 'Enter') {
            $e.SuppressKeyPress = $true
            $IsSource = ($sender -eq $Global:CmbSrcBucList)
            $locLbx  = if ($IsSource) { $Global:LbxSrcDir } else { $Global:LbxDstDir }
            $val = $sender.Text.Trim()
            if (![string]::IsNullOrWhiteSpace($val) -and $val -notmatch "Type Bucket" -and $val -notmatch "--- Bucket ---") {
                $locLbx.Enabled = $true
                if ($IsSource) { $Global:SrcPath = "" } else { $Global:DstPath = ""; $Global:BtnDstNewF.Enabled = $true; $Global:BtnDstRef.Enabled = $true }
                Update-Directory $IsSource
            }
        }
    })
    Set-Variable -Name "Cmb${Prefix}Provider" -Value $CmbProv -Scope Global; Set-Variable -Name "Cmb${Prefix}AuthType" -Value $CmbAuth -Scope Global; Set-Variable -Name "Btn${Prefix}Auth" -Value $BtnAu -Scope Global; Set-Variable -Name "Btn${Prefix}SignOut" -Value $BtnOut -Scope Global; Set-Variable -Name "Lbl${Prefix}AuthStatus" -Value $LblStat -Scope Global; Set-Variable -Name "Cmb${Prefix}ProjList" -Value $CmbProj -Scope Global; Set-Variable -Name "Cmb${Prefix}BucList" -Value $CmbBuc -Scope Global; Set-Variable -Name "Btn${Prefix}Loc" -Value $BtnLoc -Scope Global; Set-Variable -Name "Lbl${Prefix}Path" -Value $LblPth -Scope Global; Set-Variable -Name "Lbx${Prefix}Dir" -Value $Lbx -Scope Global
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
$AllDropdowns = @($CmbSrcProvider, $CmbSrcAuthType, $CmbSrcProjList, $CmbSrcBucList, $CmbDstProvider, $CmbDstAuthType, $CmbDstProjList, $CmbDstBucList, $CmbSort, $CmbSrcSort)
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
    
    $ThemeBtns = @($BtnNewTask, $BtnDuplicate, $BtnDelTask, $BtnClearAll, $BtnSettings, $BtnSrcAuth, $BtnSrcSignOut, $BtnSrcLoc, $BtnSrcFilter, $BtnDstAuth, $BtnDstSignOut, $BtnDstLoc, $BtnDstRef, $BtnDstNewF, $BtnCheckAll, $BtnUncheckAll, $BtnOpenLog)
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
    if ($null -eq $Global:FullLogLines) { $Global:FullLogLines = New-Object System.Collections.ArrayList }
    [void]$Global:FullLogLines.Add($msg)
    $RtbLog.SelectionStart = $RtbLog.TextLength
    if (-not $Global:AppSettings.IsDarkMode -and $color -eq "LightGray") { $color = "Black" }
    if (-not $Global:AppSettings.IsDarkMode -and $color -eq "White") { $color = "DarkGray" }
    $RtbLog.SelectionColor = [System.Drawing.Color]::$color
    $RtbLog.AppendText("$msg`n"); $RtbLog.ScrollToCaret()
    if ($RtbLog.Lines.Count -gt 150) {
        $excess = $RtbLog.Lines.Count - 150
        $cutPos = $RtbLog.GetFirstCharIndexFromLine($excess)
        if ($cutPos -gt 0) {
            $RtbLog.ReadOnly = $false
            $RtbLog.Select(0, $cutPos)
            $RtbLog.SelectedText = ""
            $RtbLog.ReadOnly = $true
        }
    }
}

function New-BrowserListItem([int]$Type, [string]$Name, [DateTime]$RawDate = [DateTime]::MinValue, [string]$DisplayString = $null) {
    if ([string]::IsNullOrWhiteSpace($DisplayString)) {
        if ($Type -eq -1) {
            $DisplayString = ".. [Go Up] | ---"
        } elseif ($Type -eq 0) {
            $dateStr = if ($RawDate -ne [DateTime]::MinValue) { $RawDate.ToString("yyyy-MM-dd HH:mm") } else { "---" }
            $DisplayString = ("[DIR]  {0,-30} | {1}" -f $Name, $dateStr)
        } elseif ($Type -eq 1) {
            $dateStr = if ($RawDate -ne [DateTime]::MinValue) { $RawDate.ToString("yyyy-MM-dd HH:mm") } else { "---" }
            $DisplayString = ("[FILE] {0,-30} | {1}" -f $Name, $dateStr)
        } else {
            $DisplayString = $Name
        }
    }

    return [PSCustomObject]@{
        Type = $Type
        Name = $Name
        RawDate = $RawDate
        DisplayString = $DisplayString
    }
}

# REFACTORED CLI EXECUTION: Uses native Invoke-Expression wrapper with robust JSON extraction
function Execute-Cli-Json($cmdArgs, [bool]$isRclone = $false) {
    $exePath = if ($isRclone) { $Global:RcloneExe } else { if ($Global:GCloudBin) { Join-Path $Global:GCloudBin "gcloud.cmd" } else { "gcloud.cmd" } }
    
    $outData = ""
    try {
        $cmd = "& `"$exePath`" $cmdArgs 2>&1"
        $outData = Invoke-Expression $cmd | Out-String
    } catch {}
    
    if (![string]::IsNullOrWhiteSpace($outData)) {
        $outData = $outData.Trim()
        $firstChar = $outData.IndexOfAny([char[]]('[', '{'))
        $lastChar = $outData.LastIndexOfAny([char[]](']', '}'))
        
        if ($firstChar -ge 0 -and $lastChar -ge $firstChar) {
            $jsonString = $outData.Substring($firstChar, $lastChar - $firstChar + 1)
            try { return (ConvertFrom-Json -InputObject $jsonString) } catch { return $null }
        }
    }
    return $null
}

function Execute-Cli-Text($cmdArgs, [bool]$isRclone = $false) {
    $exePath = if ($isRclone) { $Global:RcloneExe } else { if ($Global:GCloudBin) { Join-Path $Global:GCloudBin "gcloud.cmd" } else { "gcloud.cmd" } }

    try {
        $cmd = "& `"$exePath`" $cmdArgs 2>&1"
        return (Invoke-Expression $cmd | Out-String)
    } catch {
        return ""
    }
}

function Execute-Gsutil-Result($cmdArgs) {
    $gsutilCmd = $null
    try { $gsutilCmd = Get-Command "gsutil.cmd" -ErrorAction Stop } catch {}
    if (-not $gsutilCmd) {
        try { $gsutilCmd = Get-Command "gsutil" -ErrorAction Stop } catch {}
    }

    if (-not $gsutilCmd) {
        return [PSCustomObject]@{ ExitCode = -1; Output = "gsutil not found"; Command = "gsutil $cmdArgs" }
    }

    $outData = ""
    $exitCode = -1
    try {
        $cmd = "& `"$($gsutilCmd.Source)`" $cmdArgs 2>&1"
        $outData = Invoke-Expression $cmd | Out-String
        $exitCode = $LASTEXITCODE
    } catch {
        $outData = ""
        $exitCode = -1
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output = if ($outData) { $outData } else { "" }
        Command = "$($gsutilCmd.Source) $cmdArgs"
    }
}

# Returns a status label that reflects which OAuth credentials are active in the rclone config.
# Reads the persisted rclone config after auth so the answer is always definitive.
function Get-DriveAuthLabel {
    try {
        if (Test-Path -LiteralPath $Global:TempConfig) {
            $cfg = Get-Content -LiteralPath $Global:TempConfig -Raw
            # Find the [GWorkspaceAuth] section and check for a non-empty client_id line
            if ($cfg -match "(?ms)\[$([regex]::Escape($Global:RemoteName))\].*?client_id\s*=\s*([^\r\n]+)") {
                $storedId = $Matches[1].Trim()
                if (-not [string]::IsNullOrWhiteSpace($storedId)) {
                    return "Auth (GDrive - Custom ID)"
                }
            }
        }
    } catch {}
    return "Auth (GDrive - Built-in)"
}

function Execute-Cli-Result($cmdArgs, [bool]$isRclone = $false) {
    $exePath = if ($isRclone) { $Global:RcloneExe } else { if ($Global:GCloudBin) { Join-Path $Global:GCloudBin "gcloud.cmd" } else { "gcloud.cmd" } }

    $outData = ""
    $exitCode = -1
    try {
        $cmd = "& `"$exePath`" $cmdArgs 2>&1"
        $outData = Invoke-Expression $cmd | Out-String
        $exitCode = $LASTEXITCODE
    } catch {
        $outData = ""
        $exitCode = -1
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output = if ($outData) { $outData } else { "" }
        Command = "$exePath $cmdArgs"
    }
}

function Get-GcsProjectArg([object]$ProjectValue) {
    if (-not [string]::IsNullOrWhiteSpace($ProjectValue) -and $ProjectValue -notmatch "No Project") {
        return "--project=`"$ProjectValue`""
    }
    return ""
}

function Get-SourceLeafName {
    if (-not $Global:SrcIsFile) { return "" }
    if ($Global:SrcProvider -eq "LOCAL") {
        return (Split-Path $Global:SrcLocalPath -Leaf)
    }
    if ([string]::IsNullOrWhiteSpace($Global:SrcPath)) { return "" }
    return (($Global:SrcPath.TrimEnd('/') -split '/')[-1])
}

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
    $SF.Size = New-Object System.Drawing.Size(530, 530); $SF.StartPosition = "CenterParent"; $SF.FormBorderStyle = "FixedDialog"; $SF.MaximizeBox = $false; $SF.MinimizeBox = $false
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
    
    $chkForceRclone = New-Object System.Windows.Forms.CheckBox
    $chkForceRclone.Text = "Force Rclone engine for Local <-> GCS transfers (Bypasses gcloud session limits)"
    $chkForceRclone.Location = New-Object System.Drawing.Point(15, 155)
    $chkForceRclone.Size = New-Object System.Drawing.Size(485, 20)
    $chkForceRclone.Checked = $Global:AppSettings.ForceRcloneGcs
    $SF.Controls.Add($chkForceRclone)

    $lblT = New-Object System.Windows.Forms.Label; $lblT.Text = "Rclone Transfer Threads (1-6):"; $lblT.Location = New-Object System.Drawing.Point(15, 185); $lblT.AutoSize = $true; $SF.Controls.Add($lblT)
    
    $cmbT = New-Object System.Windows.Forms.ComboBox; $cmbT.Location = New-Object System.Drawing.Point(200, 182); $cmbT.Size = New-Object System.Drawing.Size(50, 20); $cmbT.DropDownStyle = "DropDownList"; $cmbT.FlatStyle = "Flat"; [void]$cmbT.Items.AddRange(@(1,2,3,4,5,6)); $cmbT.SelectedItem = $Global:AppSettings.TransferThreads; $cmbT.BackColor = $TxtTaskName.BackColor; $cmbT.ForeColor = $TxtTaskName.ForeColor; $SF.Controls.Add($cmbT)

    $lblTWarn = New-Object System.Windows.Forms.Label; $lblTWarn.Text = "Note: Using 4 or more threads on Google Drive may trigger 403 Rate Limit Quota Exceeded errors. 4+ threads are recommended for Local-to-Local transfers only."; $lblTWarn.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic); $lblTWarn.ForeColor = if ($Global:AppSettings.IsDarkMode) { [System.Drawing.Color]::LightCoral } else { [System.Drawing.Color]::IndianRed }; $lblTWarn.Location = New-Object System.Drawing.Point(15, 210); $lblTWarn.Size = New-Object System.Drawing.Size(485, 30); $SF.Controls.Add($lblTWarn)

    # --- Google Cloud Storage Service Account section ---
    $lblSASection = New-Object System.Windows.Forms.Label; $lblSASection.Text = "Google Cloud Storage - Service Account (Optional):"; $lblSASection.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold); $lblSASection.Location = New-Object System.Drawing.Point(15, 245); $lblSASection.AutoSize = $true; $SF.Controls.Add($lblSASection)

    $lblSANote = New-Object System.Windows.Forms.Label
    $lblSANote.Text = "Optional. Select a Service Account JSON key file to authenticate headless GCS transfers instead of interactive User OAuth."
    $lblSANote.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $lblSANote.ForeColor = if ($Global:AppSettings.IsDarkMode) { [System.Drawing.Color]::LightGray } else { [System.Drawing.Color]::DimGray }
    $lblSANote.Location = New-Object System.Drawing.Point(15, 265); $lblSANote.Size = New-Object System.Drawing.Size(485, 20); $SF.Controls.Add($lblSANote)

    $lblSAKey = New-Object System.Windows.Forms.Label; $lblSAKey.Text = "JSON Key Path:"; $lblSAKey.Location = New-Object System.Drawing.Point(15, 290); $lblSAKey.AutoSize = $true; $SF.Controls.Add($lblSAKey)
    $txtSAKey = New-Object System.Windows.Forms.TextBox; $txtSAKey.Location = New-Object System.Drawing.Point(120, 287); $txtSAKey.Size = New-Object System.Drawing.Size(240, 20); $txtSAKey.Text = $Global:AppSettings.GcsServiceAccountKeyPath; $txtSAKey.BackColor = $TxtTaskName.BackColor; $txtSAKey.ForeColor = $TxtTaskName.ForeColor; $txtSAKey.BorderStyle = "FixedSingle"; $SF.Controls.Add($txtSAKey)
    $btnBrowseSA = New-Object System.Windows.Forms.Button; $btnBrowseSA.Text = "Browse"; $btnBrowseSA.Location = New-Object System.Drawing.Point(365, 285); $btnBrowseSA.Size = New-Object System.Drawing.Size(65, 24); $btnBrowseSA.FlatStyle="Flat"; $btnBrowseSA.FlatAppearance.BorderSize=1; $btnBrowseSA.FlatAppearance.BorderColor=[System.Drawing.Color]::Gray; $btnBrowseSA.BackColor = $BtnSettings.BackColor; $btnBrowseSA.ForeColor = $BtnSettings.ForeColor; $SF.Controls.Add($btnBrowseSA)
    $btnClearSA = New-Object System.Windows.Forms.Button; $btnClearSA.Text = "Clear"; $btnClearSA.Location = New-Object System.Drawing.Point(435, 285); $btnClearSA.Size = New-Object System.Drawing.Size(55, 24); $btnClearSA.FlatStyle="Flat"; $btnClearSA.FlatAppearance.BorderSize=1; $btnClearSA.FlatAppearance.BorderColor=[System.Drawing.Color]::Gray; $btnClearSA.BackColor = $BtnSettings.BackColor; $btnClearSA.ForeColor = $BtnSettings.ForeColor; $SF.Controls.Add($btnClearSA)

    # --- Google Drive API credentials section ---
    $lblDivider = New-Object System.Windows.Forms.Label; $lblDivider.Text = "Google Drive API - Custom OAuth Client (Optional):"; $lblDivider.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold); $lblDivider.Location = New-Object System.Drawing.Point(15, 320); $lblDivider.AutoSize = $true; $SF.Controls.Add($lblDivider)

    $lblDriveNote = New-Object System.Windows.Forms.Label
    $lblDriveNote.Text = "Optional. Leave blank to use rclone's shared built-in credentials. To use a custom Client ID: enter values, click Save & Apply, then click Login/Auth to re-authenticate."
    $lblDriveNote.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $lblDriveNote.ForeColor = if ($Global:AppSettings.IsDarkMode) { [System.Drawing.Color]::LightGray } else { [System.Drawing.Color]::DimGray }
    $lblDriveNote.Location = New-Object System.Drawing.Point(15, 340); $lblDriveNote.Size = New-Object System.Drawing.Size(485, 20); $SF.Controls.Add($lblDriveNote)

    $lblCId = New-Object System.Windows.Forms.Label; $lblCId.Text = "Client ID:"; $lblCId.Location = New-Object System.Drawing.Point(15, 365); $lblCId.AutoSize = $true; $SF.Controls.Add($lblCId)
    $txtCId = New-Object System.Windows.Forms.TextBox; $txtCId.Location = New-Object System.Drawing.Point(120, 362); $txtCId.Size = New-Object System.Drawing.Size(370, 20); $txtCId.Text = $Global:AppSettings.DriveClientId; $txtCId.BackColor = $TxtTaskName.BackColor; $txtCId.ForeColor = $TxtTaskName.ForeColor; $txtCId.BorderStyle = "FixedSingle"; $SF.Controls.Add($txtCId)

    $lblCSec = New-Object System.Windows.Forms.Label; $lblCSec.Text = "Client Secret:"; $lblCSec.Location = New-Object System.Drawing.Point(15, 393); $lblCSec.AutoSize = $true; $SF.Controls.Add($lblCSec)
    $txtCSec = New-Object System.Windows.Forms.TextBox; $txtCSec.Location = New-Object System.Drawing.Point(120, 390); $txtCSec.Size = New-Object System.Drawing.Size(370, 20); $txtCSec.Text = $Global:AppSettings.DriveClientSecret; $txtCSec.BackColor = $TxtTaskName.BackColor; $txtCSec.ForeColor = $TxtTaskName.ForeColor; $txtCSec.BorderStyle = "FixedSingle"; $txtCSec.UseSystemPasswordChar = $true; $SF.Controls.Add($txtCSec)

    $chkShowSec = New-Object System.Windows.Forms.CheckBox; $chkShowSec.Text = "Show Secret"; $chkShowSec.Location = New-Object System.Drawing.Point(120, 415); $chkShowSec.AutoSize = $true; $chkShowSec.ForeColor = if ($Global:AppSettings.IsDarkMode) { [System.Drawing.Color]::LightGray } else { [System.Drawing.Color]::DimGray }; $SF.Controls.Add($chkShowSec)
    $chkShowSec.Add_CheckedChanged({ $txtCSec.UseSystemPasswordChar = -not $chkShowSec.Checked })

    $btnSave = New-Object System.Windows.Forms.Button; $btnSave.Text = "Save & Apply"; $btnSave.Location = New-Object System.Drawing.Point(120, 445); $btnSave.Size = New-Object System.Drawing.Size(120, 30); $btnSave.FlatStyle="Flat"; $btnSave.FlatAppearance.BorderSize=1; $btnSave.FlatAppearance.BorderColor=[System.Drawing.Color]::Gray; $btnSave.BackColor = $BtnSettings.BackColor; $btnSave.ForeColor = $BtnSettings.ForeColor; $SF.Controls.Add($btnSave)
    
    $btnHelp = New-Object System.Windows.Forms.Button; $btnHelp.Text = "Help / Guide"; $btnHelp.Location = New-Object System.Drawing.Point(260, 445); $btnHelp.Size = New-Object System.Drawing.Size(120, 30); $btnHelp.FlatStyle="Flat"; $btnHelp.FlatAppearance.BorderSize=1; $btnHelp.FlatAppearance.BorderColor=[System.Drawing.Color]::Gray; $btnHelp.BackColor = $BtnSettings.BackColor; $btnHelp.ForeColor = $BtnSettings.ForeColor; $SF.Controls.Add($btnHelp)
    
    $btnBR.Add_Click({ $fd = New-Object System.Windows.Forms.OpenFileDialog; $fd.Filter = "Executable (*.exe)|*.exe"; if ($fd.ShowDialog() -eq "OK") { $txtR.Text = $fd.FileName } })
    $btnBG.Add_Click({ $fb = New-Object System.Windows.Forms.FolderBrowserDialog; if ($fb.ShowDialog() -eq "OK") { $txtG.Text = $fb.SelectedPath } })
    $btnBrowseSA.Add_Click({ 
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "JSON Key Files (*.json)|*.json|All Files (*.*)|*.*"
        $ofd.Title = "Select Google Cloud Service Account JSON Key"
        if ($ofd.ShowDialog() -eq "OK") {
            $info = Get-GcsServiceAccountInfo $ofd.FileName
            if ($info) {
                $txtSAKey.Text = $ofd.FileName
            } else {
                [System.Windows.Forms.MessageBox]::Show("The selected file is not a valid Google Cloud Service Account JSON key.", "Invalid Key File", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            }
        }
    })
    $btnClearSA.Add_Click({ $txtSAKey.Text = "" })
    $btnHelp.Add_Click({ [System.Diagnostics.Process]::Start("https://github.com/tonyyang-noaa/nwc-data-transfer-tool-repo/blob/main/USER_GUIDE.md") | Out-Null })
    $btnSave.Add_Click({ 
        $Global:AppSettings.RclonePath = $txtR.Text
        $Global:AppSettings.GCloudPath = $txtG.Text
        $Global:AppSettings.IsDebugMode = $chkDebug.Checked
        $Global:AppSettings.TransferThreads = $cmbT.SelectedItem
        $Global:AppSettings.DriveClientId = $txtCId.Text.Trim()
        $Global:AppSettings.DriveClientSecret = $txtCSec.Text.Trim()
        $Global:AppSettings.ForceRcloneGcs = $chkForceRclone.Checked
        
        $newSaKey = $txtSAKey.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($newSaKey)) {
            if ($Global:AppSettings.GcsAuthType -eq "ServiceAccount") {
                Revoke-GcsServiceAccount
            }
            $Global:AppSettings.GcsServiceAccountKeyPath = ""
        } else {
            if (Test-Path -LiteralPath $newSaKey) {
                $Global:AppSettings.GcsServiceAccountKeyPath = $newSaKey
                Activate-GcsServiceAccount $newSaKey | Out-Null
            }
        }
        
        Save-Settings; Set-RcloneEnvironment; Set-GCloudEnvironment
        [System.Windows.Forms.MessageBox]::Show("Settings saved.", "Settings Saved") | Out-Null; $SF.Close() 
    })
    $SF.ShowDialog() | Out-Null
}

# REFACTORED: Now correctly accepts $IsSrc to map the exact Project ID needed to authenticate restricted buckets
function Get-CloudItems([string]$Prov, [string]$Buc, [string]$Pth, [bool]$DirOnly, [bool]$IsSrc) {
    $parsed = New-Object System.Collections.ArrayList; $seen = @{}
    if ($Prov -eq "GCS") {
        # 1. Primary engine: Rclone lsjson via GCSBridge (direct bucket-level JSON API access, works for Service Accounts and OAuth)
        if ($Global:RcloneExe -and (Test-Path -LiteralPath $Global:TempConfig)) {
            $trimmedPth = $Pth.Trim('/')
            $target = if ([string]::IsNullOrWhiteSpace($trimmedPth)) { "${Global:GcsBridgeName}:${Buc}" } else { "${Global:GcsBridgeName}:${Buc}/${trimmedPth}" }
            $args = "lsjson `"$target`" --config `"$Global:TempConfig`""
            $result = Execute-Cli-Json -cmdArgs $args -isRclone $true
            if ($result) {
                $rArray = if ($result -is [array]) { $result } else { @($result) }
                foreach ($i in $rArray) {
                    $rawDate = if ($i.ModTime) { try { [DateTime]::Parse($i.ModTime) } catch { [DateTime]::MinValue } } else { [DateTime]::MinValue }
                    if ($i.IsDir) {
                        $leaf = "$($i.Name)/"
                        if (-not $seen[$leaf]) {
                            $seen[$leaf] = $true
                            [void]$parsed.Add((New-BrowserListItem -Type 0 -Name $leaf -RawDate $rawDate))
                        }
                    } else {
                        if (-not $DirOnly) {
                            $leaf = $i.Name
                            if ($leaf -ne ".placeholder" -and -not [string]::IsNullOrWhiteSpace($leaf) -and -not $seen[$leaf]) {
                                $seen[$leaf] = $true
                                [void]$parsed.Add((New-BrowserListItem -Type 1 -Name $leaf -RawDate $rawDate))
                            }
                        }
                    }
                }
                return $parsed
            }
        }

        function Normalize-GcsCandidatePath([string]$LineValue) {
            $line = if ($LineValue) { $LineValue.Trim() } else { "" }
            if ([string]::IsNullOrWhiteSpace($line)) { return "" }

            if ($line -match '(?i)^(NAME|UPDATED|SIZE|ETAG|GENERATION|METAGENERATION)$') { return "" }
            if ($line -match '^(ERROR:|WARNING:|Operation\s+failed|AccessDenied|PERMISSION_DENIED|Requester Pays|At line:|\+\s|FullyQualifiedErrorId|CategoryInfo|CommandNotFoundException|Traceback)') { return "" }

            if ($line -match '^gs://') {
                return $line
            }

            if ($line -match '^https?://storage.googleapis.com/([^\s]+)$') {
                return ("gs://{0}" -f $Matches[1])
            }

            # Fallback for tabular object output where only relative object names are printed.
            if ($line -notmatch '^[-=]+$' -and $line -notmatch '^\d{4}-\d{2}-\d{2}\s') {
                $candidate = $line.TrimStart('/')
                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    return ("gs://{0}/{1}" -f $Buc, $candidate)
                }
            }

            return ""
        }

        function Add-GcsPathItem([string]$CandidatePath, [DateTime]$RawDate = [DateTime]::MinValue) {
            $normalizedCandidate = Normalize-GcsCandidatePath $CandidatePath
            if ([string]::IsNullOrWhiteSpace($normalizedCandidate) -or $normalizedCandidate -notmatch '^gs://') { return }

            $bucketPrefix = "gs://$Buc/"
            if ($normalizedCandidate.StartsWith($bucketPrefix)) {
                $clean = $normalizedCandidate.Substring($bucketPrefix.Length)
            } elseif ($normalizedCandidate -eq ("gs://$Buc")) {
                $clean = ""
            } else {
                return
            }
            if ($clean -eq $Pth -or [string]::IsNullOrWhiteSpace($clean)) { return }

            $relativePath = $clean
            if (![string]::IsNullOrEmpty($Pth) -and $relativePath.StartsWith($Pth)) {
                $relativePath = $relativePath.Substring($Pth.Length)
            }
            $relativePath = $relativePath.TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($relativePath)) { return }

            if ($relativePath -match '/') {
                $leaf = ($relativePath -split '/')[0] + "/"
                if (-not $seen[$leaf]) {
                    $seen[$leaf] = $true
                    [void]$parsed.Add((New-BrowserListItem -Type 0 -Name $leaf -RawDate $RawDate))
                }
            } else {
                if ($DirOnly) { return }
                $leaf = $relativePath
                if ($leaf -eq ".placeholder") { return }
                if ([string]::IsNullOrWhiteSpace($leaf)) { return }
                if (-not $seen[$leaf]) {
                    $seen[$leaf] = $true
                    [void]$parsed.Add((New-BrowserListItem -Type 1 -Name $leaf -RawDate $RawDate))
                }
            }
        }

        $Proj = if ($IsSrc) { $Global:CmbSrcProjList.SelectedItem } else { $Global:CmbDstProjList.SelectedItem }
        $projArg = Get-GcsProjectArg $Proj

        $fullUri = "gs://$Buc/$Pth"
        if (-not $fullUri.EndsWith('/')) { $fullUri += '/' }

        $lastGcsDiag = @()
        
        # gcloud storage ls supports only --format=gsutil in some SDK versions, so parse plain output.
        $lsRes = Execute-Cli-Result -cmdArgs (("storage ls `"$fullUri`" {0}" -f $projArg).Trim()) -isRclone $false
        $lastGcsDiag += $lsRes
        if ($lsRes.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($lsRes.Output)) {
            $rawLines = $lsRes.Output -split "`r?`n"
            foreach ($raw in $rawLines) {
                Add-GcsPathItem -CandidatePath $raw.Trim()
            }
        }

        if ($parsed.Count -eq 0) {
            # Secondary fallback using object listing for SDK variants where ls output is sparse.
            $prefixArg = ""
            $trimmedPrefix = $Pth.Trim('/')
            if (-not [string]::IsNullOrWhiteSpace($trimmedPrefix)) {
                $prefixArg = "--prefix=`"$trimmedPrefix/`""
            }

            $objCmd = (("storage objects list `"gs://$Buc`" {0} {1} --format=json(name,updated)" -f $prefixArg, $projArg).Trim())
            $objRes = Execute-Cli-Json -cmdArgs $objCmd -isRclone $false
            if ($objRes) {
                $oArray = if ($objRes -is [array]) { $objRes } else { @($objRes) }
                foreach ($obj in $oArray) {
                    $objName = if ($obj.name) { [string]$obj.name } else { "" }
                    if ([string]::IsNullOrWhiteSpace($objName)) { continue }
                    $updated = if ($obj.updated) { [string]$obj.updated } else { "" }
                    $rawDate = if (-not [string]::IsNullOrWhiteSpace($updated)) { try { [DateTime]::Parse($updated) } catch { [DateTime]::MinValue } } else { [DateTime]::MinValue }

                    Add-GcsPathItem -CandidatePath ("gs://{0}/{1}" -f $Buc, $objName) -RawDate $rawDate
                }
            } else {
                $objListRes = Execute-Cli-Result -cmdArgs (("storage objects list `"gs://$Buc`" {0} {1}" -f $prefixArg, $projArg).Trim()) -isRclone $false
                $lastGcsDiag += $objListRes
                if ($objListRes.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($objListRes.Output)) {
                    foreach ($raw in ($objListRes.Output -split "`r?`n")) {
                        Add-GcsPathItem -CandidatePath $raw.Trim()
                    }
                }
            }
        }

        if ($parsed.Count -eq 0) {
            # Legacy fallback for environments where gcloud storage commands are unavailable.
            $gsutilUri = "gs://$Buc"
            $trimmedPrefix = $Pth.Trim('/')
            if (-not [string]::IsNullOrWhiteSpace($trimmedPrefix)) { $gsutilUri = "gs://$Buc/$trimmedPrefix" }
            if (-not $gsutilUri.EndsWith('/')) { $gsutilUri += '/' }

            $gsRes = Execute-Gsutil-Result -cmdArgs ("ls `"$gsutilUri`"")
            $lastGcsDiag += $gsRes
            if ($gsRes.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($gsRes.Output)) {
                foreach ($raw in ($gsRes.Output -split "`r?`n")) {
                    Add-GcsPathItem -CandidatePath $raw.Trim()
                }
            }

            if ($parsed.Count -eq 0) {
                $gsRecRes = Execute-Gsutil-Result -cmdArgs ("ls -r `"$gsutilUri**`"")
                $lastGcsDiag += $gsRecRes
                if ($gsRecRes.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($gsRecRes.Output)) {
                    foreach ($raw in ($gsRecRes.Output -split "`r?`n")) {
                        Add-GcsPathItem -CandidatePath $raw.Trim()
                    }
                }
            }
        }

        if ($Global:AppSettings.IsDebugMode -and $parsed.Count -eq 0) {
            Log-Message "DEBUG: GCS listing returned no visible entries for $fullUri" "Yellow"
            foreach ($diag in $lastGcsDiag) {
                if ($null -eq $diag) { continue }
                Log-Message ("DEBUG: GCS command exit={0} :: {1}" -f $diag.ExitCode, $diag.Command) "Yellow"
                if (-not [string]::IsNullOrWhiteSpace($diag.Output)) {
                    $preview = ($diag.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 3)
                    foreach ($pLine in $preview) {
                        Log-Message ("DEBUG: {0}" -f $pLine.Trim()) "DarkGray"
                    }
                }
            }
        }
    } elseif ($Prov -eq "GDRIVE") {
        # FIXED: Bind Team Drive ID directly to the connection string to decouple My Drive from Shared Drives
        $target = "${Global:RemoteName}:${Pth}"
        if ($Buc -and $Global:DriveMap.ContainsKey($Buc)) {
            $target = "${Global:RemoteName},team_drive=$($Global:DriveMap[$Buc]):${Pth}"
        }
        
        $args = "lsjson `"$target`" --config `"$Global:TempConfig`" --tpslimit 8 --fast-list --drive-use-trash=false --drive-skip-shortcuts --drive-list-chunk=1000"
        if ($DirOnly) { $args += " --dirs-only" }
        
        $result = Execute-Cli-Json -cmdArgs $args -isRclone $true
        if ($result) { 
            $rArray = if ($result -is [array]) { $result } else { @($result) }
            foreach ($item in $rArray) { 
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
    if (![string]::IsNullOrEmpty($Pth) -or ($Prov -eq "LOCAL" -and ![string]::IsNullOrEmpty($LocP) -and $LocP.Contains("\"))) {
        [void]$Lbx.Items.Add((New-BrowserListItem -Type -1 -Name ".."))
    }

    $rawParsedItems = @()
    if ($Prov -eq "GCS" -or $Prov -eq "GDRIVE") {
        if ($Prov -eq "GCS" -and ([string]::IsNullOrWhiteSpace($Buc) -or $Buc -match "Select Bucket" -or $Buc -match "--- Bucket ---" -or $Buc -match "Type Bucket")) { $Form.Cursor = [System.Windows.Forms.Cursors]::Default; return }
        $LblP.Text = if ($Prov -eq "GCS") { "Path: gs://$Buc/$Pth" } else { "Path: /$Pth" }
        # Ensures $IsSrc is correctly passed downward to identify the billing project
        $rawParsedItems = Get-CloudItems $Prov $Buc $Pth $false $IsSrc
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
        foreach ($pItem in $parsedItems) { [void]$Lbx.Items.Add($pItem) }
    }
    
    if ($IsSrc) {
        $ChkExclusions.Items.Clear()
        if ($Prov -eq "LOCAL") {
            try {
                if (Test-Path -LiteralPath $LocP -ErrorAction Stop) { 
                    $subs = Get-ChildItem $LocP -Force -ErrorAction SilentlyContinue 
                    foreach($d in $subs){ 
                        if (-not (Is-Filtered $d.Name)) {
                            $prefix = if ($d.PSIsContainer) { "[DIR]  " } else { "[FILE] " }
                            [void]$ChkExclusions.Items.Add("$prefix$($d.Name)", $true) 
                        }
                    } 
                }
            } catch {}
        } else {
            $subCloud = Get-CloudItems $Prov $Buc $Pth $false $IsSrc
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
        [void]$LbxSrcDir.Items.Add((New-BrowserListItem -Type -2 -Name "" -DisplayString "--- Storage not loaded (Read-Only Mode) ---"))
        [void]$LbxDstDir.Items.Add((New-BrowserListItem -Type -2 -Name "" -DisplayString "--- Storage not loaded (Read-Only Mode) ---"))
        
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
    if ($Global:SplitSrc) { 
        $idealDist = [math]::Floor(($Global:SplitSrc.Height + 110) / 2)
        if ($idealDist -lt 160) { $idealDist = 160 }
        $Global:SplitSrc.SplitterDistance = $idealDist
    }
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

function Invoke-GlobalSignOut {
    param([string]$Provider)

    if ($Provider -eq "GCS") {
        if ($Global:AppSettings.GcsAuthType -eq "ServiceAccount") {
            $confirm = [System.Windows.Forms.MessageBox]::Show("Clear active Google Cloud Service Account credentials?", "Clear Service Account", "YesNo", "Question")
            if ($confirm -eq "Yes") {
                Revoke-GcsServiceAccount
                [System.Windows.Forms.MessageBox]::Show("Service Account credentials cleared.", "Cleared") | Out-Null
            }
            return
        }
        $confirm = [System.Windows.Forms.MessageBox]::Show("Sign out of Google Cloud Storage? This will wipe your credentials globally so you can switch accounts.", "Sign Out GCS", "YesNo", "Warning")
        if ($confirm -eq "Yes") {
            $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $gcmd = if ($Global:GCloudBin) { Join-Path $Global:GCloudBin "gcloud.cmd" } else { "gcloud.cmd" }
            
            try { 
                $pInfo = New-Object System.Diagnostics.ProcessStartInfo
                $pInfo.FileName = "cmd.exe"
                $pInfo.Arguments = "/c `"`"$gcmd`" auth revoke --all --quiet`""
                $pInfo.UseShellExecute = $false
                $pInfo.CreateNoWindow = $true
                $p = [System.Diagnostics.Process]::Start($pInfo)
                $p.WaitForExit()
            } catch {}
            
            try { 
                $pInfo = New-Object System.Diagnostics.ProcessStartInfo
                $pInfo.FileName = "cmd.exe"
                $pInfo.Arguments = "/c `"`"$gcmd`" auth application-default revoke --quiet`""
                $pInfo.UseShellExecute = $false
                $pInfo.CreateNoWindow = $true
                $p = [System.Diagnostics.Process]::Start($pInfo)
                $p.WaitForExit()
            } catch {}
            
            $adcPath = Join-Path $env:APPDATA "gcloud\application_default_credentials.json"
            if (Test-Path -LiteralPath $adcPath) { Remove-Item -LiteralPath $adcPath -Force -ErrorAction SilentlyContinue }
            try { Remove-Item Env:GOOGLE_APPLICATION_CREDENTIALS -ErrorAction SilentlyContinue } catch {}
            
            # HARD WIPE GCLOUD CACHE
            $gcloudAppData = Join-Path $env:APPDATA "gcloud"
            if (Test-Path -LiteralPath $gcloudAppData) {
                try { Remove-Item -Path "$gcloudAppData\credentials.db" -Force -ErrorAction SilentlyContinue } catch {}
                try { Remove-Item -Path "$gcloudAppData\access_tokens.db" -Force -ErrorAction SilentlyContinue } catch {}
                try { Remove-Item -Path "$gcloudAppData\legacy_credentials" -Recurse -Force -ErrorAction SilentlyContinue } catch {}
            }
            
            $Form.Cursor = [System.Windows.Forms.Cursors]::Default
            [System.Windows.Forms.MessageBox]::Show("GCS credentials successfully cleared! You can now click Login/Auth to sign in with a different account.", "Signed Out") | Out-Null
        }
    } elseif ($Provider -eq "GDRIVE") {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Sign out of Google Drive? This will wipe your rclone auth token.", "Sign Out Google Drive", "YesNo", "Warning")
        if ($confirm -eq "Yes") {
            $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            try { 
                $pInfo = New-Object System.Diagnostics.ProcessStartInfo
                $pInfo.FileName = $Global:RcloneExe
                $pInfo.Arguments = "config delete `"$Global:RemoteName`" --config `"$Global:TempConfig`""
                $pInfo.UseShellExecute = $false
                $pInfo.CreateNoWindow = $true
                $p = [System.Diagnostics.Process]::Start($pInfo)
                $p.WaitForExit()
            } catch {}
            
            # Extra hard wipe for rclone config
            try {
                if (Test-Path -LiteralPath $Global:TempConfig) {
                    $rcloneConfigText = Get-Content -LiteralPath $Global:TempConfig -Raw
                    $newConfigText = $rcloneConfigText -replace '(?ms)\[GWorkspaceAuth\].*?(?=\[|$)', ''
                    $newConfigText | Out-File -LiteralPath $Global:TempConfig -Encoding utf8 -Force
                }
            } catch {}
            
            $Form.Cursor = [System.Windows.Forms.Cursors]::Default
            [System.Windows.Forms.MessageBox]::Show("Google Drive credentials successfully cleared! You can now click Login/Auth to sign in with a different account.", "Signed Out") | Out-Null
        }
    }
}

function Handle-SignOutClick([bool]$IsSrc) {
    $Prov = if($IsSrc){$Global:SrcProvider}else{$Global:DstProvider}
    if ($Prov -notmatch "GCS|GDRIVE") { return }

    Invoke-GlobalSignOut -Provider $Prov

    if ($IsSrc) { $Global:SrcPath = ""; $Global:SrcIsFile = $false } else { $Global:DstPath = "" }
    Handle-ProviderChange $IsSrc
}

function Handle-AuthTypeChange([bool]$IsSrc) {
    $CmbAuth = if($IsSrc){$CmbSrcAuthType}else{$CmbDstAuthType}
    $OtherCmbAuth = if($IsSrc){$CmbDstAuthType}else{$CmbSrcAuthType}
    if ($CmbAuth.SelectedIndex -eq 0) {
        $Global:AppSettings.GcsAuthType = "UserOAuth"
    } else {
        $Global:AppSettings.GcsAuthType = "ServiceAccount"
    }
    if ($OtherCmbAuth.SelectedIndex -ne $CmbAuth.SelectedIndex) {
        $OtherCmbAuth.SelectedIndex = $CmbAuth.SelectedIndex
    }
    Save-Settings
    Set-RcloneEnvironment
    Set-GCloudEnvironment
    Handle-ProviderChange $IsSrc
}
$CmbSrcAuthType.Add_SelectedIndexChanged({ Handle-AuthTypeChange $true })
$CmbDstAuthType.Add_SelectedIndexChanged({ Handle-AuthTypeChange $false })

function Handle-AuthClick([bool]$IsSrc) {
    $Prov = if($IsSrc){$Global:SrcProvider}else{$Global:DstProvider}
    $ProvCmb = if($IsSrc){$CmbSrcProvider}else{$CmbDstProvider}
    
    if ($Prov -eq "GCS") {
        if ($Global:AppSettings.GcsAuthType -eq "ServiceAccount") {
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Filter = "JSON Key Files (*.json)|*.json|All Files (*.*)|*.*"
            $ofd.Title = "Select Google Cloud Service Account JSON Key"
            if ($ofd.ShowDialog() -eq "OK") {
                $info = Get-GcsServiceAccountInfo $ofd.FileName
                if ($info) {
                    $activated = Activate-GcsServiceAccount $ofd.FileName
                    if ($activated) {
                        Handle-ProviderChange $IsSrc
                    } else {
                        [System.Windows.Forms.MessageBox]::Show("Failed to activate Google Cloud Service Account via gcloud.", "Activation Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                    }
                } else {
                    [System.Windows.Forms.MessageBox]::Show("The selected file is not a valid Google Cloud Service Account JSON key.", "Invalid Key File", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                }
            }
            return
        }

        if ($Global:AppSettings.ForceRcloneGcs -and $Global:AppSettings.GcsAuthType -eq "UserOAuth") {
            try {
                $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                try {
                    $pDel = New-Object System.Diagnostics.ProcessStartInfo
                    $pDel.FileName = $Global:RcloneExe
                    $pDel.Arguments = "config delete `"$Global:GcsBridgeName`" --config `"$Global:TempConfig`""
                    $pDel.UseShellExecute = $false; $pDel.CreateNoWindow = $true
                    [System.Diagnostics.Process]::Start($pDel).WaitForExit()
                } catch {}

                $authArgs = "config create `"$Global:GcsBridgeName`" `"google cloud storage`" env_auth=false bucket_policy_only=true --config `"$Global:TempConfig`""
                $pInfo = New-Object System.Diagnostics.ProcessStartInfo
                $pInfo.FileName = $Global:RcloneExe
                $pInfo.Arguments = $authArgs
                $pInfo.UseShellExecute = $false; $pInfo.CreateNoWindow = $false
                $p = [System.Diagnostics.Process]::Start($pInfo)
                $p.WaitForExit()

                if ($p.ExitCode -eq 0) { $ProvCmb.SelectedIndex = 0; $ProvCmb.SelectedIndex = 1 }
            } catch {} finally {
                $Form.Cursor = [System.Windows.Forms.Cursors]::Default
            }
        } else {
            $gcmd = if ($Global:GCloudBin) { Join-Path $Global:GCloudBin "gcloud.cmd" } else { "gcloud.cmd" }
            try {
                $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                $pInfo = New-Object System.Diagnostics.ProcessStartInfo
                $pInfo.FileName = "cmd.exe"
                $pInfo.Arguments = "/c `"`"$gcmd`" auth login`""
                $pInfo.UseShellExecute = $false
                $pInfo.CreateNoWindow = $false
                $p = [System.Diagnostics.Process]::Start($pInfo)
                $p.WaitForExit()
                
                if ($p.ExitCode -eq 0) { 
                    $backupEnv = $env:GOOGLE_APPLICATION_CREDENTIALS
                    $env:GOOGLE_APPLICATION_CREDENTIALS = ""
                    $pInfo2 = New-Object System.Diagnostics.ProcessStartInfo
                    $pInfo2.FileName = "cmd.exe"
                    $pInfo2.Arguments = "/c `"`"$gcmd`" auth application-default login`""
                    $pInfo2.UseShellExecute = $false
                    $pInfo2.CreateNoWindow = $false
                    $p2 = [System.Diagnostics.Process]::Start($pInfo2)
                    $p2.WaitForExit()
                    
                    if ($backupEnv) { $env:GOOGLE_APPLICATION_CREDENTIALS = $backupEnv }
                    Set-GCloudEnvironment
                    $ProvCmb.SelectedIndex = 0; $ProvCmb.SelectedIndex = 1 
                }
            } catch {} finally {
                $Form.Cursor = [System.Windows.Forms.Cursors]::Default
            }
        }
    } else {
        $driveExtraArgs = ""
        if (-not [string]::IsNullOrWhiteSpace($Global:AppSettings.DriveClientId) -and -not [string]::IsNullOrWhiteSpace($Global:AppSettings.DriveClientSecret)) {
            $driveExtraArgs = " client_id=`"$($Global:AppSettings.DriveClientId)`" client_secret=`"$($Global:AppSettings.DriveClientSecret)`""
        }
        try {
            $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

            # Always wipe the existing remote first so config create always runs with
            # the currently saved credentials (built-in or custom Client ID).
            try {
                $pDel = New-Object System.Diagnostics.ProcessStartInfo
                $pDel.FileName = $Global:RcloneExe
                $pDel.Arguments = "config delete `"$Global:RemoteName`" --config `"$Global:TempConfig`""
                $pDel.UseShellExecute = $false
                $pDel.CreateNoWindow = $true
                $proc = [System.Diagnostics.Process]::Start($pDel)
                $proc.WaitForExit()
            } catch {}
            # Also strip any leftover section from the config file directly
            try {
                if (Test-Path -LiteralPath $Global:TempConfig) {
                    $cfg = Get-Content -LiteralPath $Global:TempConfig -Raw
                    $cfg = $cfg -replace '(?ms)\[$([regex]::Escape($Global:RemoteName))\].*?(?=\[|\z)', ''
                    $cfg | Out-File -LiteralPath $Global:TempConfig -Encoding utf8 -Force
                }
            } catch {}

            $authArgs = "config create `"$Global:RemoteName`" drive scope=drive team_drive=`"`"$driveExtraArgs --config `"$Global:TempConfig`""
            $pInfo = New-Object System.Diagnostics.ProcessStartInfo
            $pInfo.FileName = $Global:RcloneExe
            $pInfo.Arguments = $authArgs
            $pInfo.UseShellExecute = $false
            $pInfo.CreateNoWindow = $false
            $p = [System.Diagnostics.Process]::Start($pInfo)
            $p.WaitForExit()

            if ($p.ExitCode -eq 0) { $ProvCmb.SelectedIndex = 0; $ProvCmb.SelectedIndex = 2 }
        } catch {} finally {
            $Form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }
}
$BtnSrcAuth.Add_Click({ Handle-AuthClick $true })
$BtnDstAuth.Add_Click({ Handle-AuthClick $false })

$BtnSrcSignOut.Add_Click({ Handle-SignOutClick $true })
$BtnDstSignOut.Add_Click({ Handle-SignOutClick $false })

function Handle-ProviderChange([bool]$IsSrc) {
    $ProvCmb = if($IsSrc){$CmbSrcProvider}else{$CmbDstProvider}; $ProvList = @("", "GCS", "GDRIVE", "LOCAL"); $Prov = $ProvList[$ProvCmb.SelectedIndex]
    if($IsSrc){$Global:SrcProvider=$Prov; $Global:SrcPath=""; $Global:SrcIsFile=$false}else{$Global:DstProvider=$Prov; $Global:DstPath=""}
    
    $CmbAuth = if($IsSrc){$CmbSrcAuthType}else{$CmbDstAuthType}
    $BtnAuth = if($IsSrc){$BtnSrcAuth}else{$BtnDstAuth}; $LblStat = if($IsSrc){$LblSrcAuthStatus}else{$LblDstAuthStatus}
    $BtnSignOut = if($IsSrc){$BtnSrcSignOut}else{$BtnDstSignOut}
    $CmbProj = if($IsSrc){$CmbSrcProjList}else{$CmbDstProjList}; $CmbBuc = if($IsSrc){$CmbSrcBucList}else{$CmbDstBucList}
    $BtnLoc = if($IsSrc){$BtnSrcLoc}else{$BtnDstLoc}; $Lbx = if($IsSrc){$LbxSrcDir}else{$LbxDstDir}
    
    $Lbx.Items.Clear(); $Lbx.Enabled = $false; $BtnUpload.Enabled = $false
    
    $CmbAuth.Visible = ($Prov -eq "GCS")
    if ($Prov -eq "GCS") {
        $CmbAuth.SelectedIndex = if ($Global:AppSettings.GcsAuthType -eq "ServiceAccount") { 1 } else { 0 }
        $BtnAuth.Location = New-Object System.Drawing.Point(170, 64)
        $BtnAuth.Size = New-Object System.Drawing.Size(85, 25)
        $BtnSignOut.Location = New-Object System.Drawing.Point(170, 64)
        $BtnSignOut.Size = New-Object System.Drawing.Size(85, 25)
        $LblStat.Location = New-Object System.Drawing.Point(260, 68)
        $BtnAuth.Text = if ($Global:AppSettings.GcsAuthType -eq "ServiceAccount") { "Select Key" } else { "Login/Auth" }
        $BtnSignOut.Text = if ($Global:AppSettings.GcsAuthType -eq "ServiceAccount") { "Clear Key" } else { "Sign Out" }
    } else {
        $BtnAuth.Location = New-Object System.Drawing.Point(5, 64)
        $BtnAuth.Size = New-Object System.Drawing.Size(95, 25)
        $BtnSignOut.Location = New-Object System.Drawing.Point(105, 64)
        $BtnSignOut.Size = New-Object System.Drawing.Size(85, 25)
        $LblStat.Location = New-Object System.Drawing.Point(195, 68)
        $BtnAuth.Text = "Login/Auth"
        $BtnSignOut.Text = "Sign Out"
    }

    $CmbProj.Visible=($Prov -eq "GCS" -or $Prov -eq "GDRIVE"); 
    $CmbBuc.Visible=($Prov -eq "GCS") 
    $BtnLoc.Visible=($Prov -eq "LOCAL")
    
    $BtnSignOut.Visible = ($Prov -match "GCS|GDRIVE")
    $BtnSignOut.Enabled = $false
    
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
        if ($Prov -eq "GCS") { 
            $LblStat.Text = if ($Global:AppSettings.GcsAuthType -eq "ServiceAccount") { "Auth (SA)" } else { "Auth (GCS)" }
            $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightGreen" } else { "Green" }
            $BtnSignOut.Enabled = $true
            $BtnAuth.Enabled = $false 
        }
        elseif ($Prov -eq "GDRIVE") { $LblStat.Text = Get-DriveAuthLabel; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightGreen" } else { "Green" }; $BtnSignOut.Enabled = $true; $BtnAuth.Enabled = $false }
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
        $BtnAuth.Enabled = $false; $LblStat.Text = "Checking..."; $LblStat.ForeColor = "Orange"; [System.Windows.Forms.Application]::DoEvents()
        if ($Prov -eq "GCS") {
            if ($Global:AppSettings.GcsAuthType -eq "ServiceAccount") {
                $saKey = $Global:AppSettings.GcsServiceAccountKeyPath
                $saInfo = Get-GcsServiceAccountInfo $saKey
                if ($saInfo -and (Test-Path -LiteralPath $saKey)) {
                    $shortEmail = if ($saInfo.client_email.Length -gt 18) { $saInfo.client_email.Substring(0, 15) + "..." } else { $saInfo.client_email }
                    $LblStat.Text = "Auth (SA: $shortEmail)"; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightGreen" } else { "Green" }
                    $BtnSignOut.Visible = $true
                    $BtnSignOut.Enabled = $true
                    $BtnAuth.Visible = $false
                    $CmbProj.Items.Clear()
                    if ($saInfo.project_id) {
                        [void]$CmbProj.Items.Add($saInfo.project_id)
                    } else {
                        [void]$CmbProj.Items.Add("[ No Project ID (Manual) ]")
                    }
                    $CmbProj.Enabled = $true; $CmbProj.SelectedIndex = 0
                    if (-not $IsSrc -and -not $Global:LoadingHistory) { $BtnDstRef.Enabled = $true }
                } else {
                    $LblStat.Text = "Key Required"; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightCoral" } else { "Red" }
                    $BtnSignOut.Visible = $false
                    $BtnAuth.Visible = $true
                    $BtnAuth.Enabled = $true
                    $CmbProj.Items.Clear(); [void]$CmbProj.Items.Add("[ No Project ID (Manual) ]")
                    $CmbProj.Enabled = $true; $CmbProj.SelectedIndex = 0
                }
            } else {
            $BtnSignOut.Visible = $true
            $BtnAuth.Visible = $true
            
            if ($Global:AppSettings.ForceRcloneGcs) {
                $cfgData = Get-Content -LiteralPath $Global:TempConfig -Raw -ErrorAction SilentlyContinue
                if ($cfgData -and $cfgData -match "(?ms)\[$([regex]::Escape($Global:GcsBridgeName))\].*?token\s*=") {
                    $LblStat.Text = "Auth (Rclone OAuth)"; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightGreen" } else { "Green" }
                    $BtnSignOut.Enabled = $true; $BtnAuth.Enabled = $false
                    $CmbProj.Items.Clear(); [void]$CmbProj.Items.Add("[ No Project ID (Manual) ]")
                    $CmbProj.Enabled = $true; $CmbProj.SelectedIndex = 0 
                    if (-not $IsSrc -and -not $Global:LoadingHistory) { $BtnDstRef.Enabled = $true } 
                } else {
                    $LblStat.Text = "Not Connected"; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightCoral" } else { "Red" }
                    $BtnSignOut.Enabled = $false; $BtnAuth.Enabled = $true
                    $CmbProj.Items.Clear(); [void]$CmbProj.Items.Add("[ No Project ID (Manual) ]")
                    $CmbProj.Enabled = $true; $CmbProj.SelectedIndex = 0 
                }
            } else {
                try { $data = Execute-Cli-Json -cmdArgs "projects list --format=json" -isRclone $false } catch { $data = $null }
                if ($data) { 
                    $LblStat.Text = "Auth (GCS)"; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightGreen" } else { "Green" }
                    $BtnSignOut.Enabled = $true
                    $BtnAuth.Enabled = $false
                    $CmbProj.Items.Clear(); [void]$CmbProj.Items.Add("--- Project ---"); [void]$CmbProj.Items.Add("[ No Project ID (Manual) ]")
                    
                    $dArray = if ($data -is [array]) { $data } else { @($data) }
                    $dArray | Select-Object -ExpandProperty projectId -ErrorAction SilentlyContinue | ForEach-Object { [void]$CmbProj.Items.Add($_) }
                    
                    $CmbProj.Enabled = $true; $CmbProj.SelectedIndex = 0 
                    if (-not $IsSrc -and -not $Global:LoadingHistory) { $BtnDstRef.Enabled = $true } 
                } else { 
                    $LblStat.Text = "Not Connected"; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightCoral" } else { "Red" }
                    $BtnSignOut.Enabled = $false
                    $BtnAuth.Enabled = $true
                    $CmbProj.Items.Clear(); [void]$CmbProj.Items.Add("[ No Project ID (Manual) ]")
                    $CmbProj.Enabled = $true; $CmbProj.SelectedIndex = 0 
                }
            }
        }
        } elseif ($Prov -eq "GDRIVE") {
            try { $d = Execute-Cli-Json -cmdArgs "about `"${Global:RemoteName}:`" --config `"$Global:TempConfig`" --json" -isRclone $true } catch { $d = $null }
            if ($d) { 
                $LblStat.Text = Get-DriveAuthLabel; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightGreen" } else { "Green" }; 
                $BtnSignOut.Enabled = $true
                $BtnAuth.Enabled = $false
                $Lbx.Enabled = $true; 
                if (-not $IsSrc -and -not $Global:LoadingHistory) { $BtnDstNewF.Enabled = $true; $BtnDstRef.Enabled = $true } 
                Update-Directory $IsSrc 
            } else { 
                $LblStat.Text = "Not Connected"; $LblStat.ForeColor = if ($Global:AppSettings.IsDarkMode) { "LightCoral" } else { "Red" }; 
                $BtnAuth.Enabled = $true
                $BtnSignOut.Enabled = $false
            }
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
        # Force manual entry for all GCS buckets
        $CmbBuc.DropDownStyle = "DropDown"
        $CmbBuc.Items.Clear()
        $CmbBuc.Text = "Type Bucket & Press Enter..."
        $CmbBuc.Enabled = $true
        $CmbBuc.Visible = $true
    } elseif ($Prov -eq "GDRIVE") {
        $CmbBuc.DropDownStyle = "DropDownList"
        if($IsSrc){$Global:SrcPath=""}else{$Global:DstPath=""}
        if($CmbProj.SelectedItem -eq "Shared Drive"){
            try { $d = Execute-Cli-Json -cmdArgs "backend drives `"${Global:RemoteName}:`" --config `"$Global:TempConfig`" --json" -isRclone $true } catch { $d = $null }
            $CmbBuc.Items.Clear()
            if ($d) { 
                $dArray = if ($d -is [array]) { $d } else { @($d) }
                foreach($i in $dArray){ [void]$CmbBuc.Items.Add($i.name); $Global:DriveMap[$i.name]=$i.id }
                $CmbBuc.Enabled = $true; $CmbBuc.Visible = $true
                if($CmbBuc.Items.Count -gt 0){ $CmbBuc.SelectedIndex = 0 } 
            }
        } else { 
            $CmbBuc.Items.Clear()
            $CmbBuc.Text = ""
            $CmbBuc.Enabled = $false
            $CmbBuc.Visible = $false
            Update-Directory $IsSrc 
        }
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

    $selType = $null
    $selName = $null
    if ($sel.PSObject -and $sel.PSObject.Properties["Type"] -and $sel.PSObject.Properties["Name"]) {
        $selType = [int]$sel.Type
        $selName = [string]$sel.Name
    }

    if ($selType -eq -1 -or $sel -match "^\.\.\s\[Go\sUp\]") {
        if ($Prov -eq "LOCAL") { 
            $parent = Split-Path $LocP
            if (-not [string]::IsNullOrEmpty($parent)) { $LocP = $parent } 
        } else { 
            $parts = $CPath.TrimEnd('/') -split '/'
            $CPath = if ($parts.Count -le 1) {""} else {($parts[0..($parts.Count-2)] -join '/') + "/"} 
        }
        if ($IsSrc -and $Global:SrcIsFile) { $Global:SrcIsFile = $false }
    } elseif ($selType -eq 0) {
        if ($Prov -eq "LOCAL") { $LocP = Join-Path $LocP $selName.TrimEnd('/') } else { $CPath += $selName }
    } elseif ($selType -eq 1) {
        if ($IsSrc) { $Global:SrcIsFile = $true; if ($Prov -eq "LOCAL") { $LocP = Join-Path $LocP $selName } else { $CPath += $selName } } else { return }
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
    if ($Global:DstProvider -eq "LOCAL" -and $Global:DstLocalPath) { try { New-Item -ItemType Directory -Path (Join-Path $Global:DstLocalPath $fName) -ErrorAction Stop | Out-Null } catch {} }
    elseif ($Global:DstProvider -eq "GCS") {
        $tempPh = Join-Path $Global:AppDir ".placeholder"; if (-not (Test-Path $tempPh)) { try { $null | Out-File -FilePath $tempPh -Encoding utf8 -ErrorAction Stop } catch {} }
        if ($Global:AppSettings.GcsAuthType -eq "ServiceAccount" -and $Global:RcloneExe) {
            $destSub = if ($Global:DstPath) { "$($Global:DstPath.Trim('/'))/$fName/.placeholder" } else { "$fName/.placeholder" }
            $target = "${Global:GcsBridgeName}:$($CmbDstBucList.Text)/$destSub"
            $args = "copyto `"$tempPh`" `"$target`" --config `"$Global:TempConfig`""
            try { [System.Diagnostics.Process]::Start((New-Object System.Diagnostics.ProcessStartInfo -Property @{FileName=$Global:RcloneExe; Arguments=$args; WindowStyle="Hidden"; CreateNoWindow=$true})).WaitForExit() } catch {}
        } else {
            $destUri = if ($Global:DstPath) { "gs://$($CmbDstBucList.Text)/$($Global:DstPath.Trim('/'))/$fName/.placeholder" } else { "gs://$($CmbDstBucList.Text)/$fName/.placeholder" }
            $gcloudToolPath = if ($Global:GCloudBin) { Join-Path $Global:GCloudBin "gcloud.cmd" } else { "gcloud.cmd" }
            
            $projArg = ""
            if (-not [string]::IsNullOrWhiteSpace($CmbDstProjList.SelectedItem) -and $CmbDstProjList.SelectedItem -notmatch "No Project") {
                $projArg = " --project=`"$($CmbDstProjList.SelectedItem)`""
            }
            
            try { [System.Diagnostics.Process]::Start((New-Object System.Diagnostics.ProcessStartInfo -Property @{FileName="cmd.exe"; Arguments="/c `"`"$gcloudToolPath`" storage cp `"$tempPh`" `"$destUri`"$projArg`""; WindowStyle="Hidden"; CreateNoWindow=$true})).WaitForExit() } catch {}
        }
    } elseif ($Global:DstProvider -eq "GDRIVE") {
        $target = "${Global:RemoteName}:${Global:DstPath}$fName"
        if ($CmbDstProjList.SelectedItem -eq "Shared Drive" -and $Global:DriveMap.ContainsKey($CmbDstBucList.Text)) {
            $target = "${Global:RemoteName},team_drive=$($Global:DriveMap[$CmbDstBucList.Text]):${Global:DstPath}$fName"
        }
        $args = "mkdir `"$target`" --config `"$Global:TempConfig`""
        try { [System.Diagnostics.Process]::Start((New-Object System.Diagnostics.ProcessStartInfo -Property @{FileName=$Global:RcloneExe; Arguments=$args; WindowStyle="Hidden"; CreateNoWindow=$true})).WaitForExit() } catch {}
    }
    $Form.Cursor = [System.Windows.Forms.Cursors]::Default; Update-Directory $false
})

# --- 5. ENGINE REWRITE (UNIFIED TARGETED ITERATION) ---

$BtnUpload.Add_Click({
    if ($Global:SrcProvider -eq "LOCAL" -and -not $Global:SrcLocalPath) { Log-Message "Source Local path not selected." "LightCoral"; return }
    if ($Global:DstProvider -eq "LOCAL" -and -not $Global:DstLocalPath) { Log-Message "Target Local path not selected." "LightCoral"; return }
    
    if ($Global:SrcProvider -eq "GCS") {
        $sBuc = $CmbSrcBucList.Text
        if ([string]::IsNullOrWhiteSpace($sBuc) -or $sBuc -match "--- Bucket ---" -or $sBuc -match "Type Bucket") { Log-Message "Source Bucket not selected." "LightCoral"; return }
    }
    
    if ($Global:DstProvider -eq "GCS") {
        $dBuc = $CmbDstBucList.Text
        if ([string]::IsNullOrWhiteSpace($dBuc) -or $dBuc -match "--- Bucket ---" -or $dBuc -match "Type Bucket") { Log-Message "Target Bucket not selected." "LightCoral"; return }
    }

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
    

    
    $BtnNewTask.Enabled = $false; $BtnDelTask.Enabled = $false; $BtnClearAll.Enabled = $false; $BtnDuplicate.Enabled = $false
    $BtnSrcLoc.Enabled = $false; $BtnSrcFilter.Enabled = $false; $BtnDstLoc.Enabled = $false; $BtnDstNewF.Enabled = $false; $BtnDstRef.Enabled = $false
    $BtnUpload.Enabled = $false; $BtnCheckAll.Enabled = $false; $BtnUncheckAll.Enabled = $false
    
    $RtbLog.Enabled = $true; $BtnStop.Enabled = $true; $Global:StopTransfer = $false
    
    if (-not $existing -or [string]::IsNullOrWhiteSpace($RtbLog.Text)) {
        $RtbLog.Clear()
    } else {
        Log-Message "`n=========================================================" "Yellow"
        $runType = if ($existing.Status -eq "Completed") { "RESTARTING" } else { "RESUMING" }
        Log-Message "  $runType TRANSFER TASK: $(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')" "Yellow"
        Log-Message "=========================================================" "Yellow"
    }

    Log-Message "--- TRANSFER STARTED ---" "Cyan"
    [System.Windows.Forms.Application]::DoEvents() 

   $UseGCloud = (-not $Global:AppSettings.ForceRcloneGcs) -and ($Global:AppSettings.GcsAuthType -ne "ServiceAccount") -and (
              ($Global:SrcProvider -eq "LOCAL" -and $Global:DstProvider -eq "GCS") -or 
              ($Global:SrcProvider -eq "GCS" -and $Global:DstProvider -eq "LOCAL") -or 
              ($Global:SrcProvider -eq "GCS" -and $Global:DstProvider -eq "GCS"))

    if (($Global:SrcProvider -eq "GCS" -or $Global:DstProvider -eq "GCS") -and -not $UseGCloud) {
        if ($Global:AppSettings.GcsAuthType -eq "ServiceAccount" -and -not [string]::IsNullOrWhiteSpace($Global:AppSettings.GcsServiceAccountKeyPath) -and (Test-Path -LiteralPath $Global:AppSettings.GcsServiceAccountKeyPath)) {
            $env:GOOGLE_APPLICATION_CREDENTIALS = $Global:AppSettings.GcsServiceAccountKeyPath
        } else {
            $adcPath = Join-Path $env:APPDATA "gcloud\application_default_credentials.json"
            try {
                if (-not (Test-Path $adcPath -ErrorAction Stop)) {
                    Log-Message "Missing Application Default Credentials for cross-Cloud connection. Requesting..." "Yellow"
                    $gcloudToolPath = if ($Global:GCloudBin) { Join-Path $Global:GCloudBin "gcloud.cmd" } else { "gcloud.cmd" }
                    try {
                        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
                        $pInfo.FileName = "cmd.exe"
                        $pInfo.Arguments = "/c `"`"$gcloudToolPath`" auth application-default login`""
                        $pInfo.UseShellExecute = $false
                        $pInfo.CreateNoWindow = $false
                        $p = [System.Diagnostics.Process]::Start($pInfo)
                        $p.WaitForExit()
                        
                        if ($p.ExitCode -ne 0 -or -not (Test-Path $adcPath -ErrorAction Stop)) {
                            Log-Message "Failed to acquire ADC credentials. Rclone requires this to bridge to GCS. Transfer aborted." "LightCoral"
                            $Global:StopTransfer = $true
                        }
                    } catch {
                        Log-Message "Failed to launch gcloud to acquire ADC credentials. Transfer aborted." "LightCoral"
                        $Global:StopTransfer = $true
                    }
                }
                if (Test-Path $adcPath -ErrorAction Stop) { $env:GOOGLE_APPLICATION_CREDENTIALS = $adcPath }
            } catch {}
        }
    }

    if ($Global:StopTransfer -eq $false) {

        # --- AUTO-CLEANUP FIX: Prevent GCS 404 tracking errors ---
        try {
            $trackerBases = @(
                (Join-Path $env:APPDATA "gcloud\storage"),
                (Join-Path $env:APPDATA "gcloud\surface_data\storage"),
                (Join-Path $env:USERPROFILE ".gsutil")
            )
            $targetFolders = @("tracker-files", "tracker_files", "rsync", "parallel_composite_uploads")
            
            foreach ($base in $trackerBases) {
                if (Test-Path -LiteralPath $base) {
                    foreach ($folder in $targetFolders) {
                        $targetDir = Join-Path $base $folder
                        if (Test-Path -LiteralPath $targetDir) {
                            Remove-Item -LiteralPath $targetDir -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            }
        } catch {}
        # ---------------------------------------------------------
        
        $singleCheckedItem = ""
        if ($selCount -eq 1 -and $totCount -gt 0) {
            $singleCheckedItem = $incItems[0].Name
        }
        
        $srcFileLeaf = Get-SourceLeafName
        $srcName = if ($Global:SrcIsFile) { $srcFileLeaf } elseif ($singleCheckedItem -ne "") { $singleCheckedItem } elseif ($selCount -gt 1) { "Multiple Items ($selCount)" } elseif ($Global:SrcPath) { ($Global:SrcPath.TrimEnd('/') -split '/')[-1] } else { "Root Directory" }
        $displayName = if ($srcName.Length -gt 25) { $srcName.Substring(0, 22) + "..." } else { $srcName }
        
        $transferStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $Global:TransferSpeed = "N/A"

        $PrgTotal.Maximum = 100; $PrgTotal.Value = 0; $PrgTotal.Style = "Marquee"

        $Global:RunLogFile = [System.IO.Path]::GetFullPath((Join-Path $env:TEMP "transfer_run_$([guid]::NewGuid().ToString('N')).log"))
        try { if (Test-Path -LiteralPath $Global:RunLogFile -ErrorAction Stop) { Remove-Item -LiteralPath $Global:RunLogFile -Force -ErrorAction Stop } } catch {}
        try { $null | Out-File -LiteralPath $Global:RunLogFile -Encoding utf8 -ErrorAction Stop } catch {}
        $Global:FullLogLines = New-Object System.Collections.ArrayList
        $lastTransferSpeed = ""

        if ($Global:SrcProvider -eq "LOCAL") { $rSrcBase = $Global:SrcLocalPath }
        elseif ($Global:SrcProvider -eq "GCS") { $rSrcBase = "${Global:GcsBridgeName}:$($CmbSrcBucList.Text)/$Global:SrcPath" }
        elseif ($Global:SrcProvider -eq "GDRIVE" -and $CmbSrcProjList.SelectedItem -eq "Shared Drive" -and $Global:DriveMap.ContainsKey($CmbSrcBucList.Text)) { $rSrcBase = "${Global:RemoteName},team_drive=$($Global:DriveMap[$CmbSrcBucList.Text]):$Global:SrcPath" }
        else { $rSrcBase = "${Global:RemoteName}:${Global:SrcPath}" }

        if ($Global:DstProvider -eq "LOCAL") { $rDstBase = $Global:DstLocalPath }
        elseif ($Global:DstProvider -eq "GCS") { $rDstBase = "${Global:GcsBridgeName}:$($CmbDstBucList.Text)/$Global:DstPath" }
        elseif ($Global:DstProvider -eq "GDRIVE" -and $CmbDstProjList.SelectedItem -eq "Shared Drive" -and $Global:DriveMap.ContainsKey($CmbDstBucList.Text)) { $rDstBase = "${Global:RemoteName},team_drive=$($Global:DriveMap[$CmbDstBucList.Text]):$Global:DstPath" }
        else { $rDstBase = "${Global:RemoteName}:${Global:DstPath}" }
        
        $rSrcBase = $rSrcBase -replace '(?<!:)/{2,}', '/'
        $rDstBase = $rDstBase -replace '(?<!:)/{2,}', '/'

        $gSrcBase = if($Global:SrcProvider -eq "GCS"){"gs://$($CmbSrcBucList.Text)/$($Global:SrcPath.Trim('/'))"}else{$Global:SrcLocalPath}
        $gDstBase = if($Global:DstProvider -eq "GCS"){"gs://$($CmbDstBucList.Text)/$($Global:DstPath.Trim('/'))"}else{$Global:DstLocalPath}
        $gSrcBase = $gSrcBase -replace '(?<!gs:)/{2,}', '/'
        $gDstBase = $gDstBase -replace '(?<!gs:)/{2,}', '/'

        $Global:TotalTransferItems = 0
        $LblFolderCount.Text = "Item(s): Calculating transfer size..."
        $LblProgress.Text = "Progress ($displayName): Calculating..."
        if ($Global:AppSettings.IsDebugMode) { Log-Message "DEBUG: Starting targeted pre-flight file count..." "Yellow" }
        [System.Windows.Forms.Application]::DoEvents()
        
        if ($Global:SrcProvider -eq "LOCAL" -and (Test-Path -LiteralPath $gSrcBase)) {
            try {
                if ($incItems.Count -gt 0 -and $totCount -gt 0) {
                    foreach ($incObj in $incItems) {
                        $tPath = Join-Path $gSrcBase $incObj.Name
                        if ($Global:AppSettings.IsDebugMode) { Log-Message "DEBUG: Scanning inclusion path: $tPath" "DarkGray" }
                        if (-not $incObj.IsDir -and (Test-Path -LiteralPath $tPath -PathType Leaf)) { 
                            $Global:TotalTransferItems++ 
                        } elseif ($incObj.IsDir -and (Test-Path -LiteralPath $tPath -PathType Container)) {
                            $Global:TotalTransferItems += @(Get-ChildItem -LiteralPath $tPath -File -Recurse -Force -ErrorAction SilentlyContinue).Count
                        }
                        [System.Windows.Forms.Application]::DoEvents()
                    }
                } else {
                    if ($Global:AppSettings.IsDebugMode) { Log-Message "DEBUG: Scanning root directory: $gSrcBase" "DarkGray" }
                    if (Test-Path -LiteralPath $gSrcBase -PathType Leaf) { $Global:TotalTransferItems = 1 }
                    else { $Global:TotalTransferItems += @(Get-ChildItem -LiteralPath $gSrcBase -File -Recurse -Force -ErrorAction SilentlyContinue).Count }
                }
            } catch { $Global:TotalTransferItems = -1 }
        } elseif ($Global:SrcProvider -eq "GCS") {
            try {
                if (($Global:AppSettings.GcsAuthType -eq "ServiceAccount" -or $Global:AppSettings.ForceRcloneGcs) -and $Global:RcloneExe) {
                    if ($incItems.Count -gt 0 -and $totCount -gt 0) {
                        foreach ($incObj in $incItems) {
                            $rSub = if ($Global:SrcPath) { "$($Global:SrcPath.Trim('/'))/$($incObj.Name)" } else { $incObj.Name }
                            $szRes = Execute-Cli-Json -cmdArgs "size `"${Global:GcsBridgeName}:$($CmbSrcBucList.Text)/$rSub`" --json --config `"$Global:TempConfig`"" -isRclone $true
                            if ($szRes -and $szRes.count -ne $null) {
                                $Global:TotalTransferItems += [int]$szRes.count
                            }
                            [System.Windows.Forms.Application]::DoEvents()
                        }
                    } else {
                        $rSub = if ($Global:SrcPath) { $Global:SrcPath.Trim('/') } else { "" }
                        $szRes = Execute-Cli-Json -cmdArgs "size `"${Global:GcsBridgeName}:$($CmbSrcBucList.Text)/$rSub`" --json --config `"$Global:TempConfig`"" -isRclone $true
                        if ($szRes -and $szRes.count -ne $null) {
                            $Global:TotalTransferItems += [int]$szRes.count
                        }
                    }
                } else {
                    $gcloudToolPath = if ($Global:GCloudBin) { Join-Path $Global:GCloudBin "gcloud.cmd" } else { "gcloud.cmd" }
                    
                    $projArg = ""
                    if (-not [string]::IsNullOrWhiteSpace($CmbSrcProjList.SelectedItem) -and $CmbSrcProjList.SelectedItem -notmatch "No Project") {
                        $projArg = "--project=`"$($CmbSrcProjList.SelectedItem)`" "
                    }
                    
                    if ($incItems.Count -gt 0 -and $totCount -gt 0) {
                        foreach ($incObj in $incItems) {
                            $sTarget = "$gSrcBase/$($incObj.Name)" -replace '(?<!gs:)/{2,}', '/'
                            if ($incObj.IsDir) { $lsArgs = "storage ls `"$sTarget/**`" $projArg" } else { $lsArgs = "storage ls `"$sTarget`" $projArg" }
                            if ($Global:AppSettings.IsDebugMode) { Log-Message "DEBUG: Scanning cloud path via: $lsArgs" "DarkGray" }
                            
                            $pInfoLs = New-Object System.Diagnostics.ProcessStartInfo
                            $pInfoLs.FileName = "cmd.exe"
                            $pInfoLs.Arguments = "/c `"cd /d `"$env:TEMP`" && call `"$gcloudToolPath`" $lsArgs`""
                            $pInfoLs.RedirectStandardOutput = $true
                            $pInfoLs.UseShellExecute = $false
                            $pInfoLs.CreateNoWindow = $true
                            $pInfoLs.WorkingDirectory = $env:TEMP
                            $pLs = [System.Diagnostics.Process]::Start($pInfoLs)
                            $lsOut = $pLs.StandardOutput.ReadToEnd()
                            $pLs.WaitForExit()
                            $Global:TotalTransferItems += ($lsOut -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -match "^gs://" -and $_ -notmatch "/$" }).Count
                            [System.Windows.Forms.Application]::DoEvents()
                        }
                    } else {
                        $sTarget = if ($gSrcBase.EndsWith('/')) { $gSrcBase } else { $gSrcBase + '/' }
                        $lsArgs = "storage ls `"$sTarget**`" $projArg"
                        if ($Global:AppSettings.IsDebugMode) { Log-Message "DEBUG: Scanning cloud root via: $lsArgs" "DarkGray" }
                        
                        $pInfoLs = New-Object System.Diagnostics.ProcessStartInfo
                        $pInfoLs.FileName = "cmd.exe"
                        $pInfoLs.Arguments = "/c `"call `"$gcloudToolPath`" $lsArgs`""
                        $pInfoLs.RedirectStandardOutput = $true
                        $pInfoLs.UseShellExecute = $false
                        $pInfoLs.CreateNoWindow = $true
                        $pLs = [System.Diagnostics.Process]::Start($pInfoLs)
                        $lsOut = $pLs.StandardOutput.ReadToEnd()
                        $pLs.WaitForExit()
                        $Global:TotalTransferItems += ($lsOut -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -match "^gs://" -and $_ -notmatch "/$" }).Count
                    }
                }
            } catch { $Global:TotalTransferItems = -1 }
        } else {
            $Global:TotalTransferItems = -1 
        }

        if ($Global:AppSettings.IsDebugMode) { Log-Message "DEBUG: Pre-flight count complete. Found $($Global:TotalTransferItems) items." "Yellow" }
        [System.Windows.Forms.Application]::DoEvents()

        $Global:BatFile = Join-Path $env:TEMP "run_transfer_$taskId.bat"
        $batContent = "@echo off`ncd /d `"$env:TEMP`"`nchcp 65001 >nul`n"
        
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
                try { [System.IO.File]::WriteAllLines($Global:ExcludeFile, $excludeLines.ToArray(), (New-Object System.Text.UTF8Encoding $false)) } catch {}
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
                    
                    $gcloudToolPath = if ($Global:GCloudBin) { Join-Path $Global:GCloudBin "gcloud.cmd" } else { "gcloud.cmd" }
                    $gCmdBase = "call `"$gcloudToolPath`""
                    
                    if ($incObj.IsDir) {
                        if ($Global:SrcProvider -eq "LOCAL") {
                            try {
                                if (Test-Path -LiteralPath $srcTargetSafe -ErrorAction Stop) {
                                    $allDirs = Get-ChildItem -LiteralPath $srcTargetSafe -Recurse -Directory -Force -ErrorAction SilentlyContinue
                                    foreach ($dir in $allDirs) {
                                        $items = Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
                                        if ($null -eq $items -or $items.Count -eq 0) { $null | Out-File -FilePath (Join-Path $dir.FullName ".placeholder") -Encoding utf8 }
                                    }
                                    $rootItems = Get-ChildItem -LiteralPath $srcTargetSafe -Force -ErrorAction SilentlyContinue
                                    if ($null -eq $rootItems -or $rootItems.Count -eq 0) { $null | Out-File -FilePath (Join-Path $srcTargetSafe ".placeholder") -Encoding utf8 }
                                }
                            } catch {}
                        }
                        
                        $gArgs = "storage rsync `"$srcTargetSafe`" `"$dstTargetSafe`" --recursive"
                        
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
                            $gArgs += " -x `"$regex`""
                        }
                    } else {
                        $gArgs = "storage cp `"$srcTargetSafe`" `"$dstTargetSafe`""
                    }
                    
                    $projArg = ""
                    if ($Global:SrcProvider -eq "GCS" -and -not [string]::IsNullOrWhiteSpace($CmbSrcProjList.SelectedItem) -and $CmbSrcProjList.SelectedItem -notmatch "No Project") {
                        $projArg = " --project=`"$($CmbSrcProjList.SelectedItem)`""
                    } elseif ($Global:DstProvider -eq "GCS" -and -not [string]::IsNullOrWhiteSpace($CmbDstProjList.SelectedItem) -and $CmbDstProjList.SelectedItem -notmatch "No Project") {
                        $projArg = " --project=`"$($CmbDstProjList.SelectedItem)`""
                    }
                    $gArgs += $projArg
                    
                    if ($Global:AppSettings.IsDebugMode) { $gArgs += " --verbosity=debug" }
                    
                    $gArgs = $gArgs -replace '%', '%%'
                    if ($env:CLOUDSDK_PYTHON) { $batContent += "set CLOUDSDK_PYTHON=$env:CLOUDSDK_PYTHON`n" }
                    $batContent += "$gCmdBase $gArgs >> `"$Global:RunLogFile`" 2>&1`n"
                    
                } else {
                    $srcTarget = if ($Global:SrcProvider -eq "LOCAL") { Join-Path $rSrcBase $incName } else { "$rSrcBase/$incName" -replace '(?<!:)/{2,}', '/' }
                    $dstTarget = if ($Global:DstProvider -eq "LOCAL") { Join-Path $rDstBase $incName } else { "$rDstBase/$incName" -replace '(?<!:)/{2,}', '/' }
                    
                    $srcTargetSafe = if ($Global:SrcProvider -eq "LOCAL" -and $srcTarget.EndsWith('\')) { $srcTarget + '\' } else { $srcTarget }
                    $dstTargetSafe = if ($Global:DstProvider -eq "LOCAL" -and $dstTarget.EndsWith('\')) { $dstTarget + '\' } else { $dstTarget }

                    $tThreads = $Global:AppSettings.TransferThreads
                    
                    if ($incObj.IsDir) {
                        $rcloneArgs = @("copy", "`"$srcTargetSafe`"", "`"$dstTargetSafe`"", "--create-empty-src-dirs", "-v", "--stats", "3s", "--config", "`"$Global:TempConfig`"", "--retries", "3", "--low-level-retries", "3", "--contimeout", "30s", "--tpslimit", "$tThreads", "--checkers", "$tThreads", "--transfers", "$tThreads", "--drive-pacer-min-sleep", "50ms")
                    } else {
                        $rcloneArgs = @("copyto", "`"$srcTargetSafe`"", "`"$dstTargetSafe`"", "-v", "--stats", "3s", "--config", "`"$Global:TempConfig`"", "--retries", "3", "--low-level-retries", "3", "--contimeout", "30s", "--tpslimit", "$tThreads", "--checkers", "$tThreads", "--transfers", "$tThreads", "--drive-pacer-min-sleep", "50ms")
                    }
                    
                    $gcsProj = if ($Global:SrcProvider -eq "GCS") { $CmbSrcProjList.SelectedItem } elseif ($Global:DstProvider -eq "GCS") { $CmbDstProjList.SelectedItem } else { "" }
                    if ($gcsProj -and $gcsProj -notmatch "No Project") { $rcloneArgs += "--gcs-project-number=`"$gcsProj`"" }
                    if ($Global:SrcProvider -eq "GCS" -or $Global:DstProvider -eq "GCS") { $rcloneArgs += "--gcs-bucket-policy-only" }
                    
                    if ($Global:ExcludeFile -and $incObj.IsDir) {
                        $rcloneArgs += "--exclude-from"
                        $rcloneArgs += "`"$Global:ExcludeFile`""
                    }

                    $batContent += "`"$Global:RcloneExe`" " + [string]::Join(' ', $rcloneArgs) + " >> `"$Global:RunLogFile`" 2>&1`n"
                }
            }
        } else {
            
            if ($UseGCloud) {
                $srcTargetSafe = if ($Global:SrcProvider -eq "LOCAL" -and $gSrcBase.EndsWith('\')) { $gSrcBase + '\' } else { $gSrcBase }
                $dstTargetSafe = if ($Global:DstProvider -eq "LOCAL" -and $gDstBase.EndsWith('\')) { $gDstBase + '\' } else { $gDstBase }
                
                $gcloudToolPath = if ($Global:GCloudBin) { Join-Path $Global:GCloudBin "gcloud.cmd" } else { "gcloud.cmd" }
                $gCmdBase = "call `"$gcloudToolPath`""
                
                if ($Global:SrcProvider -eq "LOCAL" -and (-not $Global:SrcIsFile)) {
                    try {
                        if (Test-Path -LiteralPath $srcTargetSafe -ErrorAction Stop) {
                            $allDirs = Get-ChildItem -LiteralPath $srcTargetSafe -Recurse -Directory -Force -ErrorAction SilentlyContinue
                            foreach ($dir in $allDirs) {
                                $items = Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
                                if ($null -eq $items -or $items.Count -eq 0) { $null | Out-File -FilePath (Join-Path $dir.FullName ".placeholder") -Encoding utf8 }
                            }
                            $rootItems = Get-ChildItem -LiteralPath $srcTargetSafe -Force -ErrorAction SilentlyContinue
                            if ($null -eq $rootItems -or $rootItems.Count -eq 0) { $null | Out-File -FilePath (Join-Path $srcTargetSafe ".placeholder") -Encoding utf8 }
                        }
                    } catch {}
                }
                
                if ($Global:SrcIsFile) {
                    $gArgs = "storage cp `"$srcTargetSafe`" `"$dstTargetSafe`""
                } else {
                    $gArgs = "storage rsync `"$srcTargetSafe`" `"$dstTargetSafe`" --recursive"
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
                        $gArgs += " -x `"$regex`""
                    }
                }
                
                $projArg = ""
                if ($Global:SrcProvider -eq "GCS" -and -not [string]::IsNullOrWhiteSpace($CmbSrcProjList.SelectedItem) -and $CmbSrcProjList.SelectedItem -notmatch "No Project") {
                    $projArg = " --project=`"$($CmbSrcProjList.SelectedItem)`""
                } elseif ($Global:DstProvider -eq "GCS" -and -not [string]::IsNullOrWhiteSpace($CmbDstProjList.SelectedItem) -and $CmbDstProjList.SelectedItem -notmatch "No Project") {
                    $projArg = " --project=`"$($CmbDstProjList.SelectedItem)`""
                }
                $gArgs += $projArg

                if ($Global:AppSettings.IsDebugMode) { $gArgs += " --verbosity=debug" }
                
                $gArgs = $gArgs -replace '%', '%%'
                if ($env:CLOUDSDK_PYTHON) { $batContent += "set CLOUDSDK_PYTHON=$env:CLOUDSDK_PYTHON`n" }
                $batContent += "$gCmdBase $gArgs >> `"$Global:RunLogFile`" 2>&1`n"
            } else {
                $rDst = $rDstBase
                if ($srcName -and $srcName -ne "Root Directory" -and $srcName -notmatch "Multiple Items") {
                    $rDst = if ($Global:DstProvider -eq "LOCAL") { Join-Path $rDstBase $srcName } else { "$rDstBase/$srcName" -replace '(?<!:)/{2,}', '/' }
                }
                $srcTargetSafe = if ($Global:SrcProvider -eq "LOCAL" -and $rSrcBase.EndsWith('\')) { $rSrcBase + '\' } else { $rSrcBase }
                $dstTargetSafe = if ($Global:DstProvider -eq "LOCAL" -and $rDst.EndsWith('\')) { $rDst + '\' } else { $rDst }
                
                $rLogLevel = if ($Global:AppSettings.IsDebugMode) { "DEBUG" } else { "INFO" }
                $tThreads = $Global:AppSettings.TransferThreads
                
                if ($Global:SrcIsFile) {
                    $rcloneArgs = @("copyto", "`"$srcTargetSafe`"", "`"$dstTargetSafe`"", "-v", "--stats", "3s", "--config", "`"$Global:TempConfig`"", "--retries", "3", "--low-level-retries", "3", "--contimeout", "30s", "--tpslimit", "$tThreads", "--checkers", "$tThreads", "--transfers", "$tThreads", "--drive-pacer-min-sleep", "50ms")
                } else {
                    $rcloneArgs = @("copy", "`"$srcTargetSafe`"", "`"$dstTargetSafe`"", "--create-empty-src-dirs", "-v", "--stats", "3s", "--config", "`"$Global:TempConfig`"", "--retries", "3", "--low-level-retries", "3", "--contimeout", "30s", "--tpslimit", "$tThreads", "--checkers", "$tThreads", "--transfers", "$tThreads", "--drive-pacer-min-sleep", "50ms")
                }
                
                $gcsProj = if ($Global:SrcProvider -eq "GCS") { $CmbSrcProjList.SelectedItem } elseif ($Global:DstProvider -eq "GCS") { $CmbDstProjList.SelectedItem } else { "" }
                if ($gcsProj -and $gcsProj -notmatch "No Project") { $rcloneArgs += "--gcs-project-number=`"$gcsProj`"" }
                if ($Global:SrcProvider -eq "GCS" -or $Global:DstProvider -eq "GCS") { $rcloneArgs += "--gcs-bucket-policy-only" }
                
                if ($Global:ExcludeFile -and -not $Global:SrcIsFile) {
                    $rcloneArgs += "--exclude-from"
                    $rcloneArgs += "`"$Global:ExcludeFile`""
                }

                $batContent += "`"$Global:RcloneExe`" " + [string]::Join(' ', $rcloneArgs) + " >> `"$Global:RunLogFile`" 2>&1`n"
            }
        }

        try { [System.IO.File]::WriteAllText($Global:BatFile, $batContent, (New-Object System.Text.UTF8Encoding $false)) } catch {}

        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName = "cmd.exe"
        $pInfo.Arguments = "/c `"$Global:BatFile`""
        $pInfo.UseShellExecute = $false
        $pInfo.CreateNoWindow = $true
        
        $Global:CurrentProcess = New-Object System.Diagnostics.Process; $Global:CurrentProcess.StartInfo = $pInfo; 
        $Global:CurrentProcess.Start() | Out-Null
        
        $lastSize = 0
        [int]$RegCopied = 0; [int]$RegFailed = 0; [bool]$QuotaReached = $false; [bool]$ProcessFailed = $false
        
        while (-not $Global:CurrentProcess.HasExited) { 
            
            $fileInfo = Get-Item -LiteralPath $Global:RunLogFile -ErrorAction SilentlyContinue
            if ($fileInfo -and $fileInfo.Length -gt $lastSize) {
                try {
                    $fs = New-Object System.IO.FileStream($Global:RunLogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    $fs.Seek($lastSize, [System.IO.SeekOrigin]::Begin) | Out-Null
                    $sr = New-Object System.IO.StreamReader($fs)
                    
                    while (-not $sr.EndOfStream) {
                        $line = $sr.ReadLine()
                        if (-not [string]::IsNullOrWhiteSpace($line)) {
                            $l = $line.Trim()

                            $isUpdate = $false

                            if ($l -match "(?i)userRateLimitExceeded|upload limit error|quota exceeded|RATE_LIMIT_EXCEEDED|rateLimitExceeded") {
                                if (-not $QuotaReached) { Log-Message "QUOTA LIMIT REACHED. Transfer safely stopped." "Yellow"; $QuotaReached = $true; $Global:StopTransfer = $true; try { Start-Process "taskkill.exe" -ArgumentList "/PID $($Global:CurrentProcess.Id) /T /F" -WindowStyle Hidden -Wait } catch {} }
                            }

                            if ($l -match 'Transferred:.*?,\s*(\d{1,3})%,\s*([\d\.]+\s*[kKMGT]?i?B/s)') {
                                $lastTransferSpeed = $Matches[2]
                                if ($Global:TotalTransferItems -le 0) {
                                    $pct = [int]$Matches[1]
                                    $Global:TransferSpeed = $lastTransferSpeed
                                    if ($pct -ge 0 -and $pct -le 100) {
                                        $PrgTotal.Style = "Continuous"
                                        if ($pct -lt 100 -and $pct -gt 0) { $PrgTotal.Value = $pct + 1; $PrgTotal.Value = $pct } else { $PrgTotal.Value = $pct }
                                        $LblProgress.Text = "Progress ($displayName): $pct%"
                                    }
                                }
                            }

                            if ($l -match '^Transferred:\s+(\d+)\s*/\s*(\d+),\s*\d{1,3}%$') {
                                if ($Global:TotalTransferItems -le 0) { $LblFolderCount.Text = "Item(s): $($Matches[1]) out of $($Matches[2])" }
                            }

                            if ($l -match "(?i)INFO\s+:\s+(.+?):\s+Copied") {
                                $relPath = $Matches[1]
                                $srcFull = ($rSrcBase.TrimEnd('/\') + "/$relPath") -replace '(?<!:)/{2,}', '/'
                                $dstFull = ($rDstBase.TrimEnd('/\') + "/$relPath") -replace '(?<!:)/{2,}', '/'
                                $speedStr = if ($lastTransferSpeed) { "  |  Speed: $lastTransferSpeed" } else { "" }
                                Log-Message "From: $srcFull -> $dstFull$speedStr" "LightGreen"
                                $RegCopied++; $isUpdate = $true
                            } elseif ($l -match "Copying\s+(\S+)\s+to\s+(\S+)") {
                                $srcFull = $Matches[1]; $dstFull = $Matches[2]
                                Log-Message "From: $srcFull -> $dstFull" "LightGreen"
                                $RegCopied++; $isUpdate = $true
                            } elseif ($l -match "(?i)INFO\s+:\s+(.+?):\s+Unchanged skipping") {
                                $relPath = $Matches[1]
                                $srcFull = ($rSrcBase.TrimEnd('/\') + "/$relPath") -replace '(?<!:)/{2,}', '/'
                                $dstFull = ($rDstBase.TrimEnd('/\') + "/$relPath") -replace '(?<!:)/{2,}', '/'
                                Log-Message "Skip: $srcFull -> $dstFull  |  Unchanged" "DarkGray"
                                $isUpdate = $true
                            } elseif ($l -match "Skipping existing(?: destination)? item\s+(.+)") {
                                Log-Message "Skip: $($Matches[1])  |  Unchanged" "DarkGray"
                                $isUpdate = $true
                            } elseif ($l -match "(?i)ERROR\s+:\s+(.+?):\s+(.+)" -or $l -match "ERROR:\s+(.+)" -or $l -match "(?i)CRITICAL(.*?):\s+(.+)") {
                                Log-Message $l "LightCoral"
                                $RegFailed++; $isUpdate = $true
                            } elseif ($l -match "^(Transferred:|Checks:|Elapsed time:)") {
                                Log-Message $l "DarkGray"
                            } else {
                                $logColor = if ($l -match "ERROR" -or $l -match "CRITICAL") { "LightCoral" } else { "White" }
                                Log-Message $l $logColor
                            }

                            if ($isUpdate) {
                                $totalPro = $RegCopied + $RegFailed
                                if ($Global:TotalTransferItems -gt 0) {
                                    $pct = [math]::Round(($totalPro / $Global:TotalTransferItems) * 100)
                                    if ($pct -gt 100) { $pct = 100 }
                                    $PrgTotal.Style = "Continuous"
                                    if ($pct -lt 100 -and $pct -gt 0) { $PrgTotal.Value = $pct + 1; $PrgTotal.Value = $pct } else { $PrgTotal.Value = $pct }
                                    $LblProgress.Text = "Progress ($displayName): $pct%"
                                    $LblFolderCount.Text = "Item(s): $totalPro out of $($Global:TotalTransferItems)"
                                } else {
                                    $LblFolderCount.Text = "Item(s) Processed: $totalPro"
                                }
                            }
                        }
                    }
                    $lastSize = $fs.Position
                    $sr.Close(); $fs.Close()
                } catch { } 
            }
            
            [System.Windows.Forms.Application]::DoEvents()
            
            if ($Global:StopTransfer) { 
                if (-not $Global:CurrentProcess.HasExited) {
                    try { Start-Process "taskkill.exe" -ArgumentList "/PID $($Global:CurrentProcess.Id) /T /F" -WindowStyle Hidden -Wait } catch {}
                }
                break 
            }
            
            [System.Threading.Thread]::Sleep(100)
        }

        $fileInfo = Get-Item -LiteralPath $Global:RunLogFile -ErrorAction SilentlyContinue
        if ($fileInfo -and $fileInfo.Length -gt $lastSize) {
            try {
                $fs = New-Object System.IO.FileStream($Global:RunLogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $fs.Seek($lastSize, [System.IO.SeekOrigin]::Begin) | Out-Null
                $sr = New-Object System.IO.StreamReader($fs); while (-not $sr.EndOfStream) { 
                    $line = $sr.ReadLine(); 
                    if (![string]::IsNullOrWhiteSpace($line)) { 
                        $l = $line.Trim()
                        if ($l -match "(?i)INFO\s+:\s+(.+?):\s+Copied") {
                            $relPath = $Matches[1]
                            $srcFull = ($rSrcBase.TrimEnd('/\') + "/$relPath") -replace '(?<!:)/{2,}', '/'
                            $dstFull = ($rDstBase.TrimEnd('/\') + "/$relPath") -replace '(?<!:)/{2,}', '/'
                            $speedStr = if ($lastTransferSpeed) { "  |  Speed: $lastTransferSpeed" } else { "" }
                            Log-Message "From: $srcFull -> $dstFull$speedStr" "LightGreen"
                            $RegCopied++
                        } elseif ($l -match "Copying\s+(\S+)\s+to\s+(\S+)") {
                            $srcFull = $Matches[1]; $dstFull = $Matches[2]
                            Log-Message "From: $srcFull -> $dstFull" "LightGreen"
                            $RegCopied++
                        } elseif ($l -match "(?i)ERROR\s+:\s+(.+?):\s+(.+)" -or $l -match "ERROR:\s+(.+)" -or $l -match "(?i)CRITICAL(.*?):\s+(.+)") {
                            Log-Message $l "LightCoral"
                            $RegFailed++
                        } elseif ($l -match "^(Transferred:|Checks:|Elapsed time:)") {
                            Log-Message $l "DarkGray"
                        } else {
                            $logColor = if ($l -match "ERROR" -or $l -match "CRITICAL") { "LightCoral" } else { "White" }
                            Log-Message $l $logColor
                        }
                    } 
                }
                $sr.Close(); $fs.Close()
            } catch {}
        }
        
        if ($Global:CurrentProcess.ExitCode -notin @(0, 1, 9)) {
            $ProcessFailed = $true
            if (-not $QuotaReached) { Log-Message "Process finished with errors (Exit Code: $($Global:CurrentProcess.ExitCode)). Review log above." "LightCoral" }
        }

        $PrgTotal.Style = "Continuous"; $PrgTotal.Value = 100
        if ($Global:StopTransfer) { 
            $LblProgress.Text = "Transfer Aborted" 
        } else { 
            $LblProgress.Text = "Progress (Complete) ================= 100%" 
        }
        
        $TotalSourceItems = $Global:TotalTransferItems
        $RegSkipped = [math]::Max(0, ($TotalSourceItems - $RegCopied - $RegFailed))
        
        if ($LblFolderCount.Text -match "Calculating" -or $Global:TotalTransferItems -gt 0) {
            $totalPro = $RegCopied + $RegFailed
            $LblFolderCount.Text = "Item(s) Processed: $totalPro"
        }
        
        $transferStopwatch.Stop()
        
        $cleanTaskName = $TxtTaskName.Text -replace '[\\/:*?"<>|]', '_'
        $logDir = "C:\data_transfer_log\"
        if (-not (Test-Path -LiteralPath $logDir)) { try { New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null } catch {} }
        
        if ($existing -and -not [string]::IsNullOrWhiteSpace($existing.LogFilePath)) {
            $logPath = $existing.LogFilePath
        } else {
            $logPath = Join-Path $logDir "${cleanTaskName}_${startTimeSafe}.txt"
        }
        
        $finalStatus = if ($QuotaReached) { "Error" } elseif ($Global:StopTransfer) { "Aborted" } elseif ($RegFailed -gt 0 -or $ProcessFailed) { "Error" } else { "Completed" }
        $totalProcessed = $RegCopied + $RegSkipped + $RegFailed

        # Show summary in live log
        $summaryLines = @(
            ""
            "================================================="
            "TRANSFER COMPLETE - SUMMARY"
            "================================================="
            "Task:             $($TxtTaskName.Text)"
            "Status:           $finalStatus"
            "Duration:         $($transferStopwatch.Elapsed.ToString('hh\:mm\:ss'))"
            "Avg Speed:        $Global:TransferSpeed"
            "-------------------------------------------------"
            "Source Items    : $TotalSourceItems"
            "Copied          : $RegCopied"
            "Skipped         : $RegSkipped"
            "Failed          : $RegFailed"
            "Total Processed : $totalProcessed"
            "================================================="
        )
        $summaryColor = "LightGray"
        foreach ($sl in $summaryLines) { Log-Message $sl $summaryColor }

        $CleanLogString = if ($Global:FullLogLines -and $Global:FullLogLines.Count -gt 0) { $Global:FullLogLines -join "`n" } else { $RtbLog.Text }

        $Summary = @"
=================================================
AUDIT SUMMARY: Data Transfer Tool
=================================================
Task Name: $($TxtTaskName.Text)
Status: $finalStatus
Session Duration: $($transferStopwatch.Elapsed.ToString("hh\:mm\:ss"))
Source: $Global:SrcProvider | Dest: $Global:DstProvider
Exit Code: $($Global:CurrentProcess.ExitCode)
Average Speed: $Global:TransferSpeed

SESSION METRICS:
- Total Items in Source: $TotalSourceItems
- Copied: $RegCopied
- Skipped: $RegSkipped
- Failed: $RegFailed
- Total Processed: $totalProcessed

=================================================
CUMULATIVE DETAILED TRANSFER LOG:
=================================================
$CleanLogString
"@
        
        try { $Summary | Out-File -LiteralPath $logPath -Encoding utf8 -ErrorAction Stop } catch {}
        Log-Message "Summary File Saved: $logPath" "Cyan"
        
        if ($Global:CurrentTaskId) { 
            for ($i = 0; $i -lt $Global:Tasks.Count; $i++) {
                if ($Global:Tasks[$i].Id -eq $Global:CurrentTaskId) {
                    $Global:Tasks[$i].Status = $finalStatus
                    $Global:Tasks[$i].CompleteDate = (Get-Date -Format "MM/dd/yyyy HH:mm")
                    $Global:Tasks[$i].LogData = $CleanLogString
                    $Global:Tasks[$i].LogFilePath = $logPath 
                    break
                }
            }
            Save-Tasks; Sync-TasksToUI 
        }
    }

    try {
        if (![string]::IsNullOrEmpty($Global:ExcludeFile) -and (Test-Path -LiteralPath $Global:ExcludeFile -ErrorAction Stop)) { Remove-Item -LiteralPath $Global:ExcludeFile -Force -ErrorAction SilentlyContinue }
        if (![string]::IsNullOrEmpty($Global:BatFile) -and (Test-Path -LiteralPath $Global:BatFile -ErrorAction Stop)) { Remove-Item -LiteralPath $Global:BatFile -Force -ErrorAction SilentlyContinue }
    } catch {}

    $Global:IsTransferring = $false
    $Global:CurrentProcess = $null
    
    
    $BtnNewTask.Enabled = $true; $BtnDelTask.Enabled = $true; $BtnClearAll.Enabled = $true; $BtnDuplicate.Enabled = $true
    $BtnSrcLoc.Enabled = $true; $BtnSrcFilter.Enabled = $true; $BtnDstLoc.Enabled = $true; $BtnDstNewF.Enabled = $true; $BtnDstRef.Enabled = $true
    $BtnUpload.Enabled = $true; $BtnCheckAll.Enabled = $true; $BtnUncheckAll.Enabled = $true
    $BtnStop.Enabled = $false
})

$Form.Add_FormClosing({
    if ($Global:CurrentProcess -and -not $Global:CurrentProcess.HasExited) {
        try { Start-Process "taskkill.exe" -ArgumentList "/PID $($Global:CurrentProcess.Id) /T /F" -WindowStyle Hidden -Wait } catch {}
    }
    try {
        if (![string]::IsNullOrEmpty($Global:JsonTempFile) -and (Test-Path -LiteralPath $Global:JsonTempFile -ErrorAction Stop)) { Remove-Item -LiteralPath $Global:JsonTempFile -Force -ErrorAction SilentlyContinue }
        if (![string]::IsNullOrEmpty($Global:RunLogFile) -and (Test-Path -LiteralPath $Global:RunLogFile -ErrorAction Stop)) { Remove-Item -LiteralPath $Global:RunLogFile -Force -ErrorAction SilentlyContinue }
        if (![string]::IsNullOrEmpty($Global:ExcludeFile) -and (Test-Path -LiteralPath $Global:ExcludeFile -ErrorAction Stop)) { Remove-Item -LiteralPath $Global:ExcludeFile -Force -ErrorAction SilentlyContinue }
        if (![string]::IsNullOrEmpty($Global:BatFile) -and (Test-Path -LiteralPath $Global:BatFile -ErrorAction Stop)) { Remove-Item -LiteralPath $Global:BatFile -Force -ErrorAction SilentlyContinue }
    } catch {}
})

$BtnStop.Add_Click({ 
    if ($Global:CurrentProcess) { 
        if ([System.Windows.Forms.MessageBox]::Show("Are you sure you want to abort the current transfer?", "Confirm Abort", "YesNo", "Warning") -eq "Yes") { 
            $Global:StopTransfer = $true
            try { 
                if (-not $Global:CurrentProcess.HasExited) { 
                    Start-Process "taskkill.exe" -ArgumentList "/PID $($Global:CurrentProcess.Id) /T /F" -WindowStyle Hidden -Wait
                } 
            } catch {} 
        } 
    } 
})

$Form.ShowDialog() | Out-Null
}