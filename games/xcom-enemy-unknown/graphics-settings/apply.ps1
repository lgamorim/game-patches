# XCOM: Enemy Unknown / Enemy Within graphics settings patch.
#
#   apply.ps1 apply|restore|status [--game-dir <path>] [--target eu|ew] [--quiet]
#
# Merges settings.ini (an overlay of [Section] Key=Value lines) into the game's
# Engine\Config\BaseEngine.ini:
#
#   - an overlay key that exists in its section has its value replaced on that line;
#   - a missing key is inserted after the last setting of its section;
#   - a missing section is created at the end of the file.
#
# Every other line stays byte-for-byte as it was, and the file keeps its encoding (byte
# order mark, if any) and line endings.
#
# Safety:
#   - nothing is written while XComGame.exe or XComEW.exe is running;
#   - a backup is taken only of a stock file (none of the overlay values present), into
#     backup\enemy-unknown\ or backup\enemy-within\ next to this script, never into the game;
#   - a partially patched file is only touched when a backup already exists;
#   - every write goes through a temporary file and is read back and verified;
#   - restore copies the backup back and verifies it by SHA-256.

$SteamAppId = '200510'   # XCOM: Enemy Unknown on Steam; Enemy Within installs into its XEW folder.

$Usage = @'
Usage: Apply.cmd | Restore.cmd | Status.cmd [options]
       powershell -File apply.ps1 apply|restore|status [options]

Options:
  --game-dir <path>   The XCOM: Enemy Unknown install folder, or its XEW folder for
                      Enemy Within only. Default: the XCOM_EU_DIR environment variable,
                      then Steam detection.
  --target eu|ew      Only Enemy Unknown (eu) or only Enemy Within (ew).
                      Default: every installed one.
  --quiet             Only print errors (status still prints its report).
'@

# --- Output -------------------------------------------------------------------------------

$script:Quiet = $false

function Write-Info([string]$Message) {
    if (-not $script:Quiet) { Write-Host $Message }
}

function Write-Problem([string]$Message) {
    Write-Host "error: $Message" -ForegroundColor Red
}

# --- Text files: bytes in, bytes out ------------------------------------------------------

function Get-Latin1 {
    # ISO-8859-1 maps every byte to one character and back, so any file without a UTF-16
    # byte order mark round-trips exactly, whatever its real encoding.
    return [Text.Encoding]::GetEncoding(28591)
}

function Read-IniFile([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $encoding = Get-Latin1
    $preambleLength = 0
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = New-Object System.Text.UnicodeEncoding($false, $false)
        $preambleLength = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = New-Object System.Text.UnicodeEncoding($true, $false)
        $preambleLength = 2
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $preambleLength = 3
    }
    $preamble = New-Object byte[] $preambleLength
    [Array]::Copy($bytes, $preamble, $preambleLength)
    return [pscustomobject]@{
        Bytes    = $bytes
        Preamble = $preamble
        Encoding = $encoding
        Text     = $encoding.GetString($bytes, $preambleLength, $bytes.Length - $preambleLength)
    }
}

function ConvertTo-IniBytes($File, [string]$Text) {
    $body = $File.Encoding.GetBytes($Text)
    $stream = New-Object System.IO.MemoryStream
    $stream.Write($File.Preamble, 0, $File.Preamble.Length)
    $stream.Write($body, 0, $body.Length)
    return ,$stream.ToArray()
}

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Write-BytesAtomically([string]$Path, [byte[]]$Bytes) {
    # Write next to the target, then swap it in, so the game file is never half-written.
    $tmp = "$Path.graphics-settings-tmp"
    [IO.File]::WriteAllBytes($tmp, $Bytes)
    try {
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($tmp, $Path, [NullString]::Value)
        } else {
            [IO.File]::Move($tmp, $Path)
        }
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

# --- INI lines ----------------------------------------------------------------------------

function New-IniLine([string]$Content, [string]$Eol) {
    $kind = 'other'
    $name = $null
    if ($Content -match '^\s*\[\s*([^\]]*?)\s*\]\s*$') {
        $kind = 'section'
        $name = $Matches[1]
    } elseif ($Content -match '^\s*$' -or $Content -match '^\s*(;|#|//)') {
        $kind = 'other'
    } elseif ($Content -match '^\s*([^=]*?)\s*=') {
        if ($Matches[1]) {
            $kind = 'setting'
            $name = $Matches[1]
        }
    }
    return [pscustomobject]@{ Content = $Content; Eol = $Eol; Kind = $kind; Name = $name }
}

function Split-IniLines([string]$Text) {
    $lines = New-Object 'System.Collections.Generic.List[object]'
    foreach ($m in [regex]::Matches($Text, '([^\r\n]*)(\r\n|\n|\r|$)')) {
        if ($m.Length -eq 0) { continue }   # the empty match at the very end
        $lines.Add((New-IniLine $m.Groups[1].Value $m.Groups[2].Value))
    }
    return ,$lines
}

function Join-IniLines($Lines) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($line in $Lines) {
        [void]$sb.Append($line.Content)
        [void]$sb.Append($line.Eol)
    }
    return $sb.ToString()
}

function Get-DominantEol($Lines) {
    $counts = @{ "`r`n" = 0; "`n" = 0; "`r" = 0 }
    foreach ($line in $Lines) {
        if ($line.Eol) { $counts[$line.Eol]++ }
    }
    if ($counts["`n"] -gt $counts["`r`n"] -and $counts["`n"] -ge $counts["`r"]) { return "`n" }
    if ($counts["`r"] -gt $counts["`r`n"] -and $counts["`r"] -gt $counts["`n"]) { return "`r" }
    return "`r`n"
}

function Get-IniSections($Lines) {
    # One entry per [Section] header: its line index and the index where it ends (exclusive).
    $sections = New-Object 'System.Collections.Generic.List[object]'
    $current = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Kind -eq 'section') {
            if ($current) { $current.End = $i }
            $current = [pscustomobject]@{ Name = $Lines[$i].Name; Header = $i; End = $Lines.Count }
            $sections.Add($current)
        }
    }
    return ,$sections
}

function Find-Section($Sections, [string]$Name) {
    $found = @($Sections | Where-Object { $_.Name -ieq $Name })
    if ($found.Count -gt 1) {
        throw "[$Name] appears $($found.Count) times in the file; refusing to guess which one to change."
    }
    if ($found.Count -eq 1) { return $found[0] }
    return $null
}

function Find-SettingLines($Lines, $Section, [string]$Key) {
    $hits = New-Object 'System.Collections.Generic.List[int]'
    for ($i = $Section.Header + 1; $i -lt $Section.End; $i++) {
        if ($Lines[$i].Kind -eq 'setting' -and $Lines[$i].Name -ieq $Key) { $hits.Add($i) }
    }
    if ($hits.Count -gt 1) {
        throw "$Key appears $($hits.Count) times in [$($Section.Name)] (array-style lines); refusing to guess which one to change."
    }
    return ,$hits
}

function Get-SettingValue([string]$Content) {
    return ([regex]::Match($Content, '^[^=]*=(.*)$')).Groups[1].Value.Trim()
}

# --- Overlay ------------------------------------------------------------------------------

function ConvertFrom-OverlayText([string]$Text) {
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $section = $null
    $number = 0
    foreach ($line in (Split-IniLines $Text)) {
        $number++
        $content = $line.Content
        if ($line.Kind -eq 'section') {
            $section = $line.Name
            continue
        }
        if ($content -match '^\s*$' -or $content -match '^\s*(;|#|//)') { continue }
        if ($line.Kind -ne 'setting') {
            throw "settings.ini line ${number}: expected [Section], Key=Value or a ; comment, got '$content'."
        }
        if ($null -eq $section) {
            throw "settings.ini line ${number}: '$content' comes before any [section]."
        }
        $key = $line.Name
        if ($key -match '^[+\-.!]') {
            throw "settings.ini line ${number}: '$key' uses UE3 array syntax (+, -, . or !), which this patch does not merge."
        }
        $id = "$section`n$key"
        if ($seen.ContainsKey($id)) {
            throw "settings.ini line ${number}: $key is set more than once in [$section]."
        }
        $seen[$id] = $true
        $entries.Add([pscustomobject]@{ Section = $section; Key = $key; Value = (Get-SettingValue $content) })
    }
    if ($entries.Count -eq 0) { throw 'settings.ini has no settings.' }
    return $entries.ToArray()
}

function Read-Overlay([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "settings.ini not found: $Path"
    }
    return ConvertFrom-OverlayText (Read-IniFile $Path).Text
}

# --- State and merge ----------------------------------------------------------------------

function Get-IniState([string]$Text, $Overlay) {
    $entries = @($Overlay)
    $lines = Split-IniLines $Text
    $sections = Get-IniSections $lines
    $present = 0
    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $entries) {
        $section = Find-Section $sections $entry.Section
        $ok = $false
        if ($section) {
            $hits = Find-SettingLines $lines $section $entry.Key
            if ($hits.Count -eq 1) {
                $ok = [string]::Equals((Get-SettingValue $lines[$hits[0]].Content), $entry.Value, [StringComparison]::Ordinal)
            }
        }
        if ($ok) { $present++ } else { $missing.Add("[$($entry.Section)] $($entry.Key)") }
    }
    $state = 'partial'
    if ($present -eq 0) { $state = 'stock' }
    elseif ($present -eq $entries.Count) { $state = 'patched' }
    return [pscustomobject]@{ State = $state; Present = $present; Total = $entries.Count; Missing = $missing.ToArray() }
}

function Merge-IniText([string]$Text, $Overlay) {
    $lines = Split-IniLines $Text
    $eol = Get-DominantEol $lines
    $noFinalEol = ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Eol -eq '')

    foreach ($entry in @($Overlay)) {
        $section = Find-Section (Get-IniSections $lines) $entry.Section
        $newSetting = "$($entry.Key)=$($entry.Value)"

        if ($null -eq $section) {
            # New section at the end of the file, after a blank line.
            if ($lines.Count -gt 0) {
                $last = $lines[$lines.Count - 1]
                if ($last.Eol -eq '') { $last.Eol = $eol }
                if ($last.Content.Trim() -ne '') { $lines.Add((New-IniLine '' $eol)) }
            }
            $lines.Add((New-IniLine "[$($entry.Section)]" $eol))
            $lines.Add((New-IniLine $newSetting $eol))
            continue
        }

        $hits = Find-SettingLines $lines $section $entry.Key
        if ($hits.Count -eq 1) {
            # Replace the value, keeping the key's spelling and the spacing around '='.
            $index = $hits[0]
            $old = $lines[$index]
            if (-not [string]::Equals((Get-SettingValue $old.Content), $entry.Value, [StringComparison]::Ordinal)) {
                $prefix = ([regex]::Match($old.Content, '^[^=]*=\s*')).Value
                $lines[$index] = New-IniLine ($prefix + $entry.Value) $old.Eol
            }
            continue
        }

        # Insert after the section's last setting (or its header), so blank lines and
        # comments that lead into the next section stay where they are.
        $after = $section.Header
        for ($i = $section.Header + 1; $i -lt $section.End; $i++) {
            if ($lines[$i].Kind -eq 'setting') { $after = $i }
        }
        if ($lines[$after].Eol -eq '') { $lines[$after].Eol = $eol }
        $lines.Insert($after + 1, (New-IniLine $newSetting $eol))
    }

    if ($noFinalEol -and $lines.Count -gt 0) { $lines[$lines.Count - 1].Eol = '' }
    return Join-IniLines $lines
}

function Update-IniFile([string]$Path, $Overlay) {
    # Merges the overlay into the file, writes it only if something changed, then verifies.
    $file = Read-IniFile $Path
    $merged = Merge-IniText -Text $file.Text -Overlay $Overlay
    if ([string]::Equals($merged, $file.Text, [StringComparison]::Ordinal)) {
        return [pscustomobject]@{ Changed = $false }
    }
    $bytes = ConvertTo-IniBytes $file $merged
    Write-BytesAtomically $Path $bytes
    $written = Read-IniFile $Path
    if ((Get-Sha256Hex $written.Bytes) -ne (Get-Sha256Hex $bytes)) {
        throw "$Path does not read back as written."
    }
    $state = Get-IniState -Text $written.Text -Overlay $Overlay
    if ($state.State -ne 'patched') {
        throw "after writing, only $($state.Present) of $($state.Total) settings verify in $Path."
    }
    return [pscustomobject]@{ Changed = $true }
}

# --- Options ------------------------------------------------------------------------------

function ConvertFrom-Arguments([string[]]$Arguments) {
    $options = [pscustomobject]@{ Verb = $null; GameDir = $null; Target = $null; Quiet = $false; Help = $false }
    if ($null -eq $Arguments) { $Arguments = @() }
    $i = 0
    while ($i -lt $Arguments.Count) {
        $arg = $Arguments[$i]
        if ($arg -like '-*') {
            $name = $arg
            $value = $null
            $inline = $false
            $eq = $arg.IndexOf('=')
            if ($arg.StartsWith('--') -and $eq -gt 2) {
                $name = $arg.Substring(0, $eq)
                $value = $arg.Substring($eq + 1)
                $inline = $true
            }
            switch ($name) {
                '--game-dir' {
                    if (-not $inline) {
                        $i++
                        if ($i -ge $Arguments.Count) { throw '--game-dir needs a value: the game''s install folder.' }
                        $value = $Arguments[$i]
                    }
                    # A quoted path ending in \ arrives from cmd.exe with a stray quote.
                    $value = $value.Trim().Trim('"')
                    if (-not $value) { throw '--game-dir needs a value: the game''s install folder.' }
                    $options.GameDir = $value
                }
                '--target' {
                    if (-not $inline) {
                        $i++
                        if ($i -ge $Arguments.Count) { throw '--target needs a value: eu or ew.' }
                        $value = $Arguments[$i]
                    }
                    $value = $value.Trim().ToLowerInvariant()
                    if ($value -ne 'eu' -and $value -ne 'ew') {
                        throw "--target must be eu (Enemy Unknown) or ew (Enemy Within), not '$value'."
                    }
                    $options.Target = $value
                }
                '--quiet' {
                    if ($inline) { throw '--quiet takes no value.' }
                    $options.Quiet = $true
                }
                { $_ -eq '--help' -or $_ -eq '-h' } {
                    $options.Help = $true
                }
                default {
                    throw "unknown option: $name (expected --game-dir, --target or --quiet)."
                }
            }
        } else {
            if ($options.Verb) { throw "unexpected argument: '$arg'." }
            $verb = $arg.ToLowerInvariant()
            if ($verb -ne 'apply' -and $verb -ne 'restore' -and $verb -ne 'status') {
                throw "unknown command '$arg': use apply, restore or status."
            }
            $options.Verb = $verb
        }
        $i++
    }
    if (-not $options.Verb -and -not $options.Help) { throw 'no command given: use apply, restore or status.' }
    return $options
}

# --- Finding the game ---------------------------------------------------------------------

function ConvertFrom-VdfString([string]$Value) {
    return [regex]::Replace($Value, '\\(.)', '$1')
}

function ConvertFrom-LibraryFoldersVdf([string]$Text) {
    foreach ($m in [regex]::Matches($Text, '"path"\s+"((?:[^"\\]|\\.)*)"')) {
        ConvertFrom-VdfString $m.Groups[1].Value
    }
}

function Get-AcfInstallDir([string]$Text) {
    $m = [regex]::Match($Text, '"installdir"\s+"((?:[^"\\]|\\.)*)"')
    if ($m.Success) { return ConvertFrom-VdfString $m.Groups[1].Value }
    return $null
}

function Find-SteamInstall {
    $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { return $null }
    $steam = $steam.Replace('/', '\')
    $libraries = New-Object 'System.Collections.Generic.List[string]'
    $libraries.Add($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf -PathType Leaf) {
        foreach ($path in (ConvertFrom-LibraryFoldersVdf ([IO.File]::ReadAllText($vdf)))) {
            if (-not ($libraries -contains $path)) { $libraries.Add($path) }
        }
    }
    foreach ($library in $libraries) {
        $manifest = Join-Path $library "steamapps\appmanifest_$SteamAppId.acf"
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
        $dir = Get-AcfInstallDir ([IO.File]::ReadAllText($manifest))
        if (-not $dir) { continue }
        $install = Join-Path $library "steamapps\common\$dir"
        if (Test-Path -LiteralPath $install -PathType Container) { return $install }
    }
    return $null
}

function New-Target([string]$Key, [string]$File) {
    if ($Key -eq 'eu') {
        return [pscustomobject]@{ Key = 'eu'; Name = 'Enemy Unknown'; BackupName = 'enemy-unknown'; File = $File }
    }
    return [pscustomobject]@{ Key = 'ew'; Name = 'Enemy Within'; BackupName = 'enemy-within'; File = $File }
}

function Resolve-Targets($Options) {
    if ($Options.GameDir) {
        $root = $Options.GameDir
        $source = '--game-dir'
    } elseif ($env:XCOM_EU_DIR) {
        $root = $env:XCOM_EU_DIR.Trim().Trim('"')
        $source = 'XCOM_EU_DIR'
    } else {
        $root = Find-SteamInstall
        $source = 'Steam'
        if (-not $root) {
            throw 'could not find XCOM: Enemy Unknown through Steam. Run again with --game-dir "<install folder>" (or set XCOM_EU_DIR).'
        }
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "'$root' (from $source) is not a folder."
    }
    $root = (Resolve-Path -LiteralPath $root).ProviderPath
    if ($root.Length -gt 3) { $root = $root.TrimEnd('\') }

    $engineIni = Join-Path $root 'Engine\Config\BaseEngine.ini'
    if (-not (Test-Path -LiteralPath $engineIni -PathType Leaf)) {
        throw "'$root' (from $source) has no Engine\Config\BaseEngine.ini. Point --game-dir at the XCOM: Enemy Unknown install folder, the one that holds Engine, XComGame and XEW."
    }

    $isXew = ((Split-Path -Leaf $root) -ieq 'XEW') -or (Test-Path -LiteralPath (Join-Path $root 'Binaries\Win32\XComEW.exe') -PathType Leaf)
    if ($isXew) {
        $targets = @(New-Target 'ew' $engineIni)
        if ($Options.Target -eq 'eu') {
            throw "--target eu does not apply: '$root' is the XEW folder, which only holds Enemy Within. Point --game-dir at its parent folder."
        }
    } else {
        $targets = @((New-Target 'eu' $engineIni), (New-Target 'ew' (Join-Path $root 'XEW\Engine\Config\BaseEngine.ini')))
        if ($Options.Target) { $targets = @($targets | Where-Object { $_.Key -eq $Options.Target }) }
    }
    return [pscustomobject]@{ Root = $root; Source = $source; Targets = $targets }
}

function Test-GameRunning {
    $running = @(Get-Process -Name 'XComGame', 'XComEW' -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { return $null }
    return (@($running | ForEach-Object { "$($_.ProcessName).exe" } | Sort-Object -Unique) -join ', ')
}

# --- Verbs --------------------------------------------------------------------------------

function Get-BackupPath([string]$BackupRoot, $Target) {
    return Join-Path (Join-Path $BackupRoot $Target.BackupName) 'BaseEngine.ini'
}

function Get-BackupLabel($Target) {
    return "backup\$($Target.BackupName)\BaseEngine.ini"
}

function Invoke-ApplyTarget($Target, $Overlay, [string]$BackupRoot) {
    $file = Read-IniFile $Target.File
    $state = Get-IniState -Text $file.Text -Overlay $Overlay
    $backup = Get-BackupPath $BackupRoot $Target
    $hasBackup = Test-Path -LiteralPath $backup -PathType Leaf

    if ($state.State -eq 'patched') {
        Write-Info '  already patched; nothing to do.'
        if (-not $hasBackup) { Write-Info '  (no backup here: Restore will point you to Steam''s "Verify integrity of game files".)' }
        return $true
    }

    if ($state.State -eq 'partial') {
        if (-not $hasBackup) {
            Write-Problem ("$($Target.Name): BaseEngine.ini is partially patched ($($state.Present) of $($state.Total) settings) and there is no backup of the stock file. " +
                'Refusing to change it, because Restore could not undo that afterwards. ' +
                'Get the stock file back with Steam > right-click XCOM: Enemy Unknown > Properties > Installed Files > "Verify integrity of game files", then run Apply again.')
            return $false
        }
        Write-Info "  partially patched ($($state.Present) of $($state.Total) settings); completing it. Keeping the existing backup."
    } else {
        # Stock: back up exactly the bytes that were just classified.
        $dir = Split-Path -Parent $backup
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Write-BytesAtomically $backup $file.Bytes
        if ((Get-Sha256Hex ([IO.File]::ReadAllBytes($backup))) -ne (Get-Sha256Hex $file.Bytes)) {
            throw "the backup $(Get-BackupLabel $Target) does not verify; nothing was changed in the game."
        }
        Write-Info "  backed up the stock file to $(Get-BackupLabel $Target)"
    }

    $result = Update-IniFile -Path $Target.File -Overlay $Overlay
    if ($result.Changed) {
        Write-Info "  patched: $($state.Total - $state.Present) of $($state.Total) settings changed, all $($state.Total) verified."
    }
    return $true
}

function Invoke-RestoreTarget($Target, $Overlay, [string]$BackupRoot) {
    $file = Read-IniFile $Target.File
    $state = Get-IniState -Text $file.Text -Overlay $Overlay
    $backup = Get-BackupPath $BackupRoot $Target

    if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
        if ($state.State -eq 'stock') {
            Write-Info '  already stock; nothing to restore.'
            return $true
        }
        Write-Problem ("$($Target.Name): there is no backup in $(Get-BackupLabel $Target). " +
            'To get the stock file back: Steam > right-click XCOM: Enemy Unknown > Properties > Installed Files > "Verify integrity of game files".')
        return $false
    }

    $backupBytes = [IO.File]::ReadAllBytes($backup)
    $backupHash = Get-Sha256Hex $backupBytes
    if ((Get-Sha256Hex $file.Bytes) -eq $backupHash) {
        Write-Info '  already matches the backup; nothing to restore.'
        return $true
    }
    if ($state.State -eq 'stock') {
        Write-Info '  already stock (none of the patch''s settings are present), so it is left as it is. The backup is older than this file, probably from before a game update.'
        return $true
    }
    $backupState = Get-IniState -Text (Read-IniFile $backup).Text -Overlay $Overlay
    if ($backupState.State -ne 'stock') {
        Write-Problem ("$($Target.Name): $(Get-BackupLabel $Target) is not a stock file, so it is not restored. " +
            'Use Steam''s "Verify integrity of game files" instead, then delete that backup.')
        return $false
    }

    Write-BytesAtomically $Target.File $backupBytes
    if ((Get-Sha256Hex ([IO.File]::ReadAllBytes($Target.File))) -ne $backupHash) {
        throw 'the restored file does not match the backup. Use Steam''s "Verify integrity of game files" to recover.'
    }
    Write-Info '  restored the stock file (SHA-256 verified).'
    return $true
}

function Get-StatusText($Target, $Overlay, [string]$BackupRoot) {
    $state = Get-IniState -Text (Read-IniFile $Target.File).Text -Overlay $Overlay
    $text = switch ($state.State) {
        'stock'   { 'stock' }
        'patched' { 'patched' }
        default   { "partially patched ($($state.Present) of $($state.Total) settings)" }
    }
    $backup = if (Test-Path -LiteralPath (Get-BackupPath $BackupRoot $Target) -PathType Leaf) { 'yes' } else { 'no' }
    return "$text; backup: $backup"
}

function Invoke-Main([string[]]$Arguments, [string]$OverlayPath, [string]$BackupRoot, [scriptblock]$IsGameRunning = { Test-GameRunning }) {
    $ErrorActionPreference = 'Stop'
    $script:Quiet = $false
    try {
        $options = ConvertFrom-Arguments $Arguments
        $script:Quiet = $options.Quiet
        if ($options.Help) {
            Write-Host $Usage
            return 0
        }
        $overlay = Read-Overlay $OverlayPath
        $resolved = Resolve-Targets $options

        if ($options.Verb -eq 'status') {
            Write-Host "Game folder: $($resolved.Root) (from $($resolved.Source))"
        } else {
            Write-Info "Game folder: $($resolved.Root) (from $($resolved.Source))"
            $running = & $IsGameRunning
            if ($running) {
                $which = if ($running -is [string]) { " ($running)" } else { '' }
                throw "XCOM is running$which. Close the game and try again."
            }
        }

        $ok = $true
        foreach ($target in $resolved.Targets) {
            $label = '{0,-14}' -f $target.Name
            if (-not (Test-Path -LiteralPath $target.File -PathType Leaf)) {
                if ($options.Target) {
                    Write-Problem "$($target.Name) is not installed (no $($target.File))."
                    $ok = $false
                } elseif ($options.Verb -eq 'status') {
                    Write-Host "${label}: not installed"
                } else {
                    Write-Info "${label}: not installed; skipped."
                }
                continue
            }
            try {
                if ($options.Verb -eq 'status') {
                    Write-Host "${label}: $(Get-StatusText $target $overlay $BackupRoot)"
                    continue
                }
                Write-Info "${label}: $($target.File)"
                if ($options.Verb -eq 'apply') {
                    $done = Invoke-ApplyTarget $target $overlay $BackupRoot
                } else {
                    $done = Invoke-RestoreTarget $target $overlay $BackupRoot
                }
                if (-not $done) { $ok = $false }
            } catch {
                Write-Problem "$($target.Name): $($_.Exception.Message)"
                $ok = $false
            }
        }
        if ($ok) { return 0 }
        return 1
    } catch {
        Write-Problem $_.Exception.Message
        return 1
    }
}

# Run only when started as a script, not when dot-sourced by the tests.
if ($MyInvocation.InvocationName -ne '.') {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    exit (Invoke-Main -Arguments $args -OverlayPath (Join-Path $here 'settings.ini') -BackupRoot (Join-Path $here 'backup'))
}
