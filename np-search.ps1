<#
np-search.ps1 - find a text string in every document currently open in Notepad.

Usage (from the command line, any folder):
  np-search "text to find" [-CaseSensitive] [-Context N] [-Before N] [-After N]

Examples:
  np-search "error 404"
  np-search "TODO" -CaseSensitive
  np-search "TODO" -Context 2
  np-search "error" -Before 1 -After 3
  (long form:  powershell -File C:\path\to\np-search.ps1 "text")

The search text is a literal string - quote it. Case-insensitive by default.
-Context N: N lines before and after each match; -Before N / -After N: one side only (grep -C / -B / -A).
SMB (\\server\share) files are searched the same way, no extra steps.

How it works:
  1. Reads Notepad's per-tab state files (LocalState\TabState\*.bin); each
     begins with the document's full path. The state directory is shared by
     all Notepad windows, so every window is covered.
  2. Matches each path to a live tab (UI Automation) for tab order and
     Modified/Unmodified state.
  3. Searches each file line by line. Encoding: BOM auto-detect (UTF-8 and
     UTF-16); files without a BOM are read as UTF-8 (ASCII text in legacy
     ANSI files still matches).

Output (grep style):
  C:\full\path\file.txt:123:  matched line text
With context flags, '|' marks a context line, ':' a match line, and '--' separates groups.
plus a summary line. Exit code: 0 = hits found, 1 = no hits, 2 = error.

Note: a tab with unsaved edits is searched by its SAVED (on-disk) content.
Modified tabs are listed at the end so you know what may be missing.
#>
param(
  [Parameter(Position = 0)][string]$Text,
  [switch]$CaseSensitive,
  [int]$Context = 0,
  [int]$Before  = 0,
  [int]$After   = 0
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Text)) {
  Write-Host 'Usage: np-search "<text to find>" [-CaseSensitive] [-Context N] [-Before N] [-After N]'
  exit 2
}
if ($args.Count -gt 0) {
  Write-Host ("Note: extra argument(s) ignored - did you forget the quotes? Ignored: {0}" -f ($args -join ' '))
}

$procs = @(Get-Process -Name notepad -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) {
  Write-Host 'Notepad is not running - nothing to search.'
  exit 2
}

$src = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\LocalState\TabState"
$dst = Join-Path $env:TEMP ('np_search_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dst | Out-Null

try {
  # --- 1) snapshot the tab-state files (Notepad holds them locked; shared read works) ---
  Get-ChildItem -Path $src -File -Filter '*.bin' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
      $fs  = [System.IO.File]::Open($_.FullName, 'Open', 'Read', 'ReadWrite')
      $out = [System.IO.File]::Create((Join-Path $dst $_.Name))
      $fs.CopyTo($out); $out.Close(); $fs.Close()
    } catch { }
  }

  # --- 2) live tabs (name, order, modified state) from every Notepad window ---
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  $root    = [System.Windows.Automation.AutomationElement]::RootElement
  $tabCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::TabItem)
  $tabs  = @()
  $order = 0
  foreach ($proc in $procs) {
    $win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children,
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $proc.Id)))
    if (-not $win) { continue }
    foreach ($tabEl in $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCond)) {
      $n = $tabEl.Current.Name
      if (-not $n -or $n -eq 'Add New Tab') { continue }
      $tabs += @{
        name     = ($n -replace '\. (Modified|Unmodified)\.$', '')
        modified = ($n -match '\. Modified\.$')
        order    = $order++
      }
    }
  }

  # --- 3) decode each state file: "NP" magic, len byte @4, path = UTF-16LE from byte 5 ---
  $docs = @()
  Get-ChildItem -Path $dst -File | ForEach-Object {
    if ($_.Length -lt 8) { return }
    $read = [Math]::Min(700, $_.Length)
    $b = New-Object byte[] $read
    $fs = [System.IO.File]::Open($_.FullName, 'Open', 'Read', 'ReadWrite')
    [void]$fs.Read($b, 0, $read); $fs.Close()
    if ($b[0] -ne 0x4E -or $b[1] -ne 0x50) { return }
    $len = $b[4]
    if ($len -lt 1 -or $len -gt 300) { return }
    $sb = New-Object System.Text.StringBuilder
    for ($j = 5; $j + 1 -lt $read -and $sb.Length -lt $len; $j += 2) {
      if ($b[$j] -eq 0 -and $b[$j + 1] -eq 0) { break }
      [void]$sb.Append([char]($b[$j] -bor ($b[$j + 1] -shl 8)))
    }
    $docPath = $sb.ToString()
    if ($docPath -notmatch '^[A-Za-z]:[\\]|^\\\\') { return }
    $tab = $null
    foreach ($t in $tabs) { if ($docPath.EndsWith($t.name)) { $tab = $t; break } }
    $docs += @{ path = $docPath; tab = $tab }
  }

  if ($docs.Count -eq 0) {
    Write-Host 'No open Notepad documents found - nothing to search.'
    exit 2
  }

  # --- 4) search ---
  if ($CaseSensitive) { $cmp = [System.StringComparison]::Ordinal } else { $cmp = [System.StringComparison]::OrdinalIgnoreCase }
  if ($Context -lt 0 -or $Before -lt 0 -or $After -lt 0) {
    Write-Host '-Context, -Before, -After take a non-negative line count.'
    exit 2
  }
  $before = if ($Before -gt 0) { $Before } else { $Context }
  $after  = if ($After -gt 0) { $After } else { $Context }
  $mode = if ($CaseSensitive) { 'case-sensitive' } else { 'case-insensitive' }
  $ctxNote = ''
  if ($before -gt 0 -or $after -gt 0) { $ctxNote = (', {0} line(s) before, {1} after' -f $before, $after) }
  Write-Host ("Searching {0} open Notepad document(s) for ""{1}"" ({2}{3}):" -f $docs.Count, $Text, $mode, $ctxNote)

  $totalHits = 0
  $hitFiles  = @{}
  $seen      = @{}
  foreach ($d in ($docs | Sort-Object @{ e = { if ($_.tab) { $_.tab.order } else { 9999 } } })) {
    $p = $d.path
    if ($seen[$p]) { continue }
    $seen[$p] = $true
    if ($Text -match '[\r\n]') {
      Write-Host ("  {0}:  <skipped: search text contains a newline>" -f $p)
      continue
    }
    try {
      $content = [System.IO.File]::ReadAllText($p)
    } catch {
      Write-Host ("  {0}:  <cannot read: {1}>" -f $p, $_.Exception.Message)
      continue
    }
    $lines = $content -split "\r\n|\r|\n"
    # collect matching line indices
    $matchIdx = @()
    for ($li = 0; $li -lt $lines.Count; $li++) {
      if ($lines[$li].IndexOf($Text, $cmp) -ge 0) { $matchIdx += $li }
    }
    if ($matchIdx.Count -eq 0) { continue }
    $totalHits += $matchIdx.Count
    $hitFiles[$p] = $true

    # merge overlapping context windows into [start, end] pairs
    $windows = @()
    foreach ($m in $matchIdx) {
      $s = [Math]::Max(0, $m - $before)
      $e = [Math]::Min($lines.Count - 1, $m + $after)
      if ($windows.Count -gt 0 -and $s -le $windows[$windows.Count - 1][1] + 1) {
        if ($e -gt $windows[$windows.Count - 1][1]) { $windows[$windows.Count - 1][1] = $e }
      } else {
        $windows += , @($s, $e)
      }
    }

    # print: ':' marks a match, '|' marks context, '--' separates groups
    $matchSet = @{}
    foreach ($m in $matchIdx) { $matchSet[$m] = $true }
    $first = $true
    foreach ($w in $windows) {
      if (-not $first) { if ($before -gt 0 -or $after -gt 0) { Write-Host '  --' } }
      $first = $false
      for ($li = $w[0]; $li -le $w[1]; $li++) {
        $sep = if ($matchSet.ContainsKey($li)) { ':' } else { '|' }
        $shown = $lines[$li].Trim()
        if ($shown.Length -gt 200) { $shown = $shown.Substring(0, 200) + ' ...' }
        Write-Host ('  ' + $p + ':' + ($li + 1) + $sep + '  ' + $shown)
      }
    }
  }

  Write-Host ("Done: {0} hit(s) in {1} of {2} document(s)." -f $totalHits, $hitFiles.Count, $seen.Count)
  $modifiedNames = @($tabs | Where-Object modified | ForEach-Object name | Sort-Object -Unique)
  if ($modifiedNames.Count -gt 0) {
    Write-Host ("Note: {0} tab(s) have unsaved changes; their saved (on-disk) content was searched: {1}" -f $modifiedNames.Count, ($modifiedNames -join ', '))
  }
  if ($totalHits -gt 0) { exit 0 } else { exit 1 }
}
finally {
  Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
}
