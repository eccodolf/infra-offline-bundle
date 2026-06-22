param(
    [string]$Repo = "eccodolf/infra-offline-bundle",

    [string]$Tag = "python-ldap-3.4.5-builddeps-2026-06",

    [string]$WorkDir = "",

    [string]$InstallDir = "",

    [string]$VenvPath = "",

    [string]$Proxy = "",

    [switch]$NoIndex,

    [switch]$InstallPythonLdap,

    [switch]$SkipDownloads
)

$ErrorActionPreference = "Stop"
$script:DownloadProxy = $Proxy
$script:DownloadProxyInitialized = $false

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

    if ($Manifest.release_tag -ne $ExpectedTag) {
        Write-Host "Ignoring manifest for tag '$($Manifest.release_tag)': $Path"
        return $null
    }

    if ($Manifest.includes_prebuilt_python_ldap_wheel -eq $true) {
        throw "Manifest points to a prebuilt python-ldap wheel payload; this installer expects build dependencies only."
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
        $Candidate = Join-Path $Dir "python-ldap-builddeps-manifest.json"
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
            return $OutFile
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
        return $OutFile
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

    return $OutFile
}

function Write-TextFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Write-PipConfigFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Wheelhouse,

        [switch]$NoIndex
    )

    if (Test-Path $Path) {
        $BackupPath = "$Path.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -Path $Path -Destination $BackupPath -Force
        Write-Host "Existing pip.ini backed up to: $BackupPath"
    }

    $NoIndexLine = ""
    if ($NoIndex) {
        $NoIndexLine = "no-index = true"
    }

    $Content = @"
[global]
find-links = $Wheelhouse
$NoIndexLine
"@

    Write-TextFile -Path $Path -Content $Content.Trim()
}

function Get-EnvironmentVariableSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $EnvPath = "Env:$Name"
    return [pscustomobject]@{
        Name = $Name
        WasSet = Test-Path $EnvPath
        Value = [Environment]::GetEnvironmentVariable($Name, "Process")
    }
}

function Restore-EnvironmentVariable {
    param(
        [Parameter(Mandatory = $true)]
        $Snapshot
    )

    if ($Snapshot.WasSet) {
        [Environment]::SetEnvironmentVariable($Snapshot.Name, $Snapshot.Value, "Process")
    }
    else {
        [Environment]::SetEnvironmentVariable($Snapshot.Name, $null, "Process")
    }
}

function Invoke-PythonLdapInstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VenvPath,

        [Parameter(Mandatory = $true)]
        [string]$PipConfig,

        [Parameter(Mandatory = $true)]
        [string]$Wheelhouse,

        [switch]$NoIndex
    )

    $PythonExe = Join-Path $VenvPath "Scripts\python.exe"
    if (-not (Test-Path $PythonExe)) {
        throw "python.exe not found in venv: $PythonExe"
    }

    $Snapshots = @(
        $(Get-EnvironmentVariableSnapshot -Name "PIP_CONFIG_FILE"),
        $(Get-EnvironmentVariableSnapshot -Name "PIP_FIND_LINKS"),
        $(Get-EnvironmentVariableSnapshot -Name "PIP_NO_INDEX")
    )

    try {
        $env:PIP_CONFIG_FILE = $PipConfig
        $env:PIP_FIND_LINKS = "$Wheelhouse $env:PIP_FIND_LINKS".Trim()
        if ($NoIndex) {
            $env:PIP_NO_INDEX = "1"
        }

        Write-Host "Installing python-ldap==3.4.5 into venv with temporary pip config..."
        & $PythonExe -m pip install "python-ldap==3.4.5"
        if ($LASTEXITCODE -ne 0) {
            throw "pip install python-ldap==3.4.5 failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        foreach ($Snapshot in $Snapshots) {
            Restore-EnvironmentVariable -Snapshot $Snapshot
        }
    }
}

function Assert-InstalledPayload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallDir
    )

    $RequiredPaths = @(
        "include\lber.h",
        "include\ldap.h",
        "lib\olber32_a.lib",
        "lib\oldap32.lib",
        "lib\oldap_r.lib",
        "lib\libssl.lib",
        "lib\libcrypto.lib",
        "wheelhouse\python_ldap-3.4.5.tar.gz",
        "Use-PythonLdapBuildDeps.ps1"
    )

    $Missing = @()
    foreach ($RelativePath in $RequiredPaths) {
        $Path = Join-Path $InstallDir $RelativePath
        if (-not (Test-Path $Path)) {
            $Missing += $RelativePath
        }
    }

    if ($Missing.Count -gt 0) {
        $Text = ($Missing | ForEach-Object { " - $_" }) -join [Environment]::NewLine
        throw "Installed python-ldap build dependency payload is incomplete:$([Environment]::NewLine)$Text"
    }
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
    $WorkDir = Join-Path $BaseDir "python-ldap-builddeps-install"
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Join-Path $BaseDir "python-ldap-builddeps"
}

$WorkDir = Get-FullPath $WorkDir
$InstallDir = Get-FullPath $InstallDir
$AssetsDir = Join-Path $WorkDir "assets"
$StagingDir = Join-Path $WorkDir "staging"

New-Item -ItemType Directory -Force $WorkDir, $AssetsDir, $StagingDir | Out-Null

$SearchDirs = @(
    $AssetsDir,
    $WorkDir,
    $BaseDir,
    (Join-Path $BaseDir "assets"),
    (Join-Path $BaseDir "python-ldap-builddeps-bootstrap"),
    (Join-Path $BaseDir "python-ldap-builddeps-release"),
    $ScriptDir,
    (Join-Path $ScriptDir "assets"),
    (Join-Path $ScriptDir "python-ldap-builddeps-bootstrap"),
    (Join-Path $ScriptDir "python-ldap-builddeps-release"),
    (Join-Path $BaseParentDir "python-ldap-builddeps-bootstrap"),
    (Join-Path $BaseParentDir "python-ldap-builddeps-release"),
    (Join-Path $ScriptParentDir "python-ldap-builddeps-bootstrap"),
    (Join-Path $ScriptParentDir "python-ldap-builddeps-release")
)

Write-Host "[1/5] Reading python-ldap build dependency manifest..."

$ManifestPath = Join-Path $AssetsDir "python-ldap-builddeps-manifest.json"
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
            throw "python-ldap-builddeps-manifest.json not found and downloads are disabled."
        }

        $ManifestUrl = Get-GitHubReleaseAssetUrl `
            -Repo $Repo `
            -Tag $Tag `
            -AssetName "python-ldap-builddeps-manifest.json"
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

Write-Host "[2/5] Ensuring GitHub release assets are present..."
$ZipAssets = @($Manifest.files | Where-Object { $_.name -like "*.zip" })
if ($ZipAssets.Count -ne 1) {
    throw "Manifest must contain exactly one zip asset, got $($ZipAssets.Count)."
}

$ZipPath = Ensure-Asset `
    -File $ZipAssets[0] `
    -AssetsDir $AssetsDir `
    -SearchDirs $SearchDirs `
    -Repo $Repo `
    -Tag $Tag `
    -SkipDownloads:$SkipDownloads

Write-Host "[3/5] Extracting payload..."
if (Test-Path $StagingDir) {
    Remove-Item -LiteralPath $StagingDir -Recurse -Force
}
New-Item -ItemType Directory -Force $StagingDir | Out-Null
Expand-Archive -Path $ZipPath -DestinationPath $StagingDir -Force

$PackageSource = Join-Path $StagingDir "python-ldap-builddeps"
if (-not (Test-Path $PackageSource)) {
    $PackageSource = Get-ChildItem $StagingDir -Directory | Select-Object -First 1 | ForEach-Object { $_.FullName }
}

if (-not $PackageSource -or -not (Test-Path $PackageSource)) {
    throw "Could not find extracted python-ldap-builddeps package root."
}

New-Item -ItemType Directory -Force $InstallDir | Out-Null
Copy-Item -Path (Join-Path $PackageSource "*") -Destination $InstallDir -Recurse -Force

Write-Host "[4/5] Writing pip configuration..."
$Wheelhouse = Join-Path $InstallDir "wheelhouse"
$PipConfig = Join-Path $InstallDir "pip.ini"
Write-PipConfigFile -Path $PipConfig -Wheelhouse $Wheelhouse -NoIndex:$NoIndex

if (-not [string]::IsNullOrWhiteSpace($env:VIRTUAL_ENV) -and [string]::IsNullOrWhiteSpace($VenvPath)) {
    $VenvPath = $env:VIRTUAL_ENV
}

if (-not [string]::IsNullOrWhiteSpace($VenvPath)) {
    $VenvPath = Get-FullPath $VenvPath
    if (-not (Test-Path $VenvPath)) {
        throw "VenvPath does not exist: $VenvPath"
    }
}

Write-Host "[5/5] Verifying installed files..."
Assert-InstalledPayload -InstallDir $InstallDir

if ($InstallPythonLdap) {
    if ([string]::IsNullOrWhiteSpace($VenvPath)) {
        throw "Pass -VenvPath or activate a venv before using -InstallPythonLdap."
    }

    Invoke-PythonLdapInstall `
        -VenvPath $VenvPath `
        -PipConfig $PipConfig `
        -Wheelhouse $Wheelhouse `
        -NoIndex:$NoIndex
}

Write-Host ""
Write-Host "python-ldap build dependencies installed:"
Write-Host $InstallDir
Write-Host ""
Write-Host "For the current shell:"
if ($NoIndex) {
    Write-Host ". `"$InstallDir\Use-PythonLdapBuildDeps.ps1`" -NoIndex"
}
else {
    Write-Host ". `"$InstallDir\Use-PythonLdapBuildDeps.ps1`""
}
Write-Host "The helper sets PIP_FIND_LINKS and PIP_CONFIG_FILE for this shell."
Write-Host ""
if ($InstallPythonLdap) {
    Write-Host ""
    Write-Host "python-ldap==3.4.5 is installed in:"
    Write-Host $VenvPath
    Write-Host ""
    Write-Host "Continue with your requirements install; the venv pip.ini was not modified:"
    Write-Host "`"$VenvPath\Scripts\python.exe`" -m pip install -r .\requirements\base.txt"
}
else {
    Write-Host ""
    Write-Host "Then run, only for the python-ldap install shell:"
    Write-Host "python -m pip install python-ldap==3.4.5"
}
