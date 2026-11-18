# Native Windows title bar for Claude Desktop. See README.md.
[CmdletBinding()]
param(
  [switch]$Rollback,
  [switch]$DryRun,
  [string]$PackageDir
)
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Patches
# ---------------------------------------------------------------------------

$Css = '.dframe-chrome-bar{padding-right:var(--df-chrome-bar-end-gutter,12px)!important}'
$CssInjector = 'try{require("electron").app.on("web-contents-created",(e,w)=>w.on("dom-ready",()=>' +
               "w.insertCSS('$Css').catch(()=>{})))}catch{}/*claude-native-titlebar*/"

# asar - archive under resources\
# path - file inside the archive; without it, 'from' must be unique in the whole archive
# from - text to replace (first occurrence in the file)
# to   - replacement
$Patches = @(
  @{ asar = 'app.asar'; name = 'native window frame'
     from = 'titleBarStyle:"hidden",titleBarOverlay:!0,'
     to   = 'titleBarOverlay:!1,' }
  @{ asar = 'app.asar'; name = 'toolbar CSS'; path = '.vite/build/index.pre.js'
     from = '"use strict";'
     to   = '"use strict";' + $CssInjector }
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

Add-Type -TypeDefinition @'
public static class ByteSearch {
  public static int IndexOf(byte[] hay, byte[] needle, int start, int end) {
    int last = end - needle.Length;
    for (int i = start; i <= last; i++) {
      i = System.Array.IndexOf(hay, needle[0], i, last - i + 1);
      if (i < 0) return -1;
      int j = 1;
      while (j < needle.Length && hay[i + j] == needle[j]) j++;
      if (j == needle.Length) return i;
    }
    return -1;
  }
  public static int Count(byte[] hay, byte[] needle, int start, int end) {
    int n = 0, i = start;
    while ((i = IndexOf(hay, needle, i, end)) >= 0) { n++; i++; }
    return n;
  }
}
'@

$Latin1 = [Text.Encoding]::GetEncoding(28591)   # 1 byte = 1 char, round-trips any bytes

function Get-Sha256Hex([byte[]]$Bytes, [long]$Offset = 0, [long]$Length = -1) {
  if ($Length -lt 0) { $Length = $Bytes.Length - $Offset }
  $sha = [Security.Cryptography.SHA256]::Create()
  try { -join ($sha.ComputeHash($Bytes, [int]$Offset, [int]$Length) | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}

function Get-AsciiBytes([string]$Text) { [Text.Encoding]::ASCII.GetBytes($Text) }
function Get-UInt32Bytes([long]$Value) { [BitConverter]::GetBytes([uint32]$Value) }

function Get-SourcePath([string]$Path) {
  if (Test-Path "$Path.bak") { "$Path.bak" } else { $Path }
}

function Find-ClaudePackage {
  $query = '(Get-AppxPackage -Name Claude | Sort-Object { [version]$_.Version } | Select-Object -Last 1).InstallLocation'
  try { $dir = Invoke-Expression $query } catch { $dir = $null }
  # PowerShell 7 can fail to load the Appx module; fall back to Windows PowerShell.
  if (-not $dir) { try { $dir = & powershell.exe -NoProfile -Command $query | Select-Object -Last 1 } catch {} }
  if (-not $dir) { throw 'Claude Desktop is not installed (Get-AppxPackage -Name Claude returned nothing).' }
  $dir
}

# ---------------------------------------------------------------------------
# asar
#
# Layout: [u32 4][u32 headerPickleSize] [u32 payloadSize][u32 jsonLength][json][pad to 4] [file data]
# Each packed file entry: {"size":N,"offset":"N","integrity":{...,"hash":"..","blockSize":N,"blocks":[..]}}
# ---------------------------------------------------------------------------

function Read-Asar([string]$Path) {
  $bytes = [IO.File]::ReadAllBytes($Path)
  $headerPickleSize = [BitConverter]::ToUInt32($bytes, 4)
  $jsonLength = [BitConverter]::ToInt32($bytes, 12)
  $json = [Text.Encoding]::UTF8.GetString($bytes, 16, $jsonLength)

  $files = @{}   # 'dir/file' -> entry, packed files only
  $stack = New-Object Collections.Stack
  $stack.Push(@('', ($json | ConvertFrom-Json)))
  while ($stack.Count) {
    $prefix, $node = $stack.Pop()
    foreach ($p in $node.files.PSObject.Properties) {
      $filePath = if ($prefix) { "$prefix/$($p.Name)" } else { $p.Name }
      if ($p.Value.files) { $stack.Push(@($filePath, $p.Value)) }
      elseif (-not $p.Value.unpacked -and $null -ne $p.Value.offset) { $files[$filePath] = $p.Value }
    }
  }

  @{
    Bytes      = $bytes
    DataStart  = [long](8 + $headerPickleSize)
    Json       = $json
    HeaderHash = Get-Sha256Hex $bytes 16 $jsonLength
    Files      = $files
  }
}

function Get-EntryJson($Entry, [long]$Size, [string]$Hash, [string[]]$Blocks) {
  '"size":' + $Size + ',"offset":"' + $Entry.offset + '","integrity":{"algorithm":"SHA256","hash":"' + $Hash +
  '","blockSize":' + $Entry.integrity.blockSize + ',"blocks":[' + (($Blocks | ForEach-Object { "`"$_`"" }) -join ',') + ']}'
}

# Applies patches to an archive read by Read-Asar; returns the new archive bytes and header hash.
function Update-Asar($Asar, $AsarPatches) {
  $changed = @{}   # 'dir/file' -> new content

  foreach ($patch in $AsarPatches) {
    if ($patch.path) {
      $filePath = $patch.path
      if (-not $Asar.Files[$filePath]) { throw "$($patch.asar) has no file $filePath." }
    } else {
      $needle = Get-AsciiBytes $patch.from
      $count = [ByteSearch]::Count($Asar.Bytes, $needle, [int]$Asar.DataStart, $Asar.Bytes.Length)
      if ($count -ne 1) {
        if ($count -eq 0) { throw "'$($patch.from)' not found in $($patch.asar). This Claude version changed the code; the patch does not apply." }
        throw "'$($patch.from)' occurs $count times in $($patch.asar), expected 1."
      }
      $pos = [ByteSearch]::IndexOf($Asar.Bytes, $needle, [int]$Asar.DataStart, $Asar.Bytes.Length) - $Asar.DataStart
      $filePath = $Asar.Files.Keys | Where-Object {
        $e = $Asar.Files[$_]; $pos -ge [long]$e.offset -and $pos -lt [long]$e.offset + $e.size
      } | Select-Object -First 1
      if (-not $filePath) { throw "Could not map '$($patch.from)' to a file in $($patch.asar)." }
    }

    $entry = $Asar.Files[$filePath]
    $text = if ($changed[$filePath]) { $Latin1.GetString($changed[$filePath]) }
            else { $Latin1.GetString($Asar.Bytes, [int]($Asar.DataStart + [long]$entry.offset), [int]$entry.size) }
    $i = $text.IndexOf($patch.from, [StringComparison]::Ordinal)
    if ($i -lt 0) { throw "'$($patch.from)' not found in $filePath. This Claude version changed the code; the patch does not apply." }
    $changed[$filePath] = $Latin1.GetBytes($text.Substring(0, $i) + $patch.to + $text.Substring($i + $patch.from.Length))
    Write-Host "  $($patch.name): $filePath"
  }

  # Header: new size and integrity for each changed file (its offset string is unique).
  $json = $Asar.Json
  foreach ($filePath in $changed.Keys) {
    $entry = $Asar.Files[$filePath]
    $content = $changed[$filePath]
    $blockSize = [long]$entry.integrity.blockSize
    $blocks = for ($off = 0L; $off -lt $content.Length; $off += $blockSize) {
      Get-Sha256Hex $content $off ([Math]::Min($blockSize, $content.Length - $off))
    }
    $old = Get-EntryJson $entry $entry.size $entry.integrity.hash $entry.integrity.blocks
    $new = Get-EntryJson $entry $content.Length (Get-Sha256Hex $content) $blocks
    $k = $json.IndexOf($old, [StringComparison]::Ordinal)
    if ($k -lt 0 -or $json.IndexOf($old, $k + 1, [StringComparison]::Ordinal) -ge 0) {
      throw "Unexpected header entry format for $filePath in $($AsarPatches[0].asar)."
    }
    $json = $json.Substring(0, $k) + $new + $json.Substring($k + $old.Length)
  }

  # Data: splice in the changed files; files after each one shift by the accumulated size delta.
  $data = New-Object IO.MemoryStream
  $cursor = 0L
  $delta = 0L
  $shifts = @()   # (offset, delta): files with a larger offset move by delta
  foreach ($filePath in ($changed.Keys | Sort-Object { [long]$Asar.Files[$_].offset })) {
    $entry = $Asar.Files[$filePath]
    $offset = [long]$entry.offset
    $data.Write($Asar.Bytes, [int]($Asar.DataStart + $cursor), [int]($offset - $cursor))
    $data.Write($changed[$filePath], 0, $changed[$filePath].Length)
    $cursor = $offset + [long]$entry.size
    $delta += $changed[$filePath].Length - [long]$entry.size
    $shifts += , @($offset, $delta)
  }
  $data.Write($Asar.Bytes, [int]($Asar.DataStart + $cursor), [int]($Asar.Bytes.Length - $Asar.DataStart - $cursor))

  $json = [regex]::Replace($json, '"offset":"(\d+)"', {
    param($m)
    $offset = [long]$m.Groups[1].Value
    $shift = 0L
    foreach ($s in $shifts) { if ($offset -gt $s[0]) { $shift = $s[1] } }
    '"offset":"' + ($offset + $shift) + '"'
  })

  $jsonBytes = [Text.Encoding]::UTF8.GetBytes($json)
  $pad = (4 - $jsonBytes.Length % 4) % 4
  $out = New-Object IO.MemoryStream
  foreach ($v in 4, (8 + $jsonBytes.Length + $pad), (4 + $jsonBytes.Length + $pad), $jsonBytes.Length) {
    $out.Write((Get-UInt32Bytes $v), 0, 4)
  }
  $out.Write($jsonBytes, 0, $jsonBytes.Length)
  $out.Write((New-Object byte[] $pad), 0, $pad)
  $data.WriteTo($out)

  @{ Bytes = $out.ToArray(); HeaderHash = Get-Sha256Hex $jsonBytes }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not $PackageDir) { $PackageDir = Find-ClaudePackage }
$appDir = Join-Path $PackageDir 'app'
$resourcesDir = Join-Path $appDir 'resources'
$exePath = Join-Path $appDir 'claude.exe'
Write-Host "Claude: $PackageDir"

if (-not $DryRun -and (Get-Process claude -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$appDir\*" })) {
  throw 'Claude is running. Quit it (including the tray icon) and try again.'
}

$candidates = @($exePath) + @(Get-ChildItem $resourcesDir -Filter *.asar -File | ForEach-Object FullName)

if ($Rollback) {
  $restored = 0
  foreach ($f in $candidates) {
    if (Test-Path "$f.bak") {
      Copy-Item "$f.bak" $f -Force
      Remove-Item "$f.bak" -Force
      Write-Host "  restored $(Split-Path $f -Leaf)"
      $restored++
    }
  }
  if (-not $restored) { throw 'No backups (*.bak) found; nothing to restore.' }
  Write-Host 'Original files restored.'
  return
}

# Build everything in memory from the originals.
$exeSource = Get-SourcePath $exePath
$exeBytes = [IO.File]::ReadAllBytes($exeSource)
$outputs = @()

foreach ($asarName in @($Patches | ForEach-Object { $_.asar } | Select-Object -Unique)) {
  $asarPath = Join-Path $resourcesDir $asarName
  $asar = Read-Asar (Get-SourcePath $asarPath)

  $oldHash = Get-AsciiBytes $asar.HeaderHash
  if ([ByteSearch]::Count($exeBytes, $oldHash, 0, $exeBytes.Length) -ne 1) {
    throw "The original $asarName hash is not in $(Split-Path $exeSource -Leaf). The files were modified without clean backups; reinstall Claude and run again."
  }

  $patched = Update-Asar $asar @($Patches | Where-Object { $_.asar -eq $asarName })
  $at = [ByteSearch]::IndexOf($exeBytes, $oldHash, 0, $exeBytes.Length)
  [Array]::Copy((Get-AsciiBytes $patched.HeaderHash), 0, $exeBytes, $at, $oldHash.Length)
  $outputs += @{ Path = $asarPath; Bytes = $patched.Bytes }
}
$outputs += @{ Path = $exePath; Bytes = $exeBytes }

# Files patched by an earlier version of this script but not anymore go back to the original.
$outputPaths = @($outputs | ForEach-Object { $_.Path })
$stale = @($candidates | Where-Object { (Test-Path "$_.bak") -and $outputPaths -notcontains $_ })

if ($DryRun) {
  $dir = Join-Path $env:TEMP 'claude-native-titlebar'
  New-Item -ItemType Directory -Force $dir | Out-Null
  foreach ($o in $outputs) { [IO.File]::WriteAllBytes((Join-Path $dir (Split-Path $o.Path -Leaf)), $o.Bytes) }
  foreach ($f in $stale) { Write-Host "  would restore $(Split-Path $f -Leaf)" }
  Write-Host "Dry run: patched files written to $dir. Installation untouched."
  return
}

foreach ($o in $outputs) { if (-not (Test-Path "$($o.Path).bak")) { Copy-Item $o.Path "$($o.Path).bak" } }

# Keep the current files until every write succeeds, so a failure leaves things as they were.
$touched = $outputPaths + $stale
foreach ($f in $touched) { Copy-Item $f "$f.prev" -Force }
try {
  foreach ($o in $outputs) { [IO.File]::WriteAllBytes($o.Path, $o.Bytes) }
  foreach ($f in $stale) { Copy-Item "$f.bak" $f -Force; Write-Host "  restored $(Split-Path $f -Leaf)" }
} catch {
  foreach ($f in $touched) { Copy-Item "$f.prev" $f -Force }
  throw "Writing failed; files were left unchanged. $_"
} finally {
  foreach ($f in $touched) { Remove-Item "$f.prev" -Force -ErrorAction SilentlyContinue }
}
foreach ($f in $stale) { Remove-Item "$f.bak" -Force }

Write-Host 'Done. Start Claude. To undo: .\claude-native-titlebar.ps1 -Rollback'
