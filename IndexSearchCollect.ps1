Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# --- Win32 helpers ---
Add-Type -ReferencedAssemblies "System.Windows.Forms" -TypeDefinition @"
    using System;
    using System.Runtime.InteropServices;
    using System.Windows.Forms;

    public class Win32Helper {
        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();
    }

    public class WindowWrapper : IWin32Window {
        private IntPtr _handle;
        public WindowWrapper(IntPtr handle) { _handle = handle; }
        public IntPtr Handle { get { return _handle; } }
    }
"@

# --- Helper: human-readable size ---
function Format-Size([long]$bytes) {
    if     ($bytes -ge 1TB) { return "{0:N2} TB" -f ($bytes / 1TB) }
    elseif ($bytes -ge 1GB) { return "{0:N2} GB" -f ($bytes / 1GB) }
    elseif ($bytes -ge 1MB) { return "{0:N2} MB" -f ($bytes / 1MB) }
    elseif ($bytes -ge 1KB) { return "{0:N2} KB" -f ($bytes / 1KB) }
    else                    { return "$bytes B" }
}

# --- Helper: sanitise search terms for Windows Search SQL ---
function Sanitize-SearchTerm([string]$term) {
    $term = $term -replace '[''"""(){}*\\&|!~^]', ' '
    $term = $term.Trim()
    return $term
}

# ============================================================
# STEP 1 - Warning / Info Dialog
# ============================================================
$warningText = @"
IMPORTANT - BEFORE USING THIS TOOL

Any drives or folders you want to search MUST be added
to the Windows Search Index first.

To do this:
  1. Open the Start Menu and search for "Indexing Options"
  2. Click "Modify" to add drives or folders
  3. Wait for indexing to complete before using this tool

Files in locations NOT added to the index will NOT be found.

SEARCH TIPS:
  - Spaces in search terms are supported
  - To search for MULTIPLE terms, separate them with a
    semicolon (;)   Example: confidential;password;secret
  - Files matching ANY term will be included

Created by: Will
"@

$warningResult = [System.Windows.Forms.MessageBox]::Show(
    $warningText,
    "Index Search & Collect by Will",
    [System.Windows.Forms.MessageBoxButtons]::OKCancel,
    [System.Windows.Forms.MessageBoxIcon]::Information
)

if ($warningResult -ne [System.Windows.Forms.DialogResult]::OK) { exit }

# ============================================================
# STEP 2 - Search Term Input Dialog
# ============================================================
$inputForm                 = New-Object System.Windows.Forms.Form
$inputForm.Text            = "Index Search & Collect by Will"
$inputForm.Size            = New-Object System.Drawing.Size(500, 220)
$inputForm.StartPosition   = "CenterScreen"
$inputForm.FormBorderStyle = "FixedDialog"
$inputForm.MaximizeBox     = $false
$inputForm.MinimizeBox     = $false
$inputForm.TopMost         = $true

$lblInput          = New-Object System.Windows.Forms.Label
$lblInput.Text     = "Enter search term(s) separated with ;"
$lblInput.Location = New-Object System.Drawing.Point(20, 20)
$lblInput.AutoSize = $true
$lblInput.Font     = New-Object System.Drawing.Font("Segoe UI", 10)
$inputForm.Controls.Add($lblInput)

$txtSearch          = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(20, 55)
$txtSearch.Size     = New-Object System.Drawing.Size(440, 28)
$txtSearch.Font     = New-Object System.Drawing.Font("Segoe UI", 11)
$inputForm.Controls.Add($txtSearch)

$btnSearch          = New-Object System.Windows.Forms.Button
$btnSearch.Text     = "Search"
$btnSearch.Size     = New-Object System.Drawing.Size(100, 35)
$btnSearch.Location = New-Object System.Drawing.Point(190, 110)
$btnSearch.Font     = New-Object System.Drawing.Font("Segoe UI", 10)
$btnSearch.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtSearch.Text)) {
        $null = [System.Windows.Forms.MessageBox]::Show("Please enter at least one search term.", "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $inputForm.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $inputForm.Close()
})
$inputForm.AcceptButton = $btnSearch
$inputForm.Controls.Add($btnSearch)

$inputResult = $inputForm.ShowDialog()
if ($inputResult -ne [System.Windows.Forms.DialogResult]::OK) { exit }

$searchInput = $txtSearch.Text

# --- Parse search terms ---
$searchTerms = $searchInput -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

if ($searchTerms.Count -eq 0) {
    $null = [System.Windows.Forms.MessageBox]::Show("No valid search terms provided.", "Error",
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    exit
}

# ============================================================
# STEP 3 - Show "Searching..." splash while querying index
# ============================================================
$splashForm                 = New-Object System.Windows.Forms.Form
$splashForm.Text            = "Index Search & Collect by Will"
$splashForm.Size            = New-Object System.Drawing.Size(400, 120)
$splashForm.StartPosition   = "CenterScreen"
$splashForm.FormBorderStyle = "FixedDialog"
$splashForm.MaximizeBox     = $false
$splashForm.MinimizeBox     = $false
$splashForm.ControlBox      = $false
$splashForm.TopMost         = $true

$lblSearching          = New-Object System.Windows.Forms.Label
$lblSearching.Text     = "Searching the index, please wait..."
$lblSearching.Font     = New-Object System.Drawing.Font("Segoe UI", 11)
$lblSearching.AutoSize = $true
$lblSearching.Location = New-Object System.Drawing.Point(30, 35)
$splashForm.Controls.Add($lblSearching)

$splashForm.Show()
$splashForm.Refresh()

# --- Build query ---
$freetextParts = @()
$fileNameParts = @()

foreach ($term in $searchTerms) {
    $clean = Sanitize-SearchTerm $term
    if ([string]::IsNullOrWhiteSpace($clean)) { continue }
    $escaped = $clean -replace "'", "''"
    $freetextParts += "FREETEXT(System.Search.Contents, '$escaped')"
    $fileNameParts += "System.FileName LIKE '%$escaped%'"
}

if ($freetextParts.Count -eq 0) {
    $splashForm.Close()
    $splashForm.Dispose()
    $null = [System.Windows.Forms.MessageBox]::Show(
        "Search terms contained only special characters. Please try simpler terms.",
        "Invalid Search",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    exit
}

$contentClause  = $freetextParts -join " OR "
$fileNameClause = $fileNameParts -join " OR "

$connectionString = "Provider=Search.CollatorDSO;Extended Properties='Application=Windows';"
$query = @"
SELECT System.ItemPathDisplay, System.Size
FROM SystemIndex
WHERE (
    $contentClause
    OR $fileNameClause
)
AND System.Kind = 'document'
"@

# --- Query with retry logic for busy indexer ---
$maxAttempts  = 5
$attempt      = 0
$success      = $false
$matchedFiles = @()
$totalSize    = [long]0
$queryError   = $null

while (-not $success -and $attempt -lt $maxAttempts) {
    $attempt++

    if ($attempt -gt 1) {
        $lblSearching.Text = "Indexer is busy - retrying (attempt $attempt of $maxAttempts)..."
        $splashForm.Refresh()
        Start-Sleep -Seconds (5 * $attempt)
    }

    $connection = New-Object System.Data.OleDb.OleDbConnection($connectionString)
    $command    = New-Object System.Data.OleDb.OleDbCommand($query, $connection)
    $command.CommandTimeout = 180

    $matchedFiles     = @()
    $totalSize        = [long]0
    $reader           = $null
    $thisAttemptError = $null

    try {
        $connection.Open()

        try {
            $reader = $command.ExecuteReader()
        } catch {
            # FREETEXT content query failed — fall back to filename-only
            $fallbackQuery = @"
SELECT System.ItemPathDisplay, System.Size
FROM SystemIndex
WHERE ($fileNameClause)
AND System.Kind = 'document'
"@
            $command2 = New-Object System.Data.OleDb.OleDbCommand($fallbackQuery, $connection)
            $command2.CommandTimeout = 180
            $reader = $command2.ExecuteReader()
        }

        $keepReading   = $true
        $readFailures  = 0

        while ($keepReading) {
            try {
                $keepReading = $reader.Read()
            } catch {
                $readFailures++
                if ($readFailures -gt 10) {
                    throw "Indexer unstable - too many read failures"
                }
                continue
            }

            if (-not $keepReading) { break }
            $readFailures = 0

            try {
                $path = $reader["System.ItemPathDisplay"]
                $size = $reader["System.Size"]

                if ($path -and (Test-Path $path)) {
                    $matchedFiles += $path
                    if ($size -ne [DBNull]::Value -and $size -ne $null) {
                        $totalSize += [long]$size
                    }
                }
            } catch {
                continue
            }
        }

        $reader.Close()
        $success = $true
    } catch {
        $thisAttemptError = $_.Exception.Message
        $queryError       = $thisAttemptError
    } finally {
        if ($connection.State -eq 'Open') { $connection.Close() }
    }
}

$splashForm.Close()
$splashForm.Dispose()

if (-not $success) {
    $null = [System.Windows.Forms.MessageBox]::Show(
        "The Windows Search indexer appears to be busy or rebuilding.`n`n" +
        "This usually resolves itself after the indexer finishes (can take anywhere from a few minutes to a few hours).`n`n" +
        "You can check indexer status in:`n" +
        "   Start Menu -> Indexing Options`n`n" +
        "Please try again later.`n`nTechnical details:`n$queryError",
        "Indexer Busy",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    exit
}

if ($matchedFiles.Count -eq 0) {
    $null = [System.Windows.Forms.MessageBox]::Show(
        "No indexed files found matching your search terms.",
        "No Results",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
    exit
}

$sizeString = Format-Size $totalSize

# ============================================================
# STEP 4 - Summary + Browse dialog
# ============================================================
$selectedFolder = $null

$summaryForm                 = New-Object System.Windows.Forms.Form
$summaryForm.Text            = "Index Search & Collect by Will"
$summaryForm.Size            = New-Object System.Drawing.Size(420, 250)
$summaryForm.StartPosition   = "CenterScreen"
$summaryForm.FormBorderStyle = "FixedDialog"
$summaryForm.MaximizeBox     = $false
$summaryForm.MinimizeBox     = $false
$summaryForm.TopMost         = $true

$lblCount          = New-Object System.Windows.Forms.Label
$lblCount.Text     = "Files found:  $($matchedFiles.Count)"
$lblCount.Font     = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblCount.Location = New-Object System.Drawing.Point(30, 25)
$lblCount.AutoSize = $true
$summaryForm.Controls.Add($lblCount)

$lblSize           = New-Object System.Windows.Forms.Label
$lblSize.Text      = "Total size:     $sizeString"
$lblSize.Font      = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblSize.Location  = New-Object System.Drawing.Point(30, 60)
$lblSize.AutoSize  = $true
$summaryForm.Controls.Add($lblSize)

$lblPrompt          = New-Object System.Windows.Forms.Label
$lblPrompt.Text     = "Choose where to save the export"
$lblPrompt.Font     = New-Object System.Drawing.Font("Segoe UI", 10)
$lblPrompt.Location = New-Object System.Drawing.Point(30, 110)
$lblPrompt.AutoSize = $true
$summaryForm.Controls.Add($lblPrompt)

$btnBrowse          = New-Object System.Windows.Forms.Button
$btnBrowse.Text     = "Browse..."
$btnBrowse.Size     = New-Object System.Drawing.Size(100, 35)
$btnBrowse.Location = New-Object System.Drawing.Point(155, 150)
$btnBrowse.Font     = New-Object System.Drawing.Font("Segoe UI", 10)
$btnBrowse.Add_Click({
    $folderDlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDlg.Description         = "Select the destination folder"
    $folderDlg.RootFolder          = [System.Environment+SpecialFolder]::MyComputer
    $folderDlg.ShowNewFolderButton = $true

    if ($folderDlg.ShowDialog($summaryForm) -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:selectedFolder     = $folderDlg.SelectedPath
        $summaryForm.DialogResult  = [System.Windows.Forms.DialogResult]::OK
        $summaryForm.Close()
    }
})
$summaryForm.Controls.Add($btnBrowse)

$btnCancel          = New-Object System.Windows.Forms.Button
$btnCancel.Text     = "Cancel"
$btnCancel.Size     = New-Object System.Drawing.Size(100, 35)
$btnCancel.Location = New-Object System.Drawing.Point(270, 150)
$btnCancel.Font     = New-Object System.Drawing.Font("Segoe UI", 10)
$btnCancel.Add_Click({
    $summaryForm.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $summaryForm.Close()
})
$summaryForm.Controls.Add($btnCancel)

$summaryResult = $summaryForm.ShowDialog()

if ($summaryResult -ne [System.Windows.Forms.DialogResult]::OK -or -not $selectedFolder) {
    exit
}

$destinationFolder = $selectedFolder

if (-not (Test-Path $destinationFolder)) {
    New-Item -ItemType Directory -Path $destinationFolder | Out-Null
}

# ============================================================
# STEP 5 - Copy files with progress dialog
# ============================================================
$progressForm                 = New-Object System.Windows.Forms.Form
$progressForm.Text            = "Index Search & Collect by Will"
$progressForm.Size            = New-Object System.Drawing.Size(500, 180)
$progressForm.StartPosition   = "CenterScreen"
$progressForm.FormBorderStyle = "FixedDialog"
$progressForm.MaximizeBox     = $false
$progressForm.MinimizeBox     = $false
$progressForm.ControlBox      = $false
$progressForm.TopMost         = $true

$lblProgress          = New-Object System.Windows.Forms.Label
$lblProgress.Text     = "Copying file 0 of $($matchedFiles.Count)..."
$lblProgress.Font     = New-Object System.Drawing.Font("Segoe UI", 10)
$lblProgress.Location = New-Object System.Drawing.Point(20, 20)
$lblProgress.AutoSize = $true
$progressForm.Controls.Add($lblProgress)

$progressBar          = New-Object System.Windows.Forms.ProgressBar
$progressBar.Minimum  = 0
$progressBar.Maximum  = $matchedFiles.Count
$progressBar.Value    = 0
$progressBar.Size     = New-Object System.Drawing.Size(440, 30)
$progressBar.Location = New-Object System.Drawing.Point(20, 55)
$progressForm.Controls.Add($progressBar)

$lblCurrentFile          = New-Object System.Windows.Forms.Label
$lblCurrentFile.Text     = ""
$lblCurrentFile.Font     = New-Object System.Drawing.Font("Segoe UI", 8)
$lblCurrentFile.Location = New-Object System.Drawing.Point(20, 95)
$lblCurrentFile.Size     = New-Object System.Drawing.Size(440, 20)
$progressForm.Controls.Add($lblCurrentFile)

$progressForm.Show()
$progressForm.Refresh()

$copiedCount = 0
$failedCount = 0
$index       = 0

foreach ($filePath in $matchedFiles) {
    $index++
    $fileName  = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
    $extension = [System.IO.Path]::GetExtension($filePath)
    $destPath  = Join-Path $destinationFolder "$fileName$extension"

    $counter = 1
    while (Test-Path $destPath) {
        $destPath = Join-Path $destinationFolder "${fileName}_$counter$extension"
        $counter++
    }

    $lblProgress.Text    = "Copying file $index of $($matchedFiles.Count)..."
    $lblCurrentFile.Text = $filePath
    $progressBar.Value   = $index
    $progressForm.Refresh()

    try {
        Copy-Item -Path $filePath -Destination $destPath -ErrorAction Stop
        $copiedCount++
    } catch {
        $failedCount++
    }
}

$progressForm.Close()
$progressForm.Dispose()

# ============================================================
# STEP 6 - Final summary
# ============================================================
$summaryMessage = @"
Export complete!

Files copied:    $copiedCount
Files failed:     $failedCount
Destination:     $destinationFolder
"@

$null = [System.Windows.Forms.MessageBox]::Show(
    $summaryMessage,
    "Index Search & Collect by Will",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
)
