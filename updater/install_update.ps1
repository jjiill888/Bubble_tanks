param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$ExecutableName,
    [string]$ExpectedSha256 = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
    throw "Missing update package: $PackagePath"
}

if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) {
    throw "Missing install dir: $InstallDir"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bubble-tanks-update-" + [System.Guid]::NewGuid().ToString("N"))
$extractDir = Join-Path $tempRoot "payload"

try {
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
    Start-Sleep -Seconds 1

    if ($ExpectedSha256 -ne "") {
        $actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $PackagePath).Hash.ToLowerInvariant()
        if ($actualSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
            throw "SHA256 mismatch"
        }
    }

    Expand-Archive -LiteralPath $PackagePath -DestinationPath $extractDir -Force
    $subdirs = @(Get-ChildItem -LiteralPath $extractDir -Directory)
    $sourceDir = if ($subdirs.Count -eq 1) { $subdirs[0].FullName } else { $extractDir }
    $null = robocopy $sourceDir $InstallDir /E /R:2 /W:1 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed with exit code $LASTEXITCODE"
    }

    Remove-Item -LiteralPath $PackagePath -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath (Join-Path $InstallDir $ExecutableName) | Out-Null
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}