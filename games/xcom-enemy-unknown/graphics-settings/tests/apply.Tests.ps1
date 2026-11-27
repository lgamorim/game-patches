# Tests for apply.ps1: the INI merge, state detection, file encoding, options and the
# apply / restore / status flow on a fake install. Every fixture is synthetic; nothing
# here reads the game's own files.
#
# Run from this folder or anywhere:
#   powershell -NoProfile -Command "Invoke-Pester -Path '<this folder>'"
#
# Written to run on the Pester 3.4 that ships with Windows PowerShell 5.1 as well as on
# Pester 5, so assertions use the small helpers below instead of Should.

Describe 'graphics-settings apply.ps1' {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'apply.ps1')

        $script:CRLF = "`r`n"

        function Show-Value($Value) {
            if ($null -eq $Value) { return '$null' }
            return ([string]$Value).Replace("`r", '\r').Replace("`n", '\n')
        }

        function Assert-Equal($Expected, $Actual, [string]$Because = '') {
            if ($Expected -is [string] -or $Actual -is [string]) {
                $ok = [string]::Equals([string]$Expected, [string]$Actual, [StringComparison]::Ordinal)
            } else {
                $ok = $Expected -eq $Actual
            }
            if (-not $ok) { throw "Expected <$(Show-Value $Expected)> but got <$(Show-Value $Actual)>. $Because" }
        }

        function Assert-True($Condition, [string]$Because) {
            if (-not $Condition) { throw "Expected true: $Because" }
        }

        function Assert-BytesEqual([byte[]]$Expected, [byte[]]$Actual, [string]$Because = '') {
            $n = [Math]::Min($Expected.Length, $Actual.Length)
            for ($i = 0; $i -lt $n; $i++) {
                if ($Expected[$i] -ne $Actual[$i]) {
                    throw "Bytes differ at offset ${i}: expected 0x$('{0:X2}' -f $Expected[$i]), got 0x$('{0:X2}' -f $Actual[$i]). $Because"
                }
            }
            if ($Expected.Length -ne $Actual.Length) {
                throw "Byte lengths differ: expected $($Expected.Length), got $($Actual.Length). $Because"
            }
        }

        function Assert-Throws([scriptblock]$Script, [string]$Like) {
            $caught = $null
            try { & $Script } catch { $caught = $_ }
            if ($null -eq $caught) { throw "Expected an error like '*$Like*', but nothing was thrown." }
            if ($caught.Exception.Message -notlike "*$Like*") {
                throw "Expected an error like '*$Like*', got: $($caught.Exception.Message)"
            }
        }

        function Join-Lines([string[]]$Lines, [string]$Eol = "`r`n", [switch]$NoFinalEol) {
            $text = ($Lines -join $Eol)
            if (-not $NoFinalEol) { $text += $Eol }
            return $text
        }

        function Get-Latin1Bytes([string]$Text) {
            return [Text.Encoding]::GetEncoding(28591).GetBytes($Text)
        }

        function New-TestFolder {
            $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            return $dir
        }

        function Get-Sha256([string]$Path) {
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }

        # Overlay used by the merge tests.
        $script:BasicOverlay = ConvertFrom-OverlayText (Join-Lines @(
            '[SystemSettings]',
            '; Anisotropic filtering level',
            'MaxAnisotropy=16'
        ))

        # A small file shaped like BaseEngine.ini, and an overlay shaped like base-engine.ini.
        $script:StockLines = @(
            '[Engine.Engine]',
            'Language=INT',
            'bDisablePhysXHardwareSupport=True',
            'DemoRecordingDevice=Engine.DemoRecDriver',
            '',
            '[XAudio2.XAudio2Device]',
            'MaxChannels=32',
            'CommonAudioPoolSize=0',
            '',
            '[ALAudio.ALAudioDevice]',
            'MaxChannels=32',
            '//DeviceName=Generic Software',
            '',
            '[SystemSettings]',
            '; NOTE THAT ANY ITEMS IN THIS SECTION WILL AFFECT ALL PLATFORMS!!!',
            'MaxAnisotropy=4',
            'TEXTUREGROUP_World=(MinLODSize=1,MaxLODSize=4096,LODBias=0,MinMagFilter=point,MipFilter=point)',
            '',
            '[SystemSettingsMobile]',
            'MaxAnisotropy=2',
            '',
            '[ContentComparisonReferenceTypes]',
            '+Class=AnimSet',
            '+Class=SkeletalMesh'
        )
        $script:OverlayText = Join-Lines @(
            '; Test overlay',
            '[Engine.Engine]',
            'bDisablePhysXHardwareSupport=False',
            '[XAudio2.XAudio2Device]',
            'MaxChannels=96',
            '[ALAudio.ALAudioDevice]',
            'MaxChannels=96',
            '[SystemSettings]',
            'MaxAnisotropy=16',
            'TEXTUREGROUP_World=(MinLODSize=1,MaxLODSize=4096,LODBias=0,MinMagFilter=aniso,MipFilter=aniso)'
        )
        $script:PatchedLines = @(
            '[Engine.Engine]',
            'Language=INT',
            'bDisablePhysXHardwareSupport=False',
            'DemoRecordingDevice=Engine.DemoRecDriver',
            '',
            '[XAudio2.XAudio2Device]',
            'MaxChannels=96',
            'CommonAudioPoolSize=0',
            '',
            '[ALAudio.ALAudioDevice]',
            'MaxChannels=96',
            '//DeviceName=Generic Software',
            '',
            '[SystemSettings]',
            '; NOTE THAT ANY ITEMS IN THIS SECTION WILL AFFECT ALL PLATFORMS!!!',
            'MaxAnisotropy=16',
            'TEXTUREGROUP_World=(MinLODSize=1,MaxLODSize=4096,LODBias=0,MinMagFilter=aniso,MipFilter=aniso)',
            '',
            '[SystemSettingsMobile]',
            'MaxAnisotropy=2',
            '',
            '[ContentComparisonReferenceTypes]',
            '+Class=AnimSet',
            '+Class=SkeletalMesh'
        )
        $script:Overlay = ConvertFrom-OverlayText $script:OverlayText

        # A small file shaped like XComGame\Config\DefaultEngine.ini (it starts with a blank
        # line, like the real one), and an overlay shaped like default-engine.ini.
        $script:DefaultStockLines = @(
            '',
            '[Configuration]',
            'BasedOn=..\Engine\Config\BaseEngine.ini',
            '',
            '[SystemSettings]',
            'ResX=0',
            'ResY=0',
            'TEXTUREGROUP_World=(MinLODSize=256,MaxLODSize=1024,LODBias=1,MinMagFilter=aniso,MipFilter=point)',
            'TEXTUREGROUP_UI=(MinLODSize=512,MaxLODSize=1024,LODBias=0,MinMagFilter=linear,MipFilter=point)',
            '',
            '[SystemSettingsEditor]',
            'TEXTUREGROUP_World=(MinLODSize=256,MaxLODSize=1024,LODBias=1,MinMagFilter=aniso,MipFilter=point)'
        )
        $script:DefaultPatchedLines = $script:DefaultStockLines.Clone()
        $script:DefaultPatchedLines[7] = 'TEXTUREGROUP_World=(MinLODSize=256,MaxLODSize=1024,LODBias=1,MinMagFilter=aniso,MipFilter=aniso)'
        $script:DefaultPatchedLines[8] = 'TEXTUREGROUP_UI=(MinLODSize=512,MaxLODSize=1024,LODBias=0,MinMagFilter=linear,MipFilter=aniso)'
        # Enemy Within's own sizes differ; they must survive the patch.
        $script:DefaultEwStockLines = $script:DefaultStockLines.Clone()
        $script:DefaultEwStockLines[7] = 'TEXTUREGROUP_World=(MinLODSize=256,MaxLODSize=1024,LODBias=0,MinMagFilter=aniso,MipFilter=point)'
        $script:DefaultOverlayText = Join-Lines @(
            '[SystemSettings]',
            '; World textures: filter between mipmap levels',
            'TEXTUREGROUP_World.MipFilter=aniso',
            'TEXTUREGROUP_UI.MipFilter=aniso'
        )
        $script:DefaultOverlay = ConvertFrom-OverlayText $script:DefaultOverlayText

        # Fake install: for each game, Engine\Config\BaseEngine.ini and
        # XComGame\Config\DefaultEngine.ini, under <root> and <root>\XEW.
        function New-FakeInstall([switch]$NoXew, [switch]$NoDefaultEngine, [string]$EuText, [string]$EwText, [string]$EuDefaultText, [string]$EwDefaultText) {
            $base = New-TestFolder
            $root = Join-Path $base 'XCom-Enemy-Unknown'
            if (-not $EuText) { $EuText = Join-Lines $script:StockLines }
            if (-not $EwText) { $EwText = Join-Lines ($script:StockLines + @('', '[Extra]', 'OnlyInEW=1')) }
            if (-not $EuDefaultText) { $EuDefaultText = Join-Lines $script:DefaultStockLines }
            if (-not $EwDefaultText) { $EwDefaultText = Join-Lines $script:DefaultEwStockLines }
            $games = @(@{ Dir = $root; Base = $EuText; Default = $EuDefaultText })
            if (-not $NoXew) { $games += @{ Dir = (Join-Path $root 'XEW'); Base = $EwText; Default = $EwDefaultText } }
            foreach ($g in $games) {
                New-Item -ItemType Directory -Path (Join-Path $g.Dir 'Engine\Config') -Force | Out-Null
                [IO.File]::WriteAllBytes((Join-Path $g.Dir 'Engine\Config\BaseEngine.ini'), (Get-Latin1Bytes $g.Base))
                if (-not $NoDefaultEngine) {
                    New-Item -ItemType Directory -Path (Join-Path $g.Dir 'XComGame\Config') -Force | Out-Null
                    [IO.File]::WriteAllBytes((Join-Path $g.Dir 'XComGame\Config\DefaultEngine.ini'), (Get-Latin1Bytes $g.Default))
                }
            }
            $overlayPath = Join-Path $base 'base-engine.ini'
            [IO.File]::WriteAllBytes($overlayPath, (Get-Latin1Bytes $script:OverlayText))
            $defaultOverlayPath = Join-Path $base 'default-engine.ini'
            [IO.File]::WriteAllBytes($defaultOverlayPath, (Get-Latin1Bytes $script:DefaultOverlayText))
            $documents = Join-Path $base 'Documents'
            New-Item -ItemType Directory -Path $documents | Out-Null
            return [pscustomobject]@{
                Root           = $root
                EuFile         = Join-Path $root 'Engine\Config\BaseEngine.ini'
                EwFile         = Join-Path $root 'XEW\Engine\Config\BaseEngine.ini'
                EuDefault      = Join-Path $root 'XComGame\Config\DefaultEngine.ini'
                EwDefault      = Join-Path $root 'XEW\XComGame\Config\DefaultEngine.ini'
                Overlay        = $overlayPath
                DefaultOverlay = $defaultOverlayPath
                Backup         = Join-Path $base 'backup'
                Documents      = $documents
            }
        }

        function Get-FileState([string]$Path, $Overlay) {
            return (Get-IniState -Text ([IO.File]::ReadAllText($Path)) -Overlay $Overlay).State
        }

        # Runs the CLI entry point and returns its exit code and everything it printed.
        function Invoke-Cli($Install, [string[]]$Arguments, [scriptblock]$IsGameRunning = { $false }) {
            $records = & { Invoke-Main -Arguments $Arguments -BaseEngineOverlayPath $Install.Overlay -DefaultEngineOverlayPath $Install.DefaultOverlay -BackupRoot $Install.Backup -DocumentsRoot $Install.Documents -IsGameRunning $IsGameRunning } 6>&1
            $code = $null
            $lines = New-Object System.Collections.Generic.List[string]
            foreach ($r in $records) {
                if ($r -is [int]) { $code = $r }
                elseif ($r -is [System.Management.Automation.InformationRecord]) { $lines.Add([string]$r.MessageData) }
                else { $lines.Add([string]$r) }
            }
            return [pscustomobject]@{ Code = $code; Output = ($lines -join "`n") }
        }
    }

    Context 'Merge-IniText' {

        It 'replaces the value of an existing key' {
            $text = Join-Lines @('[SystemSettings]', 'MaxAnisotropy=4', 'Bloom=True')
            $merged = Merge-IniText -Text $text -Overlay $script:BasicOverlay
            Assert-Equal (Join-Lines @('[SystemSettings]', 'MaxAnisotropy=16', 'Bloom=True')) $merged
        }

        It 'only touches the key in the overlay section, not the same key elsewhere' {
            $text = Join-Lines @('[SystemSettings]', 'MaxAnisotropy=4', '', '[SystemSettingsMobile]', 'MaxAnisotropy=2')
            $merged = Merge-IniText -Text $text -Overlay $script:BasicOverlay
            Assert-Equal (Join-Lines @('[SystemSettings]', 'MaxAnisotropy=16', '', '[SystemSettingsMobile]', 'MaxAnisotropy=2')) $merged
        }

        It 'keeps the spacing around = when replacing' {
            $text = Join-Lines @('[SystemSettings]', 'MaxAnisotropy = 4')
            $merged = Merge-IniText -Text $text -Overlay $script:BasicOverlay
            Assert-Equal (Join-Lines @('[SystemSettings]', 'MaxAnisotropy = 16')) $merged
        }

        It 'matches section and key names case-insensitively and keeps their spelling' {
            $text = Join-Lines @('[systemsettings]', 'maxanisotropy=4')
            $merged = Merge-IniText -Text $text -Overlay $script:BasicOverlay
            Assert-Equal (Join-Lines @('[systemsettings]', 'maxanisotropy=16')) $merged
        }

        It 'inserts a missing key after the last setting of an existing section' {
            $text = Join-Lines @('[SystemSettings]', 'Bloom=True', '', '; comment about the next section', '[Other]', 'A=1')
            $merged = Merge-IniText -Text $text -Overlay $script:BasicOverlay
            $expected = Join-Lines @('[SystemSettings]', 'Bloom=True', 'MaxAnisotropy=16', '', '; comment about the next section', '[Other]', 'A=1')
            Assert-Equal $expected $merged
        }

        It 'inserts several missing keys in overlay order' {
            $overlay = ConvertFrom-OverlayText (Join-Lines @('[S]', 'B=2', 'C=3'))
            $merged = Merge-IniText -Text (Join-Lines @('[S]', 'A=1')) -Overlay $overlay
            Assert-Equal (Join-Lines @('[S]', 'A=1', 'B=2', 'C=3')) $merged
        }

        It 'inserts into an empty section right after its header' {
            $text = Join-Lines @('[SystemSettings]', '', '[Other]', 'A=1')
            $merged = Merge-IniText -Text $text -Overlay $script:BasicOverlay
            Assert-Equal (Join-Lines @('[SystemSettings]', 'MaxAnisotropy=16', '', '[Other]', 'A=1')) $merged
        }

        It 'does not treat commented-out keys as present' {
            $text = Join-Lines @('[SystemSettings]', ';MaxAnisotropy=4', '//MaxAnisotropy=4', '#MaxAnisotropy=4', 'Bloom=True')
            $merged = Merge-IniText -Text $text -Overlay $script:BasicOverlay
            $expected = Join-Lines @('[SystemSettings]', ';MaxAnisotropy=4', '//MaxAnisotropy=4', '#MaxAnisotropy=4', 'Bloom=True', 'MaxAnisotropy=16')
            Assert-Equal $expected $merged
        }

        It 'creates a missing section at the end of the file, after a blank line' {
            $text = Join-Lines @('[Other]', 'A=1')
            $merged = Merge-IniText -Text $text -Overlay $script:BasicOverlay
            Assert-Equal (Join-Lines @('[Other]', 'A=1', '', '[SystemSettings]', 'MaxAnisotropy=16')) $merged
        }

        It 'does not add a second blank line before a new section when the file already ends with one' {
            $text = Join-Lines @('[Other]', 'A=1', '')
            $merged = Merge-IniText -Text $text -Overlay $script:BasicOverlay
            Assert-Equal (Join-Lines @('[Other]', 'A=1', '', '[SystemSettings]', 'MaxAnisotropy=16')) $merged
        }

        It 'leaves every untouched line byte-identical, including odd whitespace and array lines' {
            $lines = @(
                '; header comment  ',
                '[Engine.Engine]',
                'PrimitiveProbablyVisibleTime = 8.0',
                'IdealLightMapDensity=0.2 ',
                "CompressCommandletVersion=2`t// inline note",
                '[SystemSettings]',
                'MaxAnisotropy=4',
                '[ContentComparisonReferenceTypes]',
                '+Class=AnimSet',
                '-Class=Removed',
                '.Class=Appended',
                'Repeated=1',
                'Repeated=2'
            )
            $merged = Merge-IniText -Text (Join-Lines $lines) -Overlay $script:BasicOverlay
            $expectedLines = $lines.Clone()
            $expectedLines[6] = 'MaxAnisotropy=16'
            Assert-Equal (Join-Lines $expectedLines) $merged
        }

        It 'is idempotent' {
            $once = Merge-IniText -Text (Join-Lines $script:StockLines) -Overlay $script:Overlay
            $twice = Merge-IniText -Text $once -Overlay $script:Overlay
            Assert-Equal (Join-Lines $script:PatchedLines) $once
            Assert-Equal $once $twice
        }

        It 'uses the file''s own line ending for inserted lines' {
            $text = Join-Lines @('[Other]', 'A=1') -Eol "`n"
            $merged = Merge-IniText -Text $text -Overlay $script:BasicOverlay
            Assert-Equal (Join-Lines @('[Other]', 'A=1', '', '[SystemSettings]', 'MaxAnisotropy=16') -Eol "`n") $merged
        }

        It 'keeps a missing final line break missing' {
            $text = Join-Lines @('[SystemSettings]', 'Bloom=True') -NoFinalEol
            $merged = Merge-IniText -Text $text -Overlay $script:BasicOverlay
            Assert-Equal (Join-Lines @('[SystemSettings]', 'Bloom=True', 'MaxAnisotropy=16') -NoFinalEol) $merged
        }

        It 'refuses when the key appears more than once in its section' {
            $text = Join-Lines @('[SystemSettings]', 'MaxAnisotropy=4', 'MaxAnisotropy=8')
            Assert-Throws { Merge-IniText -Text $text -Overlay $script:BasicOverlay } 'appears 2 times'
        }

        It 'refuses when the section appears more than once' {
            $text = Join-Lines @('[SystemSettings]', 'A=1', '[SystemSettings]', 'B=2')
            Assert-Throws { Merge-IniText -Text $text -Overlay $script:BasicOverlay } 'appears 2 times'
        }
    }

    Context 'ConvertFrom-OverlayText' {

        It 'reads sections, keys and values and skips comments and blank lines' {
            $entries = @(ConvertFrom-OverlayText (Join-Lines @('; top', '[A]', '', '; what K does', 'K=V', '[B.C]', 'X = (R=1,G=2)')))
            Assert-Equal 2 $entries.Count
            Assert-Equal 'A' $entries[0].Section
            Assert-Equal 'K' $entries[0].Key
            Assert-Equal 'V' $entries[0].Value
            Assert-Equal 'B.C' $entries[1].Section
            Assert-Equal 'X' $entries[1].Key
            Assert-Equal '(R=1,G=2)' $entries[1].Value
        }

        It 'rejects UE3 array syntax' {
            foreach ($key in '+K', '-K', '.K', '!K') {
                Assert-Throws { ConvertFrom-OverlayText (Join-Lines @('[A]', "$key=1")) } 'array'
            }
        }

        It 'rejects a key repeated in the same section' {
            Assert-Throws { ConvertFrom-OverlayText (Join-Lines @('[A]', 'K=1', 'K=2')) } 'more than once'
        }

        It 'rejects a key outside any section' {
            Assert-Throws { ConvertFrom-OverlayText (Join-Lines @('K=1', '[A]')) } 'comes before any'
        }

        It 'rejects an empty overlay' {
            Assert-Throws { ConvertFrom-OverlayText (Join-Lines @('; nothing')) } 'no settings'
        }

        It 'parses the shipped base-engine.ini' {
            $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'base-engine.ini'
            $entries = @(Read-Overlay -Path $path)
            Assert-True ($entries.Count -gt 0) 'base-engine.ini has entries'
        }
    }

    Context 'Get-IniState' {

        It 'reports stock when no overlay value is present' {
            $state = Get-IniState -Text (Join-Lines $script:StockLines) -Overlay $script:Overlay
            Assert-Equal 'stock' $state.State
            Assert-Equal 0 $state.Present
            Assert-Equal 5 $state.Total
        }

        It 'reports stock when keys or sections are missing altogether' {
            $state = Get-IniState -Text (Join-Lines @('[Other]', 'A=1')) -Overlay $script:Overlay
            Assert-Equal 'stock' $state.State
        }

        It 'reports patched when every overlay value is present' {
            $state = Get-IniState -Text (Join-Lines $script:PatchedLines) -Overlay $script:Overlay
            Assert-Equal 'patched' $state.State
            Assert-Equal 5 $state.Present
        }

        It 'reports partial when only some overlay values are present' {
            $lines = $script:StockLines.Clone()
            $lines[6] = 'MaxChannels=96'
            $state = Get-IniState -Text (Join-Lines $lines) -Overlay $script:Overlay
            Assert-Equal 'partial' $state.State
            Assert-Equal 1 $state.Present
        }

        It 'ignores whitespace around the value but compares the value exactly' {
            $text = Join-Lines @('[SystemSettings]', 'MaxAnisotropy = 16  ')
            Assert-Equal 'patched' (Get-IniState -Text $text -Overlay $script:BasicOverlay).State
            $text = Join-Lines @('[SystemSettings]', 'MaxAnisotropy=160')
            Assert-Equal 'stock' (Get-IniState -Text $text -Overlay $script:BasicOverlay).State
        }
    }

    Context 'Update-IniFile (encoding and line endings)' {

        It 'preserves CRLF line endings and changes only the patched line' {
            $dir = New-TestFolder
            $path = Join-Path $dir 'BaseEngine.ini'
            [IO.File]::WriteAllBytes($path, (Get-Latin1Bytes (Join-Lines $script:StockLines)))
            $result = Update-IniFile -Path $path -Overlay $script:Overlay
            Assert-True $result.Changed 'file reported as changed'
            Assert-BytesEqual (Get-Latin1Bytes (Join-Lines $script:PatchedLines)) ([IO.File]::ReadAllBytes($path))
        }

        It 'preserves LF line endings' {
            $dir = New-TestFolder
            $path = Join-Path $dir 'BaseEngine.ini'
            [IO.File]::WriteAllBytes($path, (Get-Latin1Bytes (Join-Lines $script:StockLines -Eol "`n")))
            Update-IniFile -Path $path -Overlay $script:Overlay | Out-Null
            Assert-BytesEqual (Get-Latin1Bytes (Join-Lines $script:PatchedLines -Eol "`n")) ([IO.File]::ReadAllBytes($path))
        }

        It 'keeps non-ASCII bytes in a file without a byte order mark exactly as they were' {
            $dir = New-TestFolder
            $path = Join-Path $dir 'BaseEngine.ini'
            # A UTF-8 'é' (C3 A9) and a lone Latin-1 'é' (E9): both must survive untouched.
            $before = [byte[]](Get-Latin1Bytes "; caf") + [byte[]](0xC3, 0xA9) + [byte[]](Get-Latin1Bytes " / caf") + [byte[]](0xE9) +
                      [byte[]](Get-Latin1Bytes ($script:CRLF + (Join-Lines @('[SystemSettings]', 'MaxAnisotropy=4'))))
            $after = [byte[]](Get-Latin1Bytes "; caf") + [byte[]](0xC3, 0xA9) + [byte[]](Get-Latin1Bytes " / caf") + [byte[]](0xE9) +
                     [byte[]](Get-Latin1Bytes ($script:CRLF + (Join-Lines @('[SystemSettings]', 'MaxAnisotropy=16'))))
            [IO.File]::WriteAllBytes($path, $before)
            Update-IniFile -Path $path -Overlay $script:BasicOverlay | Out-Null
            Assert-BytesEqual $after ([IO.File]::ReadAllBytes($path))
        }

        It 'keeps a UTF-8 byte order mark' {
            $dir = New-TestFolder
            $path = Join-Path $dir 'BaseEngine.ini'
            $bom = [byte[]](0xEF, 0xBB, 0xBF)
            [IO.File]::WriteAllBytes($path, $bom + [byte[]](Get-Latin1Bytes (Join-Lines @('[SystemSettings]', 'MaxAnisotropy=4'))))
            Update-IniFile -Path $path -Overlay $script:BasicOverlay | Out-Null
            Assert-BytesEqual ($bom + [byte[]](Get-Latin1Bytes (Join-Lines @('[SystemSettings]', 'MaxAnisotropy=16')))) ([IO.File]::ReadAllBytes($path))
        }

        It 'keeps UTF-16 LE encoding and its byte order mark' {
            $dir = New-TestFolder
            $path = Join-Path $dir 'BaseEngine.ini'
            $utf16 = New-Object System.Text.UnicodeEncoding($false, $false)
            $bom = [byte[]](0xFF, 0xFE)
            [IO.File]::WriteAllBytes($path, $bom + $utf16.GetBytes((Join-Lines @('[SystemSettings]', 'MaxAnisotropy=4'))))
            Update-IniFile -Path $path -Overlay $script:BasicOverlay | Out-Null
            Assert-BytesEqual ($bom + $utf16.GetBytes((Join-Lines @('[SystemSettings]', 'MaxAnisotropy=16')))) ([IO.File]::ReadAllBytes($path))
        }

        It 'does not rewrite a file that is already patched' {
            $dir = New-TestFolder
            $path = Join-Path $dir 'BaseEngine.ini'
            [IO.File]::WriteAllBytes($path, (Get-Latin1Bytes (Join-Lines $script:PatchedLines)))
            $stamp = (Get-Date).AddDays(-1)
            (Get-Item -LiteralPath $path).LastWriteTime = $stamp
            $result = Update-IniFile -Path $path -Overlay $script:Overlay
            Assert-True (-not $result.Changed) 'file reported as unchanged'
            Assert-Equal $stamp (Get-Item -LiteralPath $path).LastWriteTime
        }
    }

    Context 'ConvertFrom-Arguments' {

        It 'reads the verb and every option' {
            $o = ConvertFrom-Arguments @('apply', '--game-dir', 'D:\Games\XCOM', '--target', 'ew', '--quiet')
            Assert-Equal 'apply' $o.Verb
            Assert-Equal 'D:\Games\XCOM' $o.GameDir
            Assert-Equal 'ew' $o.Target
            Assert-True $o.Quiet '--quiet is set'
        }

        It 'accepts --option=value' {
            $o = ConvertFrom-Arguments @('status', '--game-dir=D:\Games\XCOM', '--target=EU')
            Assert-Equal 'D:\Games\XCOM' $o.GameDir
            Assert-Equal 'eu' $o.Target
        }

        It 'rejects unknown options' {
            Assert-Throws { ConvertFrom-Arguments @('apply', '--force') } 'unknown option: --force'
        }

        It 'rejects an unknown target' {
            Assert-Throws { ConvertFrom-Arguments @('apply', '--target', 'xcom2') } '--target'
        }

        It 'rejects an option missing its value' {
            Assert-Throws { ConvertFrom-Arguments @('apply', '--game-dir') } 'needs a value'
        }

        It 'rejects a missing or unknown verb' {
            Assert-Throws { ConvertFrom-Arguments @('--quiet') } 'apply, restore or status'
            Assert-Throws { ConvertFrom-Arguments @('install') } 'apply, restore or status'
        }
    }

    Context 'Steam file parsing' {

        It 'lists library paths from libraryfolders.vdf' {
            $vdf = Join-Lines @(
                '"libraryfolders"', '{',
                '	"0"', '	{', '		"path"		"C:\\Program Files (x86)\\Steam"', '		"label"		""', '	}',
                '	"1"', '	{', '		"path"		"D:\\SteamLibrary"', '		"apps"', '		{', '			"200510"		"20000000000"', '		}', '	}',
                '}')
            $paths = @(ConvertFrom-LibraryFoldersVdf $vdf)
            Assert-Equal 2 $paths.Count
            Assert-Equal 'C:\Program Files (x86)\Steam' $paths[0]
            Assert-Equal 'D:\SteamLibrary' $paths[1]
        }

        It 'reads installdir from an app manifest' {
            $acf = Join-Lines @('"AppState"', '{', '	"appid"		"200510"', '	"name"		"XCOM: Enemy Unknown"', '	"installdir"		"XCom-Enemy-Unknown"', '}')
            Assert-Equal 'XCom-Enemy-Unknown' (Get-AcfInstallDir $acf)
        }
    }

    Context 'apply, restore and status on a fake install' {

        It 'patches both games and backs up the stock files' {
            $i = New-FakeInstall
            $euStock = Get-Sha256 $i.EuFile
            $ewStock = Get-Sha256 $i.EwFile
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root, '--quiet')
            Assert-Equal 0 $r.Code $r.Output
            Assert-Equal 'patched' (Get-IniState -Text ([IO.File]::ReadAllText($i.EuFile)) -Overlay $script:Overlay).State
            Assert-Equal 'patched' (Get-IniState -Text ([IO.File]::ReadAllText($i.EwFile)) -Overlay $script:Overlay).State
            Assert-Equal $euStock (Get-Sha256 (Join-Path $i.Backup 'enemy-unknown\BaseEngine.ini'))
            Assert-Equal $ewStock (Get-Sha256 (Join-Path $i.Backup 'enemy-within\BaseEngine.ini'))
        }

        It 'does nothing the second time and keeps the stock backup' {
            $i = New-FakeInstall -NoXew
            $stock = Get-Sha256 $i.EuFile
            Invoke-Cli $i @('apply', '--game-dir', $i.Root, '--quiet') | Out-Null
            $patched = Get-Sha256 $i.EuFile
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root)
            Assert-Equal 0 $r.Code $r.Output
            Assert-True ($r.Output -like '*already patched*') $r.Output
            Assert-Equal $patched (Get-Sha256 $i.EuFile)
            Assert-Equal $stock (Get-Sha256 (Join-Path $i.Backup 'enemy-unknown\BaseEngine.ini'))
        }

        It 'limits the work to one game with --target' {
            $i = New-FakeInstall
            $euStock = Get-Sha256 $i.EuFile
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root, '--target', 'ew', '--quiet')
            Assert-Equal 0 $r.Code $r.Output
            Assert-Equal $euStock (Get-Sha256 $i.EuFile)
            Assert-Equal 'patched' (Get-IniState -Text ([IO.File]::ReadAllText($i.EwFile)) -Overlay $script:Overlay).State
        }

        It 'fails when --target names a game that is not installed' {
            $i = New-FakeInstall -NoXew
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root, '--target', 'ew')
            Assert-Equal 1 $r.Code
            Assert-True ($r.Output -like '*Enemy Within*not installed*') $r.Output
        }

        It 'treats --game-dir pointing at the XEW folder as Enemy Within' {
            $i = New-FakeInstall
            $euStock = Get-Sha256 $i.EuFile
            $r = Invoke-Cli $i @('apply', '--game-dir', (Join-Path $i.Root 'XEW'), '--quiet')
            Assert-Equal 0 $r.Code $r.Output
            Assert-Equal $euStock (Get-Sha256 $i.EuFile)
            Assert-Equal 'patched' (Get-IniState -Text ([IO.File]::ReadAllText($i.EwFile)) -Overlay $script:Overlay).State
            Assert-True (Test-Path (Join-Path $i.Backup 'enemy-within\BaseEngine.ini')) 'EW backup exists'
            Assert-True (-not (Test-Path (Join-Path $i.Backup 'enemy-unknown'))) 'no EU backup'
        }

        It 'uses the XCOM_EU_DIR environment variable when --game-dir is not given' {
            $i = New-FakeInstall -NoXew
            $saved = $env:XCOM_EU_DIR
            try {
                $env:XCOM_EU_DIR = $i.Root
                $r = Invoke-Cli $i @('apply', '--quiet')
            } finally {
                $env:XCOM_EU_DIR = $saved
            }
            Assert-Equal 0 $r.Code $r.Output
            Assert-Equal 'patched' (Get-IniState -Text ([IO.File]::ReadAllText($i.EuFile)) -Overlay $script:Overlay).State
        }

        It 'fails when the folder has no Engine\Config\BaseEngine.ini' {
            $i = New-FakeInstall -NoXew
            $r = Invoke-Cli $i @('status', '--game-dir', (Join-Path $i.Root 'Engine'))
            Assert-Equal 1 $r.Code
            Assert-True ($r.Output -like '*BaseEngine.ini*') $r.Output
        }

        It 'refuses to patch a partially patched file without a backup' {
            $lines = $script:StockLines.Clone()
            $lines[6] = 'MaxChannels=96'
            $i = New-FakeInstall -NoXew -EuText (Join-Lines $lines)
            $before = Get-Sha256 $i.EuFile
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root)
            Assert-Equal 1 $r.Code
            Assert-True ($r.Output -like '*partially patched*') $r.Output
            Assert-Equal $before (Get-Sha256 $i.EuFile)
            Assert-True (-not (Test-Path (Join-Path $i.Backup 'enemy-unknown\BaseEngine.ini'))) 'no backup taken'
        }

        It 'completes a partially patched file when a backup exists, keeping that backup' {
            $i = New-FakeInstall -NoXew
            $stock = Get-Sha256 $i.EuFile
            Invoke-Cli $i @('apply', '--game-dir', $i.Root, '--quiet') | Out-Null
            $lines = $script:PatchedLines.Clone()
            $lines[6] = 'MaxChannels=32'
            [IO.File]::WriteAllBytes($i.EuFile, (Get-Latin1Bytes (Join-Lines $lines)))
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root, '--quiet')
            Assert-Equal 0 $r.Code $r.Output
            Assert-Equal 'patched' (Get-IniState -Text ([IO.File]::ReadAllText($i.EuFile)) -Overlay $script:Overlay).State
            Assert-Equal $stock (Get-Sha256 (Join-Path $i.Backup 'enemy-unknown\BaseEngine.ini'))
        }

        It 'refuses to write while the game is running' {
            $i = New-FakeInstall -NoXew
            $before = Get-Sha256 $i.EuFile
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root) -IsGameRunning { $true }
            Assert-Equal 1 $r.Code
            Assert-True ($r.Output -like '*running*') $r.Output
            Assert-Equal $before (Get-Sha256 $i.EuFile)
        }

        It 'restores the stock file byte-for-byte' {
            $i = New-FakeInstall
            $euStock = Get-Sha256 $i.EuFile
            $ewStock = Get-Sha256 $i.EwFile
            Invoke-Cli $i @('apply', '--game-dir', $i.Root, '--quiet') | Out-Null
            $r = Invoke-Cli $i @('restore', '--game-dir', $i.Root, '--quiet')
            Assert-Equal 0 $r.Code $r.Output
            Assert-Equal $euStock (Get-Sha256 $i.EuFile)
            Assert-Equal $ewStock (Get-Sha256 $i.EwFile)
        }

        It 'points to Verify integrity when there is no backup to restore' {
            $i = New-FakeInstall -NoXew -EuText (Join-Lines $script:PatchedLines)
            $r = Invoke-Cli $i @('restore', '--game-dir', $i.Root)
            Assert-Equal 1 $r.Code
            Assert-True ($r.Output -like '*Verify integrity of game files*') $r.Output
        }

        It 'does not restore over a file that is already stock' {
            $i = New-FakeInstall -NoXew
            Invoke-Cli $i @('apply', '--game-dir', $i.Root, '--quiet') | Out-Null
            # Simulate a game update: a different stock file replaces the patched one.
            $newStock = Join-Lines ($script:StockLines + @('', '[NewInUpdate]', 'A=1'))
            [IO.File]::WriteAllBytes($i.EuFile, (Get-Latin1Bytes $newStock))
            $before = Get-Sha256 $i.EuFile
            $r = Invoke-Cli $i @('restore', '--game-dir', $i.Root)
            Assert-Equal 0 $r.Code $r.Output
            Assert-True ($r.Output -like '*already stock*') $r.Output
            Assert-Equal $before (Get-Sha256 $i.EuFile)
        }

        It 'reports each game''s state without changing anything' {
            $i = New-FakeInstall
            Invoke-Cli $i @('apply', '--game-dir', $i.Root, '--target', 'eu', '--quiet') | Out-Null
            $eu = Get-Sha256 $i.EuFile
            $ew = Get-Sha256 $i.EwFile
            $r = Invoke-Cli $i @('status', '--game-dir', $i.Root)
            Assert-Equal 0 $r.Code $r.Output
            Assert-True ($r.Output -match 'Enemy Unknown\s+BaseEngine\.ini\s*:\s*patched \(backup: yes\)\s+DefaultEngine\.ini\s*:\s*patched \(backup: yes\)') $r.Output
            Assert-True ($r.Output -match 'Enemy Within\s+BaseEngine\.ini\s*:\s*stock \(backup: no\)\s+DefaultEngine\.ini\s*:\s*stock \(backup: no\)') $r.Output
            Assert-Equal $eu (Get-Sha256 $i.EuFile)
            Assert-Equal $ew (Get-Sha256 $i.EwFile)
        }

        It 'reports a game that is not installed' {
            $i = New-FakeInstall -NoXew
            $r = Invoke-Cli $i @('status', '--game-dir', $i.Root)
            Assert-Equal 0 $r.Code $r.Output
            Assert-True ($r.Output -match 'Enemy Within\s*:\s*not installed') $r.Output
        }
    }

    Context 'Field entries (Key.Field=Value): overlay parsing' {

        It 'reads the key, the field and the value' {
            $entries = @(ConvertFrom-OverlayText (Join-Lines @('[SystemSettings]', 'TEXTUREGROUP_World.MipFilter = aniso')))
            Assert-Equal 1 $entries.Count
            Assert-Equal 'SystemSettings' $entries[0].Section
            Assert-Equal 'TEXTUREGROUP_World' $entries[0].Key
            Assert-Equal 'MipFilter' $entries[0].Field
            Assert-Equal 'aniso' $entries[0].Value
        }

        It 'leaves Field empty for a plain Key=Value' {
            $entries = @(ConvertFrom-OverlayText (Join-Lines @('[A]', 'K=V')))
            Assert-True ($null -eq $entries[0].Field) 'Field is $null'
        }

        It 'rejects an empty field name or more than one dot' {
            Assert-Throws { ConvertFrom-OverlayText (Join-Lines @('[A]', 'K.=1')) } 'Key.Field'
            Assert-Throws { ConvertFrom-OverlayText (Join-Lines @('[A]', 'K.F.G=1')) } 'Key.Field'
        }

        It 'rejects the same field twice' {
            Assert-Throws { ConvertFrom-OverlayText (Join-Lines @('[A]', 'K.F=1', 'k.f=2')) } 'more than once'
        }

        It 'rejects a key set both as a whole and by field' {
            Assert-Throws { ConvertFrom-OverlayText (Join-Lines @('[A]', 'K=(F=1)', 'K.F=2')) } 'both as a whole and by field'
        }

        It 'parses the shipped default-engine.ini' {
            $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'default-engine.ini'
            $entries = @(Read-Overlay -Path $path)
            Assert-True ($entries.Count -gt 0) 'default-engine.ini has entries'
            foreach ($e in $entries) {
                Assert-Equal 'MipFilter' $e.Field "$($e.Key) edits MipFilter"
                Assert-Equal 'linear' $e.Value "$($e.Key) uses linear (trilinear) mip filtering"
            }
        }
    }

    Context 'Field entries: merge and state' {

        It 'changes only the field, leaving the rest of the line and other sections byte-identical' {
            $merged = Merge-IniText -Text (Join-Lines $script:DefaultStockLines) -Overlay $script:DefaultOverlay
            Assert-Equal (Join-Lines $script:DefaultPatchedLines) $merged
        }

        It 'keeps the spacing inside the struct' {
            $overlay = ConvertFrom-OverlayText (Join-Lines @('[S]', 'T.MipFilter=aniso'))
            $merged = Merge-IniText -Text (Join-Lines @('[S]', 'T = ( MinLODSize = 256 , MipFilter = point )')) -Overlay $overlay
            Assert-Equal (Join-Lines @('[S]', 'T = ( MinLODSize = 256 , MipFilter = aniso )')) $merged
        }

        It 'matches the field name case-insensitively and keeps its spelling' {
            $overlay = ConvertFrom-OverlayText (Join-Lines @('[S]', 'T.MipFilter=aniso'))
            $merged = Merge-IniText -Text (Join-Lines @('[S]', 'T=(mipfilter=Point)')) -Overlay $overlay
            Assert-Equal (Join-Lines @('[S]', 'T=(mipfilter=aniso)')) $merged
        }

        It 'only changes the top-level field, not one nested or inside quotes' {
            $overlay = ConvertFrom-OverlayText (Join-Lines @('[S]', 'T.MipFilter=aniso'))
            $text = Join-Lines @('[S]', 'T=(A=(B=1,MipFilter=x),Name="a,MipFilter=q",MipFilter=point)')
            $merged = Merge-IniText -Text $text -Overlay $overlay
            Assert-Equal (Join-Lines @('[S]', 'T=(A=(B=1,MipFilter=x),Name="a,MipFilter=q",MipFilter=aniso)')) $merged
        }

        It 'is idempotent' {
            $once = Merge-IniText -Text (Join-Lines $script:DefaultStockLines) -Overlay $script:DefaultOverlay
            Assert-Equal $once (Merge-IniText -Text $once -Overlay $script:DefaultOverlay)
        }

        It 'refuses a value that has no such field' {
            $overlay = ConvertFrom-OverlayText (Join-Lines @('[S]', 'T.MipFilter=aniso'))
            Assert-Throws { Merge-IniText -Text (Join-Lines @('[S]', 'T=(MinLODSize=1)')) -Overlay $overlay } 'has no MipFilter field'
        }

        It 'refuses a field that appears twice at the top level' {
            $overlay = ConvertFrom-OverlayText (Join-Lines @('[S]', 'T.MipFilter=aniso'))
            Assert-Throws { Merge-IniText -Text (Join-Lines @('[S]', 'T=(MipFilter=a,MipFilter=b)')) -Overlay $overlay } 'appears 2 times'
        }

        It 'refuses a value that is not a (...) struct' {
            $overlay = ConvertFrom-OverlayText (Join-Lines @('[S]', 'T.MipFilter=aniso'))
            Assert-Throws { Merge-IniText -Text (Join-Lines @('[S]', 'T=point')) -Overlay $overlay } 'not a (...) value'
            Assert-Throws { Merge-IniText -Text (Join-Lines @('[S]', 'T=(MipFilter=point) trailing')) -Overlay $overlay } 'not a (...) value'
        }

        It 'never inserts: a missing key or section is an error' {
            $overlay = ConvertFrom-OverlayText (Join-Lines @('[S]', 'T.MipFilter=aniso'))
            Assert-Throws { Merge-IniText -Text (Join-Lines @('[S]', 'Other=1')) -Overlay $overlay } 'not found'
            Assert-Throws { Merge-IniText -Text (Join-Lines @('[Other]', 'T=(MipFilter=point)')) -Overlay $overlay } 'not found'
        }

        It 'detects stock, patched and partial' {
            Assert-Equal 'stock' (Get-IniState -Text (Join-Lines $script:DefaultStockLines) -Overlay $script:DefaultOverlay).State
            Assert-Equal 'patched' (Get-IniState -Text (Join-Lines $script:DefaultPatchedLines) -Overlay $script:DefaultOverlay).State
            $lines = $script:DefaultStockLines.Clone()
            $lines[8] = $script:DefaultPatchedLines[8]
            $state = Get-IniState -Text (Join-Lines $lines) -Overlay $script:DefaultOverlay
            Assert-Equal 'partial' $state.State
            Assert-Equal 1 $state.Present
        }

        It 'keeps a leading blank line and CRLF line endings when writing' {
            $dir = New-TestFolder
            $path = Join-Path $dir 'DefaultEngine.ini'
            [IO.File]::WriteAllBytes($path, (Get-Latin1Bytes (Join-Lines $script:DefaultStockLines)))
            Update-IniFile -Path $path -Overlay $script:DefaultOverlay | Out-Null
            Assert-BytesEqual (Get-Latin1Bytes (Join-Lines $script:DefaultPatchedLines)) ([IO.File]::ReadAllBytes($path))
        }
    }

    Context 'apply, restore and status with DefaultEngine.ini' {

        It 'patches both files of both games and backs up each stock file' {
            $i = New-FakeInstall
            $stock = @{}
            foreach ($p in $i.EuFile, $i.EwFile, $i.EuDefault, $i.EwDefault) { $stock[$p] = Get-Sha256 $p }
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root, '--quiet')
            Assert-Equal 0 $r.Code $r.Output
            Assert-Equal 'patched' (Get-FileState $i.EuDefault $script:DefaultOverlay)
            Assert-Equal 'patched' (Get-FileState $i.EwDefault $script:DefaultOverlay)
            Assert-Equal $stock[$i.EuFile] (Get-Sha256 (Join-Path $i.Backup 'enemy-unknown\BaseEngine.ini'))
            Assert-Equal $stock[$i.EuDefault] (Get-Sha256 (Join-Path $i.Backup 'enemy-unknown\DefaultEngine.ini'))
            Assert-Equal $stock[$i.EwFile] (Get-Sha256 (Join-Path $i.Backup 'enemy-within\BaseEngine.ini'))
            Assert-Equal $stock[$i.EwDefault] (Get-Sha256 (Join-Path $i.Backup 'enemy-within\DefaultEngine.ini'))
        }

        It 'keeps each game''s own texture sizes' {
            $i = New-FakeInstall
            Invoke-Cli $i @('apply', '--game-dir', $i.Root, '--quiet') | Out-Null
            $ew = [IO.File]::ReadAllText($i.EwDefault)
            Assert-True ($ew.Contains('TEXTUREGROUP_World=(MinLODSize=256,MaxLODSize=1024,LODBias=0,MinMagFilter=aniso,MipFilter=aniso)')) $ew
            $eu = [IO.File]::ReadAllText($i.EuDefault)
            Assert-True ($eu.Contains('TEXTUREGROUP_World=(MinLODSize=256,MaxLODSize=1024,LODBias=1,MinMagFilter=aniso,MipFilter=aniso)')) $eu
        }

        It 'upgrades an install from an earlier version: patches only DefaultEngine.ini and keeps the BaseEngine.ini backup' {
            $i = New-FakeInstall -NoXew -EuText (Join-Lines $script:PatchedLines)
            $baseBackup = Join-Path $i.Backup 'enemy-unknown\BaseEngine.ini'
            New-Item -ItemType Directory -Path (Split-Path -Parent $baseBackup) -Force | Out-Null
            [IO.File]::WriteAllBytes($baseBackup, (Get-Latin1Bytes (Join-Lines $script:StockLines)))
            $baseBefore = Get-Sha256 $i.EuFile
            $defaultStock = Get-Sha256 $i.EuDefault
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root)
            Assert-Equal 0 $r.Code $r.Output
            Assert-True ($r.Output -match 'BaseEngine\.ini: already patched') $r.Output
            Assert-Equal $baseBefore (Get-Sha256 $i.EuFile)
            Assert-Equal 'patched' (Get-FileState $i.EuDefault $script:DefaultOverlay)
            Assert-Equal $defaultStock (Get-Sha256 (Join-Path $i.Backup 'enemy-unknown\DefaultEngine.ini'))
            Assert-Equal (Get-Sha256Hex (Get-Latin1Bytes (Join-Lines $script:StockLines))) (Get-Sha256 $baseBackup)
        }

        It 'handles each file on its own: a refused file does not stop the other' {
            $lines = $script:DefaultStockLines.Clone()
            $lines[8] = $script:DefaultPatchedLines[8]
            $i = New-FakeInstall -NoXew -EuDefaultText (Join-Lines $lines)
            $defaultBefore = Get-Sha256 $i.EuDefault
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root)
            Assert-Equal 1 $r.Code
            Assert-True ($r.Output -match 'DefaultEngine\.ini is partially patched') $r.Output
            Assert-Equal $defaultBefore (Get-Sha256 $i.EuDefault)
            Assert-Equal 'patched' (Get-FileState $i.EuFile $script:Overlay)
        }

        It 'fails for a game whose DefaultEngine.ini is missing' {
            $i = New-FakeInstall -NoXew -NoDefaultEngine
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root)
            Assert-Equal 1 $r.Code
            Assert-True ($r.Output -match 'DefaultEngine\.ini.*not found') $r.Output
        }

        It 'restores both files byte-for-byte' {
            $i = New-FakeInstall
            $stock = @{}
            foreach ($p in $i.EuFile, $i.EwFile, $i.EuDefault, $i.EwDefault) { $stock[$p] = Get-Sha256 $p }
            Invoke-Cli $i @('apply', '--game-dir', $i.Root, '--quiet') | Out-Null
            $r = Invoke-Cli $i @('restore', '--game-dir', $i.Root, '--quiet')
            Assert-Equal 0 $r.Code $r.Output
            foreach ($p in $stock.Keys) { Assert-Equal $stock[$p] (Get-Sha256 $p) $p }
        }

        It 'tells you the game will rebuild its per-user settings after a change' {
            $i = New-FakeInstall -NoXew
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root)
            Assert-True ($r.Output -like '*resets your resolution and graphics options*') $r.Output
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root)
            Assert-True ($r.Output -notlike '*resets your resolution and graphics options*') 'no reminder when nothing changed'
        }
    }

    Context 'a file patched with other values for the same settings (e.g. an earlier version)' {

        BeforeAll {
            # DefaultEngine.ini as an earlier version of the patch left it: same lines, other MipFilter.
            $script:DefaultOtherLines = $script:DefaultStockLines.Clone()
            $script:DefaultOtherLines[7] = $script:DefaultStockLines[7].Replace('MipFilter=point', 'MipFilter=linear')
            $script:DefaultOtherLines[8] = $script:DefaultStockLines[8].Replace('MipFilter=point', 'MipFilter=linear')

            function Set-Backup($Install, [string]$Game, [string]$Name, [string]$Text) {
                $path = Join-Path $Install.Backup "$Game\$Name"
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                [IO.File]::WriteAllBytes($path, (Get-Latin1Bytes $Text))
                return $path
            }
        }

        It 'refuses to apply, and keeps the stock backup' {
            $i = New-FakeInstall -NoXew -EuDefaultText (Join-Lines $script:DefaultOtherLines)
            $backup = Set-Backup $i 'enemy-unknown' 'DefaultEngine.ini' (Join-Lines $script:DefaultStockLines)
            $stockHash = Get-Sha256 $backup
            $before = Get-Sha256 $i.EuDefault
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root)
            Assert-Equal 1 $r.Code
            Assert-True ($r.Output -match 'DefaultEngine\.ini has other values for this patch''s settings') $r.Output
            Assert-True ($r.Output -like '*Restore.cmd*') $r.Output
            Assert-Equal $before (Get-Sha256 $i.EuDefault)
            Assert-Equal $stockHash (Get-Sha256 $backup)
        }

        It 'restores the stock backup over it' {
            $i = New-FakeInstall -NoXew -EuDefaultText (Join-Lines $script:DefaultOtherLines)
            $backup = Set-Backup $i 'enemy-unknown' 'DefaultEngine.ini' (Join-Lines $script:DefaultStockLines)
            $r = Invoke-Cli $i @('restore', '--game-dir', $i.Root)
            Assert-Equal 0 $r.Code $r.Output
            Assert-Equal (Get-Sha256 $backup) (Get-Sha256 $i.EuDefault)
        }

        It 'then applies cleanly after the restore' {
            $i = New-FakeInstall -NoXew -EuDefaultText (Join-Lines $script:DefaultOtherLines)
            Set-Backup $i 'enemy-unknown' 'DefaultEngine.ini' (Join-Lines $script:DefaultStockLines) | Out-Null
            Invoke-Cli $i @('restore', '--game-dir', $i.Root, '--quiet') | Out-Null
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root, '--quiet')
            Assert-Equal 0 $r.Code $r.Output
            Assert-Equal 'patched' (Get-FileState $i.EuDefault $script:DefaultOverlay)
        }

        It 'still treats a file that also differs elsewhere as a new stock file (a game update)' {
            $updated = Join-Lines ($script:DefaultStockLines + @('', '[NewInUpdate]', 'A=1'))
            $i = New-FakeInstall -NoXew -EuDefaultText $updated
            $backup = Set-Backup $i 'enemy-unknown' 'DefaultEngine.ini' (Join-Lines $script:DefaultStockLines)
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root, '--quiet')
            Assert-Equal 0 $r.Code $r.Output
            Assert-Equal (Get-Sha256Hex (Get-Latin1Bytes $updated)) (Get-Sha256 $backup)
            Assert-Equal 'patched' (Get-FileState $i.EuDefault $script:DefaultOverlay)
        }

        It 'is reported by status, not shown as stock' {
            $i = New-FakeInstall -NoXew -EuDefaultText (Join-Lines $script:DefaultOtherLines)
            Set-Backup $i 'enemy-unknown' 'DefaultEngine.ini' (Join-Lines $script:DefaultStockLines) | Out-Null
            $r = Invoke-Cli $i @('status', '--game-dir', $i.Root)
            Assert-Equal 0 $r.Code $r.Output
            Assert-True ($r.Output -match 'DefaultEngine\.ini\s*:\s*patched with other values .*Restore\.cmd.*Apply\.cmd') $r.Output
            Assert-True ($r.Output -match 'BaseEngine\.ini\s*:\s*stock \(backup: no\)') $r.Output
        }

        It 'works the same for plain Key=Value settings' {
            $other = $script:StockLines.Clone()
            $other[15] = 'MaxAnisotropy=8'
            $i = New-FakeInstall -NoXew -EuText (Join-Lines $other)
            $backup = Set-Backup $i 'enemy-unknown' 'BaseEngine.ini' (Join-Lines $script:StockLines)
            $stockHash = Get-Sha256 $backup
            $r = Invoke-Cli $i @('apply', '--game-dir', $i.Root)
            Assert-Equal 1 $r.Code
            Assert-True ($r.Output -match 'BaseEngine\.ini has other values') $r.Output
            Assert-Equal $stockHash (Get-Sha256 $backup)
        }
    }

    Context 'status note on XComEngine.ini' {

        BeforeAll {
            function New-UserConfig($Install, [string]$Folder, [datetime]$Time) {
                $dir = Join-Path $Install.Documents "My Games\$Folder\XComGame\Config"
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                $path = Join-Path $dir 'XComEngine.ini'
                [IO.File]::WriteAllText($path, "[IniVersion]`r`n")
                (Get-Item -LiteralPath $path).LastWriteTime = $Time
                return $path
            }
        }

        It 'says when XComEngine.ini has not been created yet' {
            $i = New-FakeInstall -NoXew
            $r = Invoke-Cli $i @('status', '--game-dir', $i.Root)
            Assert-True ($r.Output -match 'XComEngine\.ini\s*:\s*not created yet') $r.Output
        }

        It 'says when the game will rebuild XComEngine.ini on the next launch' {
            $i = New-FakeInstall -NoXew
            New-UserConfig $i 'XCOM - Enemy Unknown' (Get-Date).AddDays(-1) | Out-Null
            $r = Invoke-Cli $i @('status', '--game-dir', $i.Root)
            Assert-True ($r.Output -match 'XComEngine\.ini\s*:\s*older than') $r.Output
        }

        It 'says when XComEngine.ini is newer, so in-game options override the patch' {
            $i = New-FakeInstall -NoXew
            New-UserConfig $i 'XCOM - Enemy Unknown' (Get-Date).AddDays(1) | Out-Null
            $r = Invoke-Cli $i @('status', '--game-dir', $i.Root)
            Assert-True ($r.Output -match 'XComEngine\.ini\s*:\s*newer than') $r.Output
        }

        It 'looks in the Enemy Within folder for Enemy Within' {
            $i = New-FakeInstall
            New-UserConfig $i 'XCOM - Enemy Within' (Get-Date).AddDays(1) | Out-Null
            $r = Invoke-Cli $i @('status', '--game-dir', $i.Root)
            Assert-True ($r.Output -match 'Enemy Unknown[\s\S]*XComEngine\.ini\s*:\s*not created yet[\s\S]*Enemy Within[\s\S]*XComEngine\.ini\s*:\s*newer than') $r.Output
        }

        It 'never writes to XComEngine.ini' {
            $i = New-FakeInstall -NoXew
            $path = New-UserConfig $i 'XCOM - Enemy Unknown' (Get-Date).AddDays(-1)
            $before = Get-Sha256 $path
            $stamp = (Get-Item -LiteralPath $path).LastWriteTime
            Invoke-Cli $i @('apply', '--game-dir', $i.Root, '--quiet') | Out-Null
            Invoke-Cli $i @('status', '--game-dir', $i.Root) | Out-Null
            Invoke-Cli $i @('restore', '--game-dir', $i.Root, '--quiet') | Out-Null
            Assert-Equal $before (Get-Sha256 $path)
            Assert-Equal $stamp (Get-Item -LiteralPath $path).LastWriteTime
        }
    }
}
