# Data Transfer Tool (`data_transfer_tool.ps1`) User Guide

> **NOAA Scientific Product Disclaimer**
> 
> *This repository is a scientific product and is not official communication of the National Oceanic and Atmospheric Administration, or the United States Department of Commerce. All NOAA GitHub project code is provided on an ‘as is’ basis and the user assumes responsibility for its use. Any claims against the Department of Commerce or Department of Commerce bureaus stemming from the use of this GitHub project will be governed by all applicable Federal law. Any reference to specific commercial products, processes, or services by service mark, trademark, manufacturer, or otherwise, does not constitute or imply their endorsement, recommendation or favoring by the Department of Commerce. The Department of Commerce seal and logo, or the seal and logo of a DOC bureau, shall not be used in any manner to imply endorsement of any commercial product or activity by DOC or the United States Government.*

---

## Guide Version & Compatibility
* **Target PowerShell Script**: `data_transfer_tool.ps1`
* **Application Version**: `v1.1.50`
* **Last Updated**: September 2026

> **Note on Maintenance**: This document is synchronized directly with `data_transfer_tool.ps1`. Whenever new features, settings, or authentication options are introduced in script version updates, this User Guide is updated accordingly.

---

## Table of Contents
1. [Overview & Interface Layout](#1-overview--interface-layout)
2. [Step-by-Step Transfer Workflows](#2-step-by-step-transfer-workflows)
   - [Workflow A: Transferring Local Files/Folders to Google Drive](#workflow-a-transferring-local-filesfolders-to-google-drive)
   - [Workflow B: Transferring Local Files/Folders to Google Cloud Storage (GCS)](#workflow-b-transferring-local-filesfolders-to-google-cloud-storage-gcs)
   - [Workflow C: Transferring Files/Folders from Google Drive to Google Cloud Storage (GCS)](#workflow-c-transferring-filesfolders-from-google-drive-to-google-cloud-storage-gcs)
3. [Configuration & Settings Options Reference](#3-configuration--settings-options-reference)
   - [Configuration Settings Modal](#31-configuration-settings-modal)
   - [Exclusion Filters Modal](#32-exclusion-filters-modal)
   - [Theme & Credentials Controls](#33-theme--credentials-controls)
4. [Task History, Resuming, & Audit Logs](#4-task-history-resuming--audit-logs)
5. [Troubleshooting & FAQ](#5-troubleshooting--faq)

---

## 1. Overview & Interface Layout

The **Data Transfer Tool** is a PowerShell Windows Forms application designed for high-performance, observable, and multi-threaded data transfers across **Local Storage**, **Google Cloud Storage (GCS)**, and **Google Drive** (Personal My Drive & Enterprise Shared Drives).

```
+---------------------------------------------------------------------------------------------------------+
| Data Transfer Tool v1.1.50                                                                    [_][square][X] |
+---------------------------------------------------------------------------------------------------------+
| [ Left Panel ]            | [ Source Storage Panel ]            | [ Target Storage Panel ]              |
| - Dark Mode Toggle        | - Provider: LOCAL / GCS / GDRIVE    | - Provider: LOCAL / GCS / GDRIVE      |
| - Sign Out Button         | - Project / Bucket / Drive Picker   | - Project / Bucket / Drive Picker     |
| - Open Log in Notepad     | - Path Browser & Breadcrumb         | - Path Browser & Folder Creation      |
| - Settings Button         | - Granular Inclusion Checklist      |                                       |
| - Custom Filters Button   |   (Check All / Uncheck All)         | - Task Name Input                     |
|                           |                                     | - Threads Selector (1-6)              |
| [ Task History ListView ] |                                     | - START TRANSFER / STOP TRANSFER      |
|   (Sortable by Headers)   |                                     |                                       |
+---------------------------------------------------------------------------------------------------------+
| [ Bottom Panel: Live Log Console, Real-time Progress Bar, Speed Metric (MiB/s), Pre-Flight Item Count ] |
+---------------------------------------------------------------------------------------------------------+
```

### Main Screen Components:
* **Task History Panel (Left)**: Shows previous transfers loaded from `%APPDATA%\DataTransferTool\tasks_v1.json`. Click headers (**Name**, **Status**, **Started**, **Completed**) to sort.
* **Source Panel (Center)**: Select the source storage provider, authenticate, browse subdirectories, and use the **Include** checklist to select or deselect specific items for transfer.
* **Target Panel (Right-Top)**: Select the destination storage provider, authenticate, select destination folders, or create new folders.
* **Task Configuration (Right-Bottom)**: Specify a unique **Task Name**, choose thread limits, and initiate or stop transfers.
* **Live Console & Status Bar (Bottom)**: Displays real-time syntax-colored log output, progress percentage, transfer speed (KiB/s, MiB/s), and total item counters.

---

## 2. Step-by-Step Transfer Workflows

---

### Workflow A: Transferring Local Files/Folders to Google Drive

Use this workflow to upload local files or directories from your computer or network share into Google Drive (either your personal **My Drive** or an enterprise **Shared Drive**).

#### Step 1: Set Up Source Storage (Local)
1. In the **Source Storage** panel (top-middle), select **`LOCAL`** from the Storage Provider dropdown.
2. Click **Select Folder** (or type a path) to pick the directory containing the data you want to upload.
3. The directory items will appear in the lower **Include** checklist.
   - By default, all items are checked.
   - Uncheck any subfolders or files you want to exclude from the transfer.
   - Use **Check All** or **Uncheck All** for quick bulk selection.

#### Step 2: Set Up Destination Storage (Google Drive)
1. In the **Target Storage** panel (top-right), select **`GDRIVE`** from the Storage Provider dropdown.
2. Observe the authentication badge:
   - **`Auth (GDrive - Built-in)`**: Standard built-in Rclone OAuth credentials.
   - **`Auth (GDrive - Custom ID)`**: Your custom organizational OAuth Client credentials (configured under Settings).
3. If not yet authenticated, click **Login/Auth**. A browser window will open asking for Google authentication and permission. Follow the prompts to authorize access.
4. Select the target Drive Type in the project dropdown:
   - **`My Drive`**: Personal Google Drive storage.
   - **`Shared Drive`**: Displays a secondary dropdown listing all team/shared drives you have access to. Select your target team drive.
5. Double-click folders in the Target directory list to navigate into your desired destination subfolder.
   - To create a new destination folder, click **New Folder**, enter the folder name, and click OK.

#### Step 3: Configure and Start Transfer
1. In the bottom-right panel, enter a descriptive **Task Name** (e.g., `Local_To_GDrive_Hydrology_Docs`).
2. Verify **Transfer Threads** (default is `3`).
   > ⚠️ **Important Rate Limit Note**: For Google Drive transfers, keep threads set between **1 and 3**. Setting threads to 4 or higher can trigger Google Drive HTTP 403 Rate Limit Quota Exceeded errors.
3. Click **START TRANSFER**.
4. The tool automatically runs a pre-flight file scan, builds the transfer batch, and displays live progress, transfer speed, item counters, and color-coded log lines in the bottom console.

---

### Workflow B: Transferring Local Files/Folders to Google Cloud Storage (GCS)

Use this workflow to upload data from local disks or network drives to a Google Cloud Storage bucket using either **User OAuth** or a **Service Account JSON Key**.

#### Step 1: Set Up Source Storage (Local)
1. In the **Source Storage** panel, select **`LOCAL`** from the Storage Provider dropdown.
2. Click **Select Folder** to browse and select the local source folder.
3. Use the **Include** checklist to refine which subfolders or files to include.

#### Step 2: Select GCS Authentication Method & Target Bucket
1. In the **Target Storage** panel, select **`GCS`** from the Storage Provider dropdown.
2. Choose your **Auth Method**:

   ##### Method 1: User Account (OAuth)
   - Select **`User Account (OAuth)`** in the Auth Method dropdown.
   - If not logged in, click **Login/Auth**. The tool executes `gcloud auth login` and `gcloud auth application-default login`. Complete the login in your web browser.
   - Select your GCP Project from the **Project** dropdown.
   - Select your target bucket from the **Bucket** dropdown.
   - *Manual Override*: If your account lacks project-level listing permissions (`roles/viewer`), select **`[ No Project ID (Manual) ]`** in the Project dropdown and manually type your bucket name into the Bucket field, then press **Enter**.

   ##### Method 2: Service Account JSON Key (Headless / Automated)
   - Select **`Service Account (.json)`** in the Auth Method dropdown (or configure via Settings).
   - Click **Select Key** and select your Service Account `.json` key file.
   - The application validates the key file, activates the Service Account, and automatically populates/locks the associated Project ID.
   - Select or type the target bucket name.
   - *Advantage*: Service Account transfers run headless via Rclone using bucket-level IAM permissions (`roles/storage.objectAdmin`), bypassing project-wide service usage checks.

3. Navigate to the target subfolder by double-clicking directory rows, or click **New Folder** to create a new folder path in the bucket.

#### Step 3: Configure and Start Transfer
1. Enter a **Task Name** (e.g., `GCS_Upload_Model_Outputs`).
2. Under **Settings** (optional):
   - Check **Force Rclone engine for Local <-> GCS transfers** if uploading massive datasets over several hours. This prevents standard `gcloud` OAuth token expiration.
3. Click **START TRANSFER**.
4. The tool cleans any stale GCS tracker caches, creates `.placeholder` files for empty directories, calculates pre-flight file counts, and begins uploading.

---

### Workflow C: Transferring Files/Folders from Google Drive to Google Cloud Storage (GCS)

Use this workflow to stream files directly from Google Drive into a Google Cloud Storage bucket (Cross-Cloud Migration).

#### Step 1: Set Up Source Storage (Google Drive)
1. In the **Source Storage** panel, select **`GDRIVE`**.
2. Click **Login/Auth** if authentication is required.
3. Select **My Drive** or **Shared Drive** and choose your team drive.
4. Double-click to open the source folder containing the files to migrate.
5. Select or unselect specific items using the **Include** checklist.

#### Step 2: Set Up Target Storage (Google Cloud Storage)
1. In the **Target Storage** panel, select **`GCS`**.
2. Authenticate via **User Account (OAuth)** or **Service Account (.json)**.
3. Select the destination **Project** and **Bucket**.
4. Navigate to the desired destination subfolder inside the bucket.

#### Step 3: Verify Cross-Cloud Application Credentials
- Cross-cloud transfers rely on Rclone's `[GCSBridge]` remote.
- If using **User OAuth**, ensure Application Default Credentials (ADC) exist by letting the tool run `gcloud auth application-default login` when prompted.
- If using a **Service Account**, the tool automatically configures `rclone_persistent.conf` with `service_account_file` and `bucket_policy_only = true`.

#### Step 4: Launch and Monitor Transfer
1. Set **Task Name** (e.g., `GDrive_To_GCS_Archive_2026`).
2. Set **Transfer Threads** to **2** or **3** to respect Google Drive API quotas.
3. Click **START TRANSFER**.
4. Data streams directly between Google Drive and Google Cloud Storage without needing to save full files to local disk first.

---

## 3. Configuration & Settings Options Reference

All settings can be customized through the GUI dialogs or directly via `%APPDATA%\DataTransferTool\settings.json`.

---

### 3.1 Configuration Settings Modal

Click **Settings** on the left control panel to open the **Configuration Settings** modal dialog (`Show-SettingsDialog`).

| Setting UI Element | `settings.json` Key | Default | Detailed Option Explanation |
| :--- | :--- | :--- | :--- |
| **Rclone.exe Path** | `RclonePath` | `""` | **Optional**. Specify the absolute file path to `rclone.exe` (e.g., `C:\Tools\rclone.exe`). If left blank, the tool automatically detects `rclone.exe` in the script directory or system `PATH`. Use the **Browse** button to select the file. |
| **GCloud Bin Dir** | `GCloudPath` | `""` | **Optional**. Specify the folder path containing `gcloud.cmd` (e.g., `C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin`). If left blank, auto-detected from standard install locations or system `PATH`. Use the **Browse** button to select the directory. |
| **Enable Verbose Debug Logging** | `IsDebugMode` | `false` | **Checkbox**. When checked, passes `--verbosity=debug` to Google Cloud SDK CLI commands and outputs extra diagnostic information into the live log console during directory scanning and transfers. |
| **Force Rclone engine for Local <-> GCS transfers** | `ForceRcloneGcs` | `false` | **Checkbox**. When checked, forces all Local <-> GCS transfers to use Rclone instead of `gcloud storage`. **Recommended** for multi-hour transfers to prevent `gcloud` OAuth token session expiration or when using Service Accounts with limited project-level permissions. |
| **Rclone Transfer Threads (1-6)** | `TransferThreads` | `3` | **Dropdown (1 to 6)**. Sets parallel worker thread limits (`--transfers`, `--checkers`, `--tpslimit`).<br/>• **1 to 3 (Recommended for Google Drive)**: Prevents HTTP 403 Rate Limit Quota Exceeded errors.<br/>• **4 to 6 (Recommended for Local-to-Local / GCS)**: Maximizes throughput for high-speed local disk or cloud bucket transfers. |
| **GCS Service Account - JSON Key Path** | `GcsServiceAccountKeyPath` | `""` | **Optional**. Absolute path to a Google Cloud Service Account `.json` key file.<br/>• **Browse Button**: Opens a file picker to select a `.json` key. Automatically validates key structure.<br/>• **Clear Button**: Revokes and clears the active Service Account key, reverting to User OAuth. |
| **Google Drive API - Client ID** | `DriveClientId` | `""` | **Optional**. Custom Google OAuth2 Client ID from Google Cloud Console. If left blank, Rclone uses its built-in shared public Client ID. |
| **Google Drive API - Client Secret** | `DriveClientSecret` | `""` | **Optional**. Custom Google OAuth2 Client Secret. Masked with password characters.<br/>• **Show Secret Checkbox**: Toggles visibility of the Client Secret string. |
| **Save & Apply** | N/A | N/A | **Button**. Saves all settings to `settings.json`, updates environment variables (`GOOGLE_APPLICATION_CREDENTIALS`, `CLOUDSDK_PYTHON`, `PATH`), updates `rclone_persistent.conf`, and closes the settings modal. |
| **Help / Guide** | N/A | N/A | **Button**. Opens the official online user documentation in your default web browser. |

---

### 3.2 Exclusion Filters Modal

Click **Custom Filters** on the left control panel to open the **Exclusion Filters** modal (`Show-FilterDialog`).

- **Filter List**: Displays all active glob exclusion patterns used during directory browsing and transfer execution.
- **`+ Add` Button**: Prompts for a new exclusion pattern (e.g., `*.tmp`, `\System Volume Information\`, `*.bak`).
- **Double-Click Entry**: Double-click any item in the list to edit the filter pattern in-place.
- **`- Remove` Button**: Select a pattern and click to remove it from the filter list.
- **`OK` Button**: Saves the custom filters list into `settings.json` and immediately refreshes the active directory view.

---

### 3.3 Theme & Credentials Controls

- **Dark Mode / Light Mode Toggle Button**: Switches the entire GUI palette between high-contrast Dark theme (RGB 30,30,30) and clean Light theme (default). Preference is stored in `IsDarkMode`.
- **Sign Out Button (`Invoke-GlobalSignOut`)**:
  - For **User OAuth**: Executes `gcloud auth revoke --all`, deletes Application Default Credentials (`application_default_credentials.json`), wipes cached SQLite token databases (`credentials.db`), and revokes Rclone tokens.
  - For **Service Account**: Revokes the active Service Account and clears key paths.
- **Open Log in Notepad Button**: Opens the active live transfer run log or the most recent audit summary file (`C:\data_transfer_log\<TaskName>_<Timestamp>.txt`) in Windows Notepad.

---

## 4. Task History, Resuming, & Audit Logs

### 4.1 Task History Table & Sorting
- All tasks are saved persistently in `%APPDATA%\DataTransferTool\tasks_v1.json`.
- Click any header column (**Name**, **Status**, **Started**, **Completed**) in the Transfer History table to sort rows ascending or descending.

### 4.2 Inspecting vs Resuming Tasks
- **Single-Click**: Selects a task row in **Read-Only** mode to inspect historical parameters, endpoints, and previous logs without altering current UI input controls.
- **Double-Click (Resume / Edit Mode)**: Double-click an `Error`, `Aborted`, or `Active` task row. The tool:
  1. Restores the exact Source & Destination providers, paths, project IDs, and thread counts.
  2. Re-establishes storage connections.
  3. Re-selects the exact **Include** checklist state.
  4. Enables you to click **START TRANSFER** to resume copying remaining files without re-transferring unchanged files.

### 4.3 Task Duplication
- Select any past task in the list and click **Duplicate**.
- Creates a copy of the task parameters with a `(Copy)` suffix, allowing quick setup for similar transfer jobs.

### 4.4 Audit Logs
- Every completed, aborted, or errored job automatically writes an audit log to `C:\data_transfer_log\<TaskName>_<Timestamp>.txt`.
- Audit logs record execution start/end timestamps, duration, source/target endpoints, process exit codes, total processed item counts, copied item counts, skipped item counts, and full execution output streams.

---

## 5. Troubleshooting & FAQ

| Problem / Error Message | Possible Cause | Solution |
| :--- | :--- | :--- |
| **`403 Rate Limit Quota Exceeded` / `userRateLimitExceeded`** | Too many parallel requests hitting Google Drive API. | Open **Settings** and reduce **Transfer Threads** to `2` or `3`. The built-in circuit breaker will automatically stop tasks if rate limits are exceeded. |
| **`403 PERMISSION_DENIED` on Service Account** | Service account lacks project-level `serviceusage.services.use` permission. | Under **Settings**, check **Force Rclone engine for Local <-> GCS transfers** or select **Service Account (.json)** mode. This routes transfers directly through Rclone using bucket-level IAM roles. |
| **`GCS 404 Tracker File Not Found` during resume** | Corrupted tracking files from an interrupted `gcloud` composite upload. | The tool automatically cleans tracker caches before every transfer. If encountered manually, delete `%APPDATA%\gcloud\storage\tracker-files` and `%USERPROFILE%\.gsutil\tracker-files`. |
| **`Python not found` or `gcloud.cmd failed`** | Windows App Execution aliases for `python.exe` pointing to empty Microsoft Store stubs. | The script automatically repairs these registry keys on launch. Ensure Google Cloud SDK is reinstalled with the bundled Python component. |
| **GCS Project Dropdown is empty** | Your Google account lacks `roles/viewer` or `resourcemanager.projects.get` permissions. | Select **`[ No Project ID (Manual) ]`** in the Project dropdown and enter your bucket name directly in the Bucket field. |
| **`rclone.exe is not recognized`** | `rclone.exe` is not present in PATH or application directory. | Place `rclone.exe` in the script directory or configure its absolute path in GUI **Settings**. |
| **Google Drive auth fails or tokens expire** | Stale OAuth tokens stored in `rclone_persistent.conf`. | Click **Sign Out** next to Google Drive, then click **Login/Auth** to run a fresh OAuth authorization flow. |

---

## Guide Maintenance Policy

This `USER_GUIDE.md` is maintained in sync with `data_transfer_tool.ps1`. Whenever a new version of the PowerShell script is released:
1. The **Version & Compatibility** header at the top of this guide is updated to match the script title (e.g., `v1.1.50`).
2. Any new configuration parameters, UI controls, CLI flags, or authentication mechanisms are added to the corresponding sections.
3. Obsolete instructions or legacy workflows are revised or archived.

