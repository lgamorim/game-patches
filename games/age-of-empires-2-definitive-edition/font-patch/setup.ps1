# Prepares .\runtime on first run (once per computer). Nothing is installed system-wide.
#
#   runtime\        the official Windows embeddable Python 3.12.10, from python.org
#   runtime\site\   numpy, fontTools and Pillow, unpacked from their official PyPI wheels
#
# Gates:
#   - python.exe and python312.dll must carry a valid Authenticode signature from the
#     Python Software Foundation; otherwise nothing is kept.
#   - each wheel must match the SHA-256 pinned below (as published on PyPI); otherwise
#     nothing is kept.
#
# To change library versions, update $wheels and delete runtime\site.
$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$runtime = Join-Path $here 'runtime'
$site    = Join-Path $runtime 'site'
$marker  = Join-Path $site '.complete'

$pythonUrl = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip'
$pythonMd5 = 'fe8ef205f2e9c3ba44d0cf9954e1abd3'   # as listed on python.org for this file

$wheels = @(
    @{ Name   = 'numpy-2.2.6-cp312-cp312-win_amd64.whl'
       Url    = 'https://files.pythonhosted.org/packages/36/fa/8c9210162ca1b88529ab76b41ba02d433fd54fecaf6feb70ef9f124683f1/numpy-2.2.6-cp312-cp312-win_amd64.whl'
       Sha256 = 'c1f9540be57940698ed329904db803cf7a402f3fc200bfe599334c9bd84a40b2' },
    @{ Name   = 'fonttools-4.60.1-cp312-cp312-win_amd64.whl'
       Url    = 'https://files.pythonhosted.org/packages/88/8f/a55b5550cd33cd1028601df41acd057d4be20efa5c958f417b0c0613924d/fonttools-4.60.1-cp312-cp312-win_amd64.whl'
       Sha256 = '992775c9fbe2cf794786fa0ffca7f09f564ba3499b8fe9f2f80bd7197db60383' },
    @{ Name   = 'pillow-11.3.0-cp312-cp312-win_amd64.whl'
       Url    = 'https://files.pythonhosted.org/packages/8c/ce/e7dfc873bdd9828f3b6e5c2bbb74e47a98ec23cc5c74fc4e54462f0d9204/pillow-11.3.0-cp312-cp312-win_amd64.whl'
       Sha256 = 'a6444696fce635783440b7f7a9fc24b3ad10a9ea3f0ab66c5905be1c19ccf17d' }
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Save-Download([string]$url) {
    $file = Join-Path $env:TEMP ('fontpatch-' + [guid]::NewGuid() + '.zip')
    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
    return $file
}

function Remove-IfPresent([string]$path) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
}

# 1. Python runtime
if (-not (Test-Path -LiteralPath (Join-Path $runtime 'python.exe'))) {
    $stage = Join-Path $here 'runtime.partial'
    Remove-IfPresent $stage
    Write-Host 'First run on this computer: downloading Python 3.12.10 (embeddable, about 11 MB) from python.org...'
    $zip = Save-Download $pythonUrl
    try {
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm MD5).Hash.ToLowerInvariant()
        if ($actual -ne $pythonMd5) { Write-Warning "Download MD5 $actual differs from the value recorded for this release; relying on the signature check." }
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $stage)
    } finally {
        Remove-IfPresent $zip
    }
    foreach ($file in 'python.exe', 'python312.dll') {
        $sig = Get-AuthenticodeSignature -LiteralPath (Join-Path $stage $file)
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Python Software Foundation') {
            Remove-IfPresent $stage
            throw "$file is not validly signed by the Python Software Foundation (status: $($sig.Status)). Nothing was installed."
        }
    }
    Remove-IfPresent $runtime   # a leftover runtime without python.exe
    Rename-Item -LiteralPath $stage -NewName 'runtime'
    Write-Host 'Python runtime ready (signature verified).'
}

# 2. Libraries
$wanted = ($wheels | ForEach-Object { $_.Name }) -join "`n"
if ((Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $marker -Raw).Trim() -eq $wanted) { exit 0 }

$stage = Join-Path $runtime 'site.partial'
Remove-IfPresent $stage
Write-Host 'Downloading numpy, fontTools and Pillow (about 22 MB) from PyPI...'
foreach ($w in $wheels) {
    Write-Host "  $($w.Name)"
    $zip = Save-Download $w.Url
    try {
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $w.Sha256) {
            Remove-IfPresent $stage
            throw "$($w.Name) has SHA-256 $actual, expected $($w.Sha256). Nothing was installed."
        }
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $stage)
    } finally {
        Remove-IfPresent $zip
    }
}
Set-Content -LiteralPath (Join-Path $stage '.complete') -Value $wanted -Encoding ASCII
Remove-IfPresent $site
Rename-Item -LiteralPath $stage -NewName 'site'
Write-Host 'Libraries ready (SHA-256 verified).'
