# XCOM: Enemy Unknown / Enemy Within graphics settings patch.
#
#   apply.ps1 apply|restore|status [--game-dir <path>] [--target eu|ew] [--quiet]
#
# Merges two overlays into each game's config files:
#
#   base-engine.ini     -> Engine\Config\BaseEngine.ini
#   default-engine.ini  -> XComGame\Config\DefaultEngine.ini
#
# An overlay holds [Section] lines followed by one of two kinds of entries:
#
#   Key=Value        replaces the value on the key's line in that section; a missing key is
#                    inserted after the section's last setting, and a missing section is
#                    created at the end of the file;
#   Key.Field=Value  changes one field inside the key's (Field=...,Field=...) value and leaves
#                    the rest of the line as it is; it never inserts, so a missing key,
#                    section or field is an error.
#
# Every other line stays byte-for-byte as it was, and the file keeps its encoding (byte
# order mark, if any) and line endings.
#
# Safety, for each file on its own:
#   - nothing is written while XComGame.exe or XComEW.exe is running;
#   - a backup is taken only of a stock file (none of the overlay values present), into
#     backup\enemy-unknown\ or backup\enemy-within\ next to this script, never into the game;
#   - a partially patched file is only touched when a backup already exists;
#   - every write goes through a temporary file and is read back and verified;
#   - restore copies the backup back and verifies it by SHA-256.
#
# The per-user XComEngine.ini in Documents\My Games is only ever read (by status): the game
# rebuilds it from these files when they change.

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

function Get-StructField([string]$Content, [string]$Field) {
    # Finds Field in a line like Key=(A=1,Field=x,B=(C=2)) and returns where its value sits
    # in the line. Only top-level fields count: nested (...) and "..." are skipped over.
    $eq = $Content.IndexOf('=')
    $open = $eq + 1
    while ($open -lt $Content.Length -and [char]::IsWhiteSpace($Content[$open])) { $open++ }
    if ($open -ge $Content.Length -or $Content[$open] -ne '(') { throw 'is not a (...) value' }

    $depth = 0
    $inQuotes = $false
    $close = -1
    $segmentStarts = New-Object 'System.Collections.Generic.List[int]'
    $segmentEnds = New-Object 'System.Collections.Generic.List[int]'
    $segmentStarts.Add($open + 1)
    for ($i = $open; $i -lt $Content.Length; $i++) {
        $c = $Content[$i]
        if ($c -eq '"') { $inQuotes = -not $inQuotes; continue }
        if ($inQuotes) { continue }
        if ($c -eq '(') { $depth++ }
        elseif ($c -eq ')') {
            $depth--
            if ($depth -eq 0) { $close = $i; break }
        } elseif ($c -eq ',' -and $depth -eq 1) {
            $segmentEnds.Add($i)
            $segmentStarts.Add($i + 1)
        }
    }
    if ($close -lt 0 -or $Content.Substring($close + 1).Trim() -ne '') { throw 'is not a (...) value' }
    $segmentEnds.Add($close)

    $found = New-Object 'System.Collections.Generic.List[object]'
    for ($s = 0; $s -lt $segmentStarts.Count; $s++) {
        $start = $segmentStarts[$s]
        $segment = $Content.Substring($start, $segmentEnds[$s] - $start)
        $m = [regex]::Match($segment, '^(\s*)([^=\s]+)(\s*=\s*)(.*?)\s*$', [Text.RegularExpressions.RegexOptions]::Singleline)
        if ($m.Success -and $m.Groups[2].Value -ieq $Field) {
            $valueStart = $start + $m.Groups[1].Length + $m.Groups[2].Length + $m.Groups[3].Length
            $found.Add([pscustomobject]@{ Start = $valueStart; Length = $m.Groups[4].Length; Value = $m.Groups[4].Value })
        }
    }
    if ($found.Count -eq 0) { throw "has no $Field field" }
    if ($found.Count -gt 1) { throw "has $Field more than once (it appears $($found.Count) times)" }
    return $found[0]
}

function Get-EntryLabel($Entry) {
    if ($Entry.Field) { return "[$($Entry.Section)] $($Entry.Key).$($Entry.Field)" }
    return "[$($Entry.Section)] $($Entry.Key)"
}

# --- Overlay ------------------------------------------------------------------------------

function ConvertFrom-OverlayText([string]$Text, [string]$Label = 'overlay') {
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}       # section + key + field, to catch repeats
    $wholeKeys = @{}  # section + key set as a whole
    $fieldKeys = @{}  # section + key set by field
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
            throw "$Label line ${number}: expected [Section], Key=Value, Key.Field=Value or a ; comment, got '$content'."
        }
        if ($null -eq $section) {
            throw "$Label line ${number}: '$content' comes before any [section]."
        }
        $key = $line.Name
        if ($key -match '^[+\-.!]') {
            throw "$Label line ${number}: '$key' uses UE3 array syntax (+, -, . or !), which this patch does not merge."
        }
        $field = $null
        if ($key.Contains('.')) {
            $parts = $key.Split('.')
            if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) {
                throw "$Label line ${number}: '$key' is not Key.Field (one key, one dot, one field name)."
            }
            $key = $parts[0]
            $field = $parts[1]
        }
        $keyId = "$section`n$key"
        $id = "$keyId`n$field"
        if ($seen.ContainsKey($id)) {
            $name = if ($field) { "$key.$field" } else { $key }
            throw "$Label line ${number}: $name is set more than once in [$section]."
        }
        if (($field -and $wholeKeys.ContainsKey($keyId)) -or (-not $field -and $fieldKeys.ContainsKey($keyId))) {
            throw "$Label line ${number}: $key is set both as a whole and by field in [$section]."
        }
        $seen[$id] = $true
        if ($field) { $fieldKeys[$keyId] = $true } else { $wholeKeys[$keyId] = $true }
        $entries.Add([pscustomobject]@{ Section = $section; Key = $key; Field = $field; Value = (Get-SettingValue $content) })
    }
    if ($entries.Count -eq 0) { throw "$Label has no settings." }
    return $entries.ToArray()
}

function Read-Overlay([string]$Path) {
    $label = Split-Path -Leaf $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$label not found: $Path"
    }
    return ConvertFrom-OverlayText (Read-IniFile $Path).Text $label
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
                $content = $lines[$hits[0]].Content
                if ($entry.Field) {
                    # A value that is not a struct or lacks the field simply isn't patched;
                    # the merge reports why if it is asked to change it.
                    $current = $null
                    try { $current = (Get-StructField $content $entry.Field).Value } catch { $current = $null }
                } else {
                    $current = Get-SettingValue $content
                }
                $ok = ($null -ne $current) -and [string]::Equals($current, $entry.Value, [StringComparison]::Ordinal)
            }
        }
        if ($ok) { $present++ } else { $missing.Add((Get-EntryLabel $entry)) }
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

        if ($entry.Field) {
            # Field edits only change an existing line; they never insert.
            $label = Get-EntryLabel $entry
            if ($null -eq $section) { throw "$label`: section [$($entry.Section)] not found in the file." }
            $hits = Find-SettingLines $lines $section $entry.Key
            if ($hits.Count -eq 0) { throw "$label`: $($entry.Key) not found in [$($entry.Section)]." }
            $index = $hits[0]
            $old = $lines[$index]
            try {
                $spot = Get-StructField $old.Content $entry.Field
            } catch {
                throw "$label`: the value of $($entry.Key) $($_.Exception.Message)."
            }
            if (-not [string]::Equals($spot.Value, $entry.Value, [StringComparison]::Ordinal)) {
                $content = $old.Content.Substring(0, $spot.Start) + $entry.Value + $old.Content.Substring($spot.Start + $spot.Length)
                $lines[$index] = New-IniLine $content $old.Eol
            }
            continue
        }

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

function Get-OverlayLineIndexes($Lines, $Overlay) {
    # Line numbers of the settings this overlay edits (whole values or fields).
    $indexes = New-Object 'System.Collections.Generic.HashSet[int]'
    $sections = Get-IniSections $Lines
    foreach ($entry in @($Overlay)) {
        foreach ($section in @($sections | Where-Object { $_.Name -ieq $entry.Section })) {
            for ($i = $section.Header + 1; $i -lt $section.End; $i++) {
                if ($Lines[$i].Kind -eq 'setting' -and $Lines[$i].Name -ieq $entry.Key) { [void]$indexes.Add($i) }
            }
        }
    }
    return ,$indexes
}

function Test-OnlyOverlayLinesDiffer([string]$Text, [string]$BackupText, $Overlay) {
    # True when Text is BackupText with other values on some of the lines this overlay
    # edits and nothing else changed: the file was patched with other values for the same
    # settings (for example by an earlier version of this patch), not updated by the game.
    $current = Split-IniLines $Text
    $backup = Split-IniLines $BackupText
    if ($current.Count -ne $backup.Count) { return $false }
    $targets = Get-OverlayLineIndexes $current $Overlay
    $differs = $false
    for ($i = 0; $i -lt $current.Count; $i++) {
        if ($current[$i].Content -cne $backup[$i].Content -or $current[$i].Eol -cne $backup[$i].Eol) {
            if (-not $targets.Contains($i) -or $current[$i].Name -ine $backup[$i].Name) { return $false }
            $differs = $true
        }
    }
    return $differs
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

function New-Target([string]$Key, [string]$Root) {
    # Root is the game's own folder: the install folder for Enemy Unknown, XEW for Enemy Within.
    if ($Key -eq 'eu') {
        return [pscustomobject]@{ Key = 'eu'; Name = 'Enemy Unknown'; BackupName = 'enemy-unknown'; UserFolder = 'XCOM - Enemy Unknown'; Root = $Root }
    }
    return [pscustomobject]@{ Key = 'ew'; Name = 'Enemy Within'; BackupName = 'enemy-within'; UserFolder = 'XCOM - Enemy Within'; Root = $Root }
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
        $targets = @(New-Target 'ew' $root)
        if ($Options.Target -eq 'eu') {
            throw "--target eu does not apply: '$root' is the XEW folder, which only holds Enemy Within. Point --game-dir at its parent folder."
        }
    } else {
        $targets = @((New-Target 'eu' $root), (New-Target 'ew' (Join-Path $root 'XEW')))
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

function Get-GameFiles($Target, $Specs, [string]$BackupRoot) {
    # One entry per config file this patch handles for one game.
    $files = New-Object 'System.Collections.Generic.List[object]'
    foreach ($spec in $Specs) {
        $files.Add([pscustomobject]@{
            Game        = $Target.Name
            Name        = $spec.Name
            Path        = Join-Path $Target.Root $spec.Relative
            Overlay     = $spec.Overlay
            Backup      = Join-Path (Join-Path $BackupRoot $Target.BackupName) $spec.Name
            BackupLabel = "backup\$($Target.BackupName)\$($spec.Name)"
        })
    }
    return ,$files
}

function Assert-FileExists($File) {
    if (-not (Test-Path -LiteralPath $File.Path -PathType Leaf)) { throw "not found ($($File.Path))." }
}

function Invoke-ApplyFile($File) {
    # Returns whether it succeeded and whether it wrote to the game file.
    Assert-FileExists $File
    $data = Read-IniFile $File.Path
    $state = Get-IniState -Text $data.Text -Overlay $File.Overlay
    $hasBackup = Test-Path -LiteralPath $File.Backup -PathType Leaf
    $name = $File.Name

    if ($state.State -eq 'patched') {
        Write-Info "  ${name}: already patched; nothing to do."
        if (-not $hasBackup) { Write-Info "  ${name}: (no backup here: Restore will point you to Steam's `"Verify integrity of game files`".)" }
        return [pscustomobject]@{ Ok = $true; Changed = $false }
    }

    if ($state.State -eq 'partial') {
        if (-not $hasBackup) {
            Write-Problem ("$($File.Game): $name is partially patched ($($state.Present) of $($state.Total) settings) and there is no backup of the stock file. " +
                'Refusing to change it, because Restore could not undo that afterwards. ' +
                'Get the stock file back with Steam > right-click XCOM: Enemy Unknown > Properties > Installed Files > "Verify integrity of game files", then run Apply again.')
            return [pscustomobject]@{ Ok = $false; Changed = $false }
        }
        Write-Info "  ${name}: partially patched ($($state.Present) of $($state.Total) settings); completing it. Keeping the existing backup."
    } else {
        # Stock as far as this overlay can tell. If it differs from an existing backup only
        # on the lines this patch edits, it holds other values for the same settings: backing
        # it up would replace the real stock file, so stop instead.
        if ($hasBackup) {
            $backupData = Read-IniFile $File.Backup
            if ((Get-Sha256Hex $backupData.Bytes) -ne (Get-Sha256Hex $data.Bytes) -and
                (Test-OnlyOverlayLinesDiffer $data.Text $backupData.Text $File.Overlay)) {
                Write-Problem ("$($File.Game): $name has other values for this patch's settings than the stock backup in $($File.BackupLabel), " +
                    'for example from an earlier version of this patch. It was not backed up or changed. Run Restore.cmd first, then Apply.cmd.')
                return [pscustomobject]@{ Ok = $false; Changed = $false }
            }
        }
        # Stock: back up exactly the bytes that were just classified.
        $dir = Split-Path -Parent $File.Backup
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Write-BytesAtomically $File.Backup $data.Bytes
        if ((Get-Sha256Hex ([IO.File]::ReadAllBytes($File.Backup))) -ne (Get-Sha256Hex $data.Bytes)) {
            throw "the backup $($File.BackupLabel) does not verify; nothing was changed in the game."
        }
        Write-Info "  ${name}: backed up the stock file to $($File.BackupLabel)"
    }

    $result = Update-IniFile -Path $File.Path -Overlay $File.Overlay
    if ($result.Changed) {
        Write-Info "  ${name}: patched: $($state.Total - $state.Present) of $($state.Total) settings changed, all $($state.Total) verified."
    }
    return [pscustomobject]@{ Ok = $true; Changed = $result.Changed }
}

function Invoke-RestoreFile($File) {
    Assert-FileExists $File
    $data = Read-IniFile $File.Path
    $state = Get-IniState -Text $data.Text -Overlay $File.Overlay
    $name = $File.Name

    if (-not (Test-Path -LiteralPath $File.Backup -PathType Leaf)) {
        if ($state.State -eq 'stock') {
            Write-Info "  ${name}: already stock; nothing to restore."
            return [pscustomobject]@{ Ok = $true; Changed = $false }
        }
        Write-Problem ("$($File.Game): there is no backup of $name in $($File.BackupLabel). " +
            'To get the stock file back: Steam > right-click XCOM: Enemy Unknown > Properties > Installed Files > "Verify integrity of game files".')
        return [pscustomobject]@{ Ok = $false; Changed = $false }
    }

    $backupBytes = [IO.File]::ReadAllBytes($File.Backup)
    $backupHash = Get-Sha256Hex $backupBytes
    if ((Get-Sha256Hex $data.Bytes) -eq $backupHash) {
        Write-Info "  ${name}: already matches the backup; nothing to restore."
        return [pscustomobject]@{ Ok = $true; Changed = $false }
    }
    if ($state.State -eq 'stock') {
        if (Test-OnlyOverlayLinesDiffer $data.Text (Read-IniFile $File.Backup).Text $File.Overlay) {
            Write-Info "  ${name}: has other values for this patch's settings than the stock backup (for example from an earlier version of this patch); restoring the backup."
        } else {
            Write-Info "  ${name}: already stock (none of the patch's settings are present), so it is left as it is. The backup is older than this file, probably from before a game update."
            return [pscustomobject]@{ Ok = $true; Changed = $false }
        }
    }
    $backupState = Get-IniState -Text (Read-IniFile $File.Backup).Text -Overlay $File.Overlay
    if ($backupState.State -ne 'stock') {
        Write-Problem ("$($File.Game): $($File.BackupLabel) is not a stock file, so it is not restored. " +
            'Use Steam''s "Verify integrity of game files" instead, then delete that backup.')
        return [pscustomobject]@{ Ok = $false; Changed = $false }
    }

    Write-BytesAtomically $File.Path $backupBytes
    if ((Get-Sha256Hex ([IO.File]::ReadAllBytes($File.Path))) -ne $backupHash) {
        throw 'the restored file does not match the backup. Use Steam''s "Verify integrity of game files" to recover.'
    }
    Write-Info "  ${name}: restored the stock file (SHA-256 verified)."
    return [pscustomobject]@{ Ok = $true; Changed = $true }
}

function Get-FileStatusText($File) {
    if (-not (Test-Path -LiteralPath $File.Path -PathType Leaf)) { return "not found ($($File.Path))" }
    $data = Read-IniFile $File.Path
    $state = Get-IniState -Text $data.Text -Overlay $File.Overlay
    $hasBackup = Test-Path -LiteralPath $File.Backup -PathType Leaf
    $text = switch ($state.State) {
        'stock'   { 'stock' }
        'patched' { 'patched' }
        default   { "partially patched ($($state.Present) of $($state.Total) settings)" }
    }
    # Same check as Apply and Restore: other values on exactly the lines this patch edits.
    if ($state.State -eq 'stock' -and $hasBackup -and
        (Test-OnlyOverlayLinesDiffer $data.Text (Read-IniFile $File.Backup).Text $File.Overlay)) {
        $text = 'patched with other values (for example by an earlier version); run Restore.cmd, then Apply.cmd'
    }
    $backup = if ($hasBackup) { 'yes' } else { 'no' }
    return "$text (backup: $backup)"
}

function Get-UserConfigNote($Target, $Files, [string]$DocumentsRoot) {
    # Only reads XComEngine.ini. The game rebuilds it when the files above change.
    $path = Join-Path $DocumentsRoot "My Games\$($Target.UserFolder)\XComGame\Config\XComEngine.ini"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return 'not created yet; the game builds it from the files above on its next launch.'
    }
    $userTime = (Get-Item -LiteralPath $path).LastWriteTimeUtc
    $newest = [datetime]::MinValue
    foreach ($file in $Files) {
        if (Test-Path -LiteralPath $file.Path -PathType Leaf) {
            $time = (Get-Item -LiteralPath $file.Path).LastWriteTimeUtc
            if ($time -gt $newest) { $newest = $time }
        }
    }
    if ($userTime -lt $newest) {
        return 'older than the files above; the game rebuilds it on its next launch, which resets your resolution and graphics options.'
    }
    return 'newer than the files above, so it already includes them. Changes made in the in-game Options are saved there and take precedence.'
}

function Invoke-Main([string[]]$Arguments, [string]$BaseEngineOverlayPath, [string]$DefaultEngineOverlayPath, [string]$BackupRoot,
                     [string]$DocumentsRoot = [Environment]::GetFolderPath('MyDocuments'),
                     [scriptblock]$IsGameRunning = { Test-GameRunning }) {
    $ErrorActionPreference = 'Stop'
    $BaseEngineRelative = 'Engine\Config\BaseEngine.ini'
    $script:Quiet = $false
    try {
        $options = ConvertFrom-Arguments $Arguments
        $script:Quiet = $options.Quiet
        if ($options.Help) {
            Write-Host $Usage
            return 0
        }
        $specs = @([pscustomobject]@{ Name = 'BaseEngine.ini'; Relative = $BaseEngineRelative; Overlay = (Read-Overlay $BaseEngineOverlayPath) })
        if ($DefaultEngineOverlayPath) {
            $specs += [pscustomobject]@{ Name = 'DefaultEngine.ini'; Relative = 'XComGame\Config\DefaultEngine.ini'; Overlay = (Read-Overlay $DefaultEngineOverlayPath) }
        }
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
        $changed = $false
        foreach ($target in $resolved.Targets) {
            $label = '{0,-14}' -f $target.Name
            $baseEngine = Join-Path $target.Root $BaseEngineRelative
            if (-not (Test-Path -LiteralPath $baseEngine -PathType Leaf)) {
                if ($options.Target) {
                    Write-Problem "$($target.Name) is not installed (no $baseEngine)."
                    $ok = $false
                } elseif ($options.Verb -eq 'status') {
                    Write-Host "${label}: not installed"
                } else {
                    Write-Info "${label}: not installed; skipped."
                }
                continue
            }

            $files = Get-GameFiles $target $specs $BackupRoot
            if ($options.Verb -eq 'status') {
                Write-Host $target.Name
                foreach ($file in $files) {
                    try { $text = Get-FileStatusText $file } catch { $text = "unreadable: $($_.Exception.Message)" }
                    Write-Host ('  {0,-18}: {1}' -f $file.Name, $text)
                }
                Write-Host ('  {0,-18}: {1}' -f 'XComEngine.ini', (Get-UserConfigNote $target $files $DocumentsRoot))
                continue
            }

            Write-Info "$($target.Name): $($target.Root)"
            foreach ($file in $files) {
                try {
                    if ($options.Verb -eq 'apply') { $result = Invoke-ApplyFile $file } else { $result = Invoke-RestoreFile $file }
                    if (-not $result.Ok) { $ok = $false }
                    if ($result.Changed) { $changed = $true }
                } catch {
                    Write-Problem "$($target.Name), $($file.Name): $($_.Exception.Message)"
                    $ok = $false
                }
            }
        }
        if ($changed) {
            Write-Info ('Next time you start the game, it rebuilds your per-user settings (XComEngine.ini) from these files. ' +
                'That resets your resolution and graphics options: set them again under Options.')
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
    exit (Invoke-Main -Arguments $args -BaseEngineOverlayPath (Join-Path $here 'base-engine.ini') `
        -DefaultEngineOverlayPath (Join-Path $here 'default-engine.ini') -BackupRoot (Join-Path $here 'backup'))
}
