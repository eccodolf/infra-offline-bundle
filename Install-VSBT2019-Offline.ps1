param(
    [string]$Repo = "eccodolf/infra-offline-bundle",

    [string]$Tag = "vsbt2019-v142-winsdk19041-2026-06",

    [string]$WorkDir = "",

    [string]$InstallPath = "C:\BuildTools\VS2019",

    [string]$Proxy = "",

    [switch]$SkipDownloads
)

$ErrorActionPreference = "Stop"
$script:DownloadProxy = $Proxy
$script:DownloadProxyInitialized = $false

function Test-IsAdministrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path)
}

function Get-UniqueExistingDirs {
    param(
        [string[]]$Paths
    )

    $Seen = @{}
    foreach ($Path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            continue
        }

        $FullPath = Get-FullPath $Path
        $Key = $FullPath.ToUpperInvariant()
        if (-not $Seen.ContainsKey($Key)) {
            $Seen[$Key] = $true
            $FullPath
        }
    }
}

function Test-LayoutRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (
        (Test-Path (Join-Path $Path "vs_buildtools.exe")) -and
        (Test-Path (Join-Path $Path "Response.json")) -and
        (Test-Path (Join-Path $Path "Catalog.json")) -and
        (Test-Path (Join-Path $Path "ChannelManifest.json"))
    )
}

function Find-LayoutRoot {
    param(
        [string[]]$Candidates
    )

    foreach ($Candidate in (Get-UniqueExistingDirs $Candidates)) {
        if (Test-LayoutRoot $Candidate) {
            return $Candidate
        }
    }

    return $null
}

function Find-ExistingFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [string[]]$SearchDirs
    )

    foreach ($Dir in (Get-UniqueExistingDirs $SearchDirs)) {
        $Candidate = Join-Path $Dir $FileName
        if (Test-Path $Candidate) {
            return $Candidate
        }
    }

    return $null
}

function Read-ValidatedManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedRepo,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedTag
    )

    try {
        $Manifest = Get-Content $Path -Raw | ConvertFrom-Json
    }
    catch {
        Write-Host "Ignoring unreadable manifest: $Path"
        return $null
    }

    if (-not $Manifest.files -or $Manifest.files.Count -eq 0) {
        Write-Host "Ignoring manifest with no files: $Path"
        return $null
    }

    if ($Manifest.repo -ne $ExpectedRepo) {
        Write-Host "Ignoring manifest for repo '$($Manifest.repo)': $Path"
        return $null
    }

    $ManifestTag = $Manifest.release_tag
    if ([string]::IsNullOrWhiteSpace($ManifestTag)) {
        $ManifestTag = $Manifest.tag
    }

    if ($ManifestTag -ne $ExpectedTag) {
        Write-Host "Ignoring manifest for tag '$ManifestTag': $Path"
        return $null
    }

    return $Manifest
}

function Find-ValidManifestFile {
    param(
        [string[]]$SearchDirs,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedRepo,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedTag
    )

    foreach ($Dir in (Get-UniqueExistingDirs $SearchDirs)) {
        $Candidate = Join-Path $Dir "manifest.json"
        if (-not (Test-Path $Candidate)) {
            continue
        }

        $Manifest = Read-ValidatedManifest `
            -Path $Candidate `
            -ExpectedRepo $ExpectedRepo `
            -ExpectedTag $ExpectedTag

        if ($Manifest) {
            return $Candidate
        }
    }

    return $null
}

function Get-GitHubReleaseAssetUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [string]$Tag,

        [Parameter(Mandatory = $true)]
        [string]$AssetName
    )

    $EncodedAssetName = [System.Uri]::EscapeDataString($AssetName)
    return "https://github.com/$Repo/releases/download/$Tag/$EncodedAssetName"
}

function Get-DownloadProxy {
    if ($script:DownloadProxyInitialized) {
        return $script:DownloadProxy
    }

    $script:DownloadProxyInitialized = $true

    if ([string]::IsNullOrWhiteSpace($script:DownloadProxy)) {
        $EnteredProxy = Read-Host "Proxy for GitHub downloads, format http://host:port (leave empty for direct)"
        $script:DownloadProxy = $EnteredProxy.Trim()
    }

    return $script:DownloadProxy
}

function Download-File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$OutFile
    )

    Write-Host "Downloading: $Url"
    $Request = @{
        UseBasicParsing = $true
        Uri = $Url
        OutFile = $OutFile
    }

    $EffectiveProxy = Get-DownloadProxy
    if (-not [string]::IsNullOrWhiteSpace($EffectiveProxy)) {
        $Request.Proxy = $EffectiveProxy
    }

    Invoke-WebRequest @Request
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Copy-VisualStudioInstallerLogs {
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$Since,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDir
    )

    $LogFiles = Get-ChildItem -Path $env:TEMP -File -Filter "dd_*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $Since.AddMinutes(-1) } |
        Sort-Object LastWriteTime -Descending

    if (-not $LogFiles) {
        Write-Host "No fresh Visual Studio dd_*.log files found in $env:TEMP"
        return
    }

    foreach ($LogFile in $LogFiles) {
        Copy-Item -Path $LogFile.FullName -Destination (Join-Path $DestinationDir $LogFile.Name) -Force
    }

    Write-Host "Copied Visual Studio installer logs to: $DestinationDir"
}

function Find-ValidExistingAsset {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AssetName,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256,

        [string[]]$SearchDirs
    )

    foreach ($Dir in (Get-UniqueExistingDirs $SearchDirs)) {
        $Candidate = Join-Path $Dir $AssetName
        if (-not (Test-Path $Candidate)) {
            continue
        }

        $ActualSha256 = Get-Sha256 $Candidate
        if ($ActualSha256 -eq $ExpectedSha256.ToUpperInvariant()) {
            return $Candidate
        }
    }

    return $null
}

function Ensure-Asset {
    param(
        [Parameter(Mandatory = $true)]
        $File,

        [Parameter(Mandatory = $true)]
        [string]$AssetsDir,

        [string[]]$SearchDirs,

        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [string]$Tag,

        [switch]$SkipDownloads
    )

    $OutFile = Join-Path $AssetsDir $File.name
    $ExpectedSha256 = $File.sha256.ToUpperInvariant()

    if (Test-Path $OutFile) {
        $ActualSha256 = Get-Sha256 $OutFile
        if ($ActualSha256 -eq $ExpectedSha256) {
            Write-Host "Already exists and SHA256 OK: $($File.name)"
            return
        }

        Write-Host "Existing file has wrong SHA256: $($File.name)"
        Remove-Item -Force $OutFile
    }

    $Existing = Find-ValidExistingAsset `
        -AssetName $File.name `
        -ExpectedSha256 $ExpectedSha256 `
        -SearchDirs $SearchDirs

    if ($Existing) {
        if ((Get-FullPath $Existing) -ne (Get-FullPath $OutFile)) {
            Write-Host "Reusing already downloaded asset: $($File.name)"
            Copy-Item -Path $Existing -Destination $OutFile -Force
        }
        else {
            Write-Host "Already exists and SHA256 OK: $($File.name)"
        }
        return
    }

    if ($SkipDownloads) {
        throw "Missing asset and downloads are disabled: $($File.name)"
    }

    $Url = Get-GitHubReleaseAssetUrl -Repo $Repo -Tag $Tag -AssetName $File.name
    Download-File -Url $Url -OutFile $OutFile

    $ActualAfterDownload = Get-Sha256 $OutFile
    if ($ActualAfterDownload -ne $ExpectedSha256) {
        throw "SHA256 mismatch after download for $($File.name). Expected $ExpectedSha256, got $ActualAfterDownload"
    }
}

if (-not (Test-IsAdministrator)) {
    throw "Run this script from an elevated PowerShell session."
}

$CurrentDir = (Get-Location).ProviderPath
if ($PSScriptRoot) {
    $ScriptDir = (Resolve-Path $PSScriptRoot).Path
}
else {
    $ScriptDir = $CurrentDir
}

$BaseDir = Get-FullPath $CurrentDir
$BaseParentDir = Split-Path -Parent $BaseDir
$ScriptParentDir = Split-Path -Parent $ScriptDir

if ([string]::IsNullOrWhiteSpace($WorkDir)) {
    $WorkDir = Join-Path $BaseDir "vsbt2019-install"
}

$WorkDir = Get-FullPath $WorkDir
$InstallPath = Get-FullPath $InstallPath
$DefaultAssetsDir = Join-Path $WorkDir "assets"
$DefaultLayoutDir = Join-Path $WorkDir "layout"
$LogsDir = Join-Path $WorkDir "logs"
$RunStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$TranscriptPath = Join-Path $LogsDir "Install-VSBT2019-Offline-$RunStamp.log"

New-Item -ItemType Directory -Force $WorkDir | Out-Null
New-Item -ItemType Directory -Force $InstallPath | Out-Null
New-Item -ItemType Directory -Force $LogsDir | Out-Null

Start-Transcript -Path $TranscriptPath -Force | Out-Null

try {

$LayoutCandidates = @(
    $BaseDir,
    $ScriptDir,
    (Join-Path $BaseDir "vs2019-buildtools"),
    (Join-Path $ScriptDir "vs2019-buildtools"),
    (Join-Path $BaseParentDir "vs2019-buildtools"),
    (Join-Path $ScriptParentDir "vs2019-buildtools"),
    (Join-Path $BaseDir "layout"),
    (Join-Path $ScriptDir "layout"),
    $DefaultLayoutDir
)

$ExistingLayout = Find-LayoutRoot -Candidates $LayoutCandidates

    if ($ExistingLayout) {
        $LayoutDir = $ExistingLayout
        Write-Host "Using existing offline layout: $LayoutDir"
    }
    else {
        $AssetsDir = $DefaultAssetsDir
        New-Item -ItemType Directory -Force $AssetsDir | Out-Null

        $SearchDirs = @(
            $AssetsDir,
            $WorkDir,
            $BaseDir,
            (Join-Path $BaseDir "assets"),
            (Join-Path $BaseDir "vsbt2019-bootstrap"),
            (Join-Path $BaseDir "vs2019-buildtools-release"),
            $ScriptDir,
            (Join-Path $ScriptDir "assets"),
            (Join-Path $ScriptDir "vsbt2019-bootstrap"),
            (Join-Path $ScriptDir "vs2019-buildtools-release"),
            (Join-Path $BaseParentDir "vsbt2019-bootstrap"),
            (Join-Path $BaseParentDir "vs2019-buildtools-release"),
            (Join-Path $ScriptParentDir "vsbt2019-bootstrap"),
            (Join-Path $ScriptParentDir "vs2019-buildtools-release")
        )

        Write-Host "[1/5] Reading manifest..."

        $ManifestPath = Join-Path $AssetsDir "manifest.json"
        $Manifest = $null

        if (Test-Path $ManifestPath) {
            $Manifest = Read-ValidatedManifest `
                -Path $ManifestPath `
                -ExpectedRepo $Repo `
                -ExpectedTag $Tag

            if ($Manifest) {
                Write-Host "Using existing manifest: $ManifestPath"
            }
            else {
                Remove-Item -Force $ManifestPath
            }
        }

        if (-not $Manifest) {
            $ExistingManifest = Find-ValidManifestFile `
                -SearchDirs $SearchDirs `
                -ExpectedRepo $Repo `
                -ExpectedTag $Tag

            if ($ExistingManifest) {
                Write-Host "Reusing existing manifest: $ExistingManifest"
                Copy-Item -Path $ExistingManifest -Destination $ManifestPath -Force
                $Manifest = Read-ValidatedManifest `
                    -Path $ManifestPath `
                    -ExpectedRepo $Repo `
                    -ExpectedTag $Tag
            }
            else {
                if ($SkipDownloads) {
                    throw "manifest.json not found and downloads are disabled."
                }

                $ManifestUrl = Get-GitHubReleaseAssetUrl -Repo $Repo -Tag $Tag -AssetName "manifest.json"
                Download-File -Url $ManifestUrl -OutFile $ManifestPath
                $Manifest = Read-ValidatedManifest `
                    -Path $ManifestPath `
                    -ExpectedRepo $Repo `
                    -ExpectedTag $Tag

                if (-not $Manifest) {
                    throw "Downloaded manifest does not match repo/tag: $Repo $Tag"
                }
            }
        }

        Write-Host "[2/5] Ensuring release assets are present..."

        foreach ($File in $Manifest.files) {
            if ($File.name -eq "Install-VSBT2019-Offline.ps1") {
                Write-Host "Skipping installer script asset: $($File.name)"
                continue
            }

            Ensure-Asset `
                -File $File `
                -AssetsDir $AssetsDir `
                -SearchDirs $SearchDirs `
                -Repo $Repo `
                -Tag $Tag `
                -SkipDownloads:$SkipDownloads
        }

        Write-Host "[3/5] Verifying SHA256..."

        foreach ($File in $Manifest.files) {
            if ($File.name -eq "Install-VSBT2019-Offline.ps1") {
                continue
            }

            $Path = Join-Path $AssetsDir $File.name

            if (-not (Test-Path $Path)) {
                throw "Missing file: $($File.name)"
            }

            $Actual = Get-Sha256 $Path
            $Expected = $File.sha256.ToUpperInvariant()

            if ($Actual -ne $Expected) {
                throw "SHA256 mismatch for $($File.name). Expected $Expected, got $Actual"
            }

            Write-Host "OK: $($File.name)"
        }

        Write-Host "[4/5] Extracting offline layout..."

        $SevenZip = Join-Path $AssetsDir "7z.exe"

        if (-not (Test-Path $SevenZip)) {
            throw "7z.exe not found: $SevenZip"
        }

        $FirstPartManifestEntries = @($Manifest.files | Where-Object { $_.name -like "*.7z.001" })

        if ($FirstPartManifestEntries.Count -ne 1) {
            throw "Manifest must contain exactly one archive first part (*.7z.001), got $($FirstPartManifestEntries.Count)."
        }

        $FirstPartPath = Join-Path $AssetsDir $FirstPartManifestEntries[0].name

        if (-not (Test-Path $FirstPartPath)) {
            throw "Archive first part not found after verification: $($FirstPartManifestEntries[0].name)"
        }

        $FirstPart = Get-Item $FirstPartPath

        $LayoutDir = $DefaultLayoutDir
        New-Item -ItemType Directory -Force $LayoutDir | Out-Null

        if (Test-LayoutRoot $LayoutDir) {
            Write-Host "Using already extracted offline layout: $LayoutDir"
        }
        else {
            & $SevenZip x $FirstPart.FullName "-o$LayoutDir" -y

            if ($LASTEXITCODE -ne 0) {
                throw "7-Zip extraction failed with exit code $LASTEXITCODE"
            }
        }

        if (-not (Test-LayoutRoot $LayoutDir)) {
            throw "Extracted layout is incomplete: $LayoutDir"
        }
    }

    Write-Host "[5/5] Installing Visual Studio Build Tools 2019 offline..."

    $Installer = Join-Path $LayoutDir "vs_buildtools.exe"

    if (-not (Test-Path $Installer)) {
        throw "vs_buildtools.exe not found: $Installer"
    }

    $InstallArgs = @(
        "--noWeb",
        "--wait",
        "--norestart",
        "--passive",
        "--installPath",
        $InstallPath
    )

    Write-Host "Script log: $TranscriptPath"
    Write-Host "Visual Studio installer logs will be copied from $env:TEMP to: $LogsDir"
    $InstallerStart = Get-Date
    Push-Location $LayoutDir
    try {
        & $Installer @InstallArgs
        $ExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    Copy-VisualStudioInstallerLogs -Since $InstallerStart -DestinationDir $LogsDir

    if ($ExitCode -eq 0) {
        Write-Host "VS Build Tools installed successfully."
    }
    elseif ($ExitCode -eq 3010) {
        Write-Host "VS Build Tools installed successfully. Reboot required."
    }
    else {
        throw "VS Build Tools installer failed with exit code $ExitCode. See logs: $LogsDir"
    }

    Write-Host "Script log: $TranscriptPath"
}
finally {
    Stop-Transcript | Out-Null
}
