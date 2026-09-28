# Index Search & Collect

A small Windows tool that searches the **Windows Search Index** for documents matching one or more terms, then copies every match into a single folder of your choice.

It was built for gathering documents for Subject Access Requests (SARs), but works for any "find everything that mentions X and put it in one place" job: audits, handovers, e-discovery, tidying up.

## How it works

1. Enter one or more search terms, separated with `;` (e.g. `Jane Smith;J.Smith;ref 12345`).
2. The tool queries the Windows Search Index for documents whose **file name or contents** match *any* of the terms.
3. You see how many files were found and their total size, then pick a destination folder.
4. The files are copied (never moved) into that folder with a progress bar. If two files share a name, the later ones get `_1`, `_2`, … added.

Originals are never modified.

## Important: the Windows Search Index

The tool only finds files in locations that Windows has indexed. It does not crawl drives itself.

1. Open the Start Menu and search for **Indexing Options**.
2. Click **Modify** and tick the drives or folders you want searchable.
3. Wait for indexing to finish before searching.

For file contents to be searchable, Windows also needs to be able to read the file type, which covers most Office documents, PDFs (with a PDF filter installed) and plain text.

If the indexer is busy or rebuilding, the tool retries a few times before giving up with a message.

## Running it

**Option 1: the PowerShell script**

```powershell
powershell -ExecutionPolicy Bypass -File .\IndexSearchCollect.ps1
```

**Option 2: the .exe**

Download `IndexSearchCollect.exe` from the [Releases](../../releases) page and double-click it.

The exe is the same script compiled with [PS2EXE](https://github.com/MScholtes/PS2EXE). It isn't code-signed, so Windows SmartScreen or antivirus may warn about it. If you'd rather not trust a binary, run the script or build the exe yourself:

```powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-ps2exe .\IndexSearchCollect.ps1 .\IndexSearchCollect.exe -noConsole -title "Index Search & Collect" -version 1.1.0
```

## Requirements

- Windows 10 or 11 with Windows Search enabled
- Windows PowerShell 5.1 or PowerShell 7+

## Licence

[MIT](LICENSE)
