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

function Get-BuildToolsVerificationFailures {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallPath
    )

    $Failures = New-Object System.Collections.Generic.List[string]

    $VsDevCmd = Join-Path $InstallPath "Common7\Tools\VsDevCmd.bat"
    if (-not (Test-Path $VsDevCmd)) {
        $Failures.Add("VsDevCmd.bat not found: $VsDevCmd")
    }

    $MsvcRoot = Join-Path $InstallPath "VC\Tools\MSVC"
    $ClPath = $null
    if (Test-Path $MsvcRoot) {
        $ClPath = Get-ChildItem -Path $MsvcRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $Candidate = Join-Path $_.FullName "bin\Hostx64\x64\cl.exe"
                if (Test-Path $Candidate) {
                    $Candidate
                }
            } |
            Select-Object -First 1
    }

    if (-not $ClPath) {
        $Failures.Add("MSVC cl.exe not found under: $MsvcRoot")
    }

    $MsBuildCandidates = @(
        (Join-Path $InstallPath "MSBuild\Current\Bin\MSBuild.exe"),
        (Join-Path $InstallPath "MSBuild\Current\Bin\amd64\MSBuild.exe")
    )

    $MsBuildPath = $MsBuildCandidates |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1

    if (-not $MsBuildPath) {
        $Failures.Add("MSBuild.exe not found under: $(Join-Path $InstallPath 'MSBuild')")
    }

    $ProgramFilesX86 = ${env:ProgramFiles(x86)}
    if ([string]::IsNullOrWhiteSpace($ProgramFilesX86)) {
        $Failures.Add("ProgramFiles(x86) environment variable is not set; cannot verify Windows SDK 10.0.19041.0")
    }
    else {
        $WinSdkInclude = Join-Path $ProgramFilesX86 "Windows Kits\10\Include\10.0.19041.0"
        $WinSdkLib = Join-Path $ProgramFilesX86 "Windows Kits\10\Lib\10.0.19041.0"

        if (-not (Test-Path $WinSdkInclude)) {
            $Failures.Add("Windows SDK include path not found: $WinSdkInclude")
        }

        if (-not (Test-Path $WinSdkLib)) {
            $Failures.Add("Windows SDK lib path not found: $WinSdkLib")
        }
    }

    return $Failures
}

function Assert-CertificateNotDisallowed {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Thumbprint,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $NormalizedThumbprint = $Thumbprint.Replace(" ", "").ToUpperInvariant()
    $DisallowedStores = @(
        "Cert:\LocalMachine\Disallowed",
        "Cert:\CurrentUser\Disallowed"
    )

    foreach ($Store in $DisallowedStores) {
        $Blocked = Get-ChildItem $Store -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $NormalizedThumbprint } |
            Select-Object -First 1

        if ($Blocked) {
            throw "Certificate is present in Untrusted Certificates store ($Store): $Name [$NormalizedThumbprint]"
        }
    }
}

function Install-CertificateFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$StoreName,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $Certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Path)
    Assert-CertificateNotDisallowed -Thumbprint $Certificate.Thumbprint -Name $Name

    $StorePath = "Cert:\LocalMachine\$StoreName"
    Write-Host "Installing certificate into $($StorePath): $Name [$($Certificate.Thumbprint)]"
    Import-Certificate -FilePath $Path -CertStoreLocation $StorePath | Out-Null

    Assert-CertificateNotDisallowed -Thumbprint $Certificate.Thumbprint -Name $Name
}

function Install-EmbeddedIntermediateCertificates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkDir
    )

    $EmbeddedCertificates = @(
        [pscustomobject]@{
            Name = "Microsoft Windows Code Signing PCA 2024"
            FileName = "MicrosoftWindowsCodeSigningPCA2024.crt"
            StoreName = "CA"
            Thumbprint = "D30F05F637E605239C0070D1EA9860D434AC2A94"
            Base64 = @"
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
"@
        }
    )

    $CertificatesDir = Join-Path $WorkDir "certificates"
    New-Item -ItemType Directory -Force $CertificatesDir | Out-Null

    foreach ($EmbeddedCertificate in $EmbeddedCertificates) {
        $CertificatePath = Join-Path $CertificatesDir $EmbeddedCertificate.FileName
        [IO.File]::WriteAllBytes($CertificatePath, [Convert]::FromBase64String($EmbeddedCertificate.Base64.Trim()))

        $Certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath)
        if ($Certificate.Thumbprint -ne $EmbeddedCertificate.Thumbprint) {
            throw "Embedded certificate thumbprint mismatch for $($EmbeddedCertificate.Name). Expected $($EmbeddedCertificate.Thumbprint), got $($Certificate.Thumbprint)"
        }

        Install-CertificateFile `
            -Path $CertificatePath `
            -StoreName $EmbeddedCertificate.StoreName `
            -Name $EmbeddedCertificate.Name
    }
}

function Install-LayoutCertificates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LayoutDir
    )

    $CertificatesDir = Join-Path $LayoutDir "certificates"
    if (-not (Test-Path $CertificatesDir)) {
        Write-Host "No layout certificates directory found: $CertificatesDir"
        return
    }

    $CertificateNames = @(
        "manifestRootCertificate.cer",
        "manifestCounterSignRootCertificate.cer",
        "vs_installer_opc.RootCertificate.cer"
    )

    foreach ($CertificateName in $CertificateNames) {
        $CertificatePath = Join-Path $CertificatesDir $CertificateName
        if (-not (Test-Path $CertificatePath)) {
            Write-Host "Layout certificate not found: $CertificatePath"
            continue
        }

        Install-CertificateFile `
            -Path $CertificatePath `
            -StoreName "Root" `
            -Name $CertificateName
    }
}

function New-OfflineInstallResponseFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LayoutDir,

        [Parameter(Mandatory = $true)]
        [string]$InstallPath,

        [Parameter(Mandatory = $true)]
        [string]$WorkDir
    )

    $LayoutResponsePath = Join-Path $LayoutDir "Response.json"
    $LayoutResponse = $null
    if (Test-Path $LayoutResponsePath) {
        $LayoutResponse = Get-Content $LayoutResponsePath -Raw | ConvertFrom-Json
    }

    $Add = @()
    if ($LayoutResponse -and $LayoutResponse.add) {
        $Add = @($LayoutResponse.add)
    }

    if ($Add.Count -eq 0) {
        $Add = @(
            "Microsoft.VisualStudio.Workload.VCTools",
            "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
            "Microsoft.VisualStudio.Component.Windows10SDK.19041"
        )
    }

    $AddProductLang = @()
    if ($LayoutResponse -and $LayoutResponse.addProductLang) {
        $AddProductLang = @($LayoutResponse.addProductLang)
    }

    if ($AddProductLang.Count -eq 0) {
        $AddProductLang = @("en-US")
    }

    $ChannelId = "VisualStudio.16.Release"
    if ($LayoutResponse -and -not [string]::IsNullOrWhiteSpace($LayoutResponse.channelId)) {
        $ChannelId = $LayoutResponse.channelId
    }

    $ProductId = "Microsoft.VisualStudio.Product.BuildTools"
    if ($LayoutResponse -and -not [string]::IsNullOrWhiteSpace($LayoutResponse.productId)) {
        $ProductId = $LayoutResponse.productId
    }

    $ChannelManifestPath = Join-Path $LayoutDir "ChannelManifest.json"
    $CatalogPath = Join-Path $LayoutDir "Catalog.json"

    $Response = [ordered]@{
        installChannelUri = $ChannelManifestPath
        channelUri = $ChannelManifestPath
        installCatalogUri = $CatalogPath
        channelId = $ChannelId
        productId = $ProductId
        installPath = $InstallPath
        passive = $true
        norestart = $true
        includeRecommended = $true
        addProductLang = $AddProductLang
        add = $Add
    }

    $ResponsePath = Join-Path $WorkDir "Install-VSBT2019-Offline.response.json"
    $Response | ConvertTo-Json -Depth 10 | Set-Content -Path $ResponsePath -Encoding UTF8
    return $ResponsePath
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

    Install-LayoutCertificates -LayoutDir $LayoutDir
    Install-EmbeddedIntermediateCertificates -WorkDir $WorkDir

    $InstallResponsePath = New-OfflineInstallResponseFile `
        -LayoutDir $LayoutDir `
        -InstallPath $InstallPath `
        -WorkDir $WorkDir

    Write-Host "Offline install response: $InstallResponsePath"

    $ChannelManifestPath = Join-Path $LayoutDir "ChannelManifest.json"
    $CatalogPath = Join-Path $LayoutDir "Catalog.json"

    $InstallArgs = @(
        "--in",
        $InstallResponsePath,
        "--noWeb",
        "--wait",
        "--norestart",
        "--passive",
        "--channelId",
        "VisualStudio.16.Release",
        "--productId",
        "Microsoft.VisualStudio.Product.BuildTools",
        "--channelUri",
        $ChannelManifestPath,
        "--installChannelUri",
        $ChannelManifestPath,
        "--installCatalogUri",
        $CatalogPath,
        "--add",
        "Microsoft.VisualStudio.Workload.VCTools",
        "--add",
        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        "--add",
        "Microsoft.VisualStudio.Component.Windows10SDK.19041",
        "--includeRecommended",
        "--installPath",
        $InstallPath
    )

    Write-Host "Installer arguments: $($InstallArgs -join ' ')"
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

    Write-Host "VS Build Tools installer exit code: $ExitCode"

    if (($ExitCode -ne 0) -and ($ExitCode -ne 3010)) {
        throw "VS Build Tools installer failed with exit code $ExitCode. See logs: $LogsDir"
    }

    $VerificationFailures = Get-BuildToolsVerificationFailures -InstallPath $InstallPath
    if ($VerificationFailures.Count -gt 0) {
        $FailureText = ($VerificationFailures | ForEach-Object { " - $_" }) -join [Environment]::NewLine
        throw "VS Build Tools installer exited successfully, but required tools were not found:$([Environment]::NewLine)$FailureText$([Environment]::NewLine)See logs: $LogsDir"
    }

    Write-Host "Verified installed Build Tools components."
    if ($ExitCode -eq 3010) {
        Write-Host "VS Build Tools installed successfully. Reboot required."
    }
    else {
        Write-Host "VS Build Tools installed successfully."
    }

    Write-Host "Script log: $TranscriptPath"
}
finally {
    Stop-Transcript | Out-Null
}
