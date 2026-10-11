# notepad-search

Find a text string in every document currently open in Notepad (Windows 11).

Notepad keeps its per-tab state files locked, and it has no built-in "find in all
open documents". `np-search` works around both: it snapshots Notepad's TabState
directory with a shared read, matches each stored path to a live tab via UI
Automation, then searches the on-disk file content line by line.

## Requirements

- Windows 11 with the built-in Microsoft Notepad
- Windows PowerShell 5.1 or later (ships with Windows)
- No other dependencies

## Install

Copy `np-search.ps1` and `np-search.cmd` to a folder of your choice and add that
folder to your `PATH`. The `.cmd` file is a one-line shim so `np-search` can be
typed in any shell; it always invokes the `.ps1` sitting next to it, so the pair
stays self-contained if you move the folder.

Alternatively, skip the PATH entry and call the script directly:

```
powershell -File .\np-search.ps1 "text"
```

If your PowerShell execution policy blocks scripts, add `-ExecutionPolicy Bypass`
before `-File` on that invocation.

## Usage

```
np-search "<text to find>" [-CaseSensitive] [-Context N] [-Before N] [-After N]
```

- The search text is a literal string — quote it.
- Case-insensitive by default; flip with `-CaseSensitive`.
- `-Context N` — N lines before and after each match (like `grep -C`).
- `-Before N` / `-After N` — one side only (like `grep -B` / `grep -A`).
  Combined with `-Context`, the specific side wins.
- PowerShell's parameter prefix matching means `-B`, `-A`, and `-Co` work as
  short forms. Bare `-C` is ambiguous (`CaseSensitive` / `Context`).

### Examples

```
np-search "error 404"
np-search "TODO" -CaseSensitive
np-search "TODO" -Context 2
np-search "error" -Before 1 -After 3
```

## Output

grep-style, in tab order:

```
C:\full\path\file.txt:123:  matched line text
```

With context flags, `:` marks a match line, `|` a context line, and `--`
separates distant groups. Lines longer than 200 characters are truncated. A
summary line ends the run.

Exit codes: `0` hits found, `1` no hits, `2` error (Notepad not running, no open
documents, bad arguments).

## Notes

- **Unsaved edits are invisible.** A tab with unsaved changes is searched by its
  *saved* (on-disk) content. Modified tabs are listed at the end of the run so
  you know what to double-check by eye.
- **SMB/UNC paths** (`\\server\share\...`) are searched with no extra handling.
- **Encoding**: BOM auto-detect (UTF-8, UTF-16); files without a BOM are read as
  UTF-8 (ASCII text in legacy ANSI files still matches).
- **Read errors** (offline share, locked file) are reported per file and do not
  stop the run.
- **Multiple Notepad windows** are all covered — the TabState directory is
  shared, so every window's tabs are enumerated.
