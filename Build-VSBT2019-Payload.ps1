param(
    [string]$LayoutPath = "C:\offline\vs2019-buildtools",
    [string]$BundlePath = "C:\offline\vs2019-buildtools-release",
    [string]$BundleName = "vsbt2019-v142-winsdk19041",
    [string]$SevenZipExe = "C:\Program Files\7-Zip\7z.exe"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $LayoutPath)) {
    throw "Layout path not found: $LayoutPath"
}

if (-not (Test-Path (Join-Path $LayoutPath "vs_buildtools.exe"))) {
    throw "vs_buildtools.exe not found in layout: $LayoutPath"
}

if (-not (Test-Path $SevenZipExe)) {
    throw "7-Zip not found: $SevenZipExe"
}

$SevenZipDir = Split-Path -Parent $SevenZipExe
$SevenZipDll = Join-Path $SevenZipDir "7z.dll"

if (-not (Test-Path $SevenZipDll)) {
    throw "7z.dll not found near 7z.exe: $SevenZipDll"
}

if (Test-Path $BundlePath) {
    Remove-Item -Recurse -Force $BundlePath
}

New-Item -ItemType Directory -Force $BundlePath | Out-Null

Write-Host "[1/4] Copying portable 7-Zip files..."
Copy-Item $SevenZipExe (Join-Path $BundlePath "7z.exe") -Force
Copy-Item $SevenZipDll (Join-Path $BundlePath "7z.dll") -Force

Write-Host "[2/4] Creating split archive with 100 MB chunks..."
$ArchivePrefix = Join-Path $BundlePath "$BundleName.7z"

& $SevenZipExe a `
    -t7z `
    -mx=5 `
    -mmt=on `
    -v100m `
    $ArchivePrefix `
    "$LayoutPath\*"

if ($LASTEXITCODE -ne 0) {
    throw "7-Zip archive creation failed with exit code $LASTEXITCODE"
}

Write-Host "[3/4] Copying installer script for closed contour..."

$InstallerScriptSource = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Install-VSBT2019-Offline.ps1"
if (-not (Test-Path $InstallerScriptSource)) {
    throw "Installer script template not found: $InstallerScriptSource"
}

$InstallerScriptPath = Join-Path $BundlePath "Install-VSBT2019-Offline.ps1"
Copy-Item -Path $InstallerScriptSource -Destination $InstallerScriptPath -Force

Write-Host "[4/4] Creating manifest..."

$Files = Get-ChildItem $BundlePath -File | ForEach-Object {
    [PSCustomObject]@{
        name = $_.Name
        size = $_.Length
        sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    }
}

$Manifest = [PSCustomObject]@{
    name = $BundleName
    chunk_size = "100 MB"
    created_at = (Get-Date).ToString("s")
    source_layout = $LayoutPath
    repo = "eccodolf/infra-offline-bundle"
    public_download = $true
    install_components = @(
        "Microsoft.VisualStudio.Workload.VCTools",
        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        "Microsoft.VisualStudio.Component.Windows10SDK.19041"
    )
    install_command = "powershell -ExecutionPolicy Bypass -File .\vsbt2019-bootstrap\Install-VSBT2019-Offline.ps1"
    files = $Files
}

$ManifestPath = Join-Path $BundlePath "manifest.json"
$Manifest | ConvertTo-Json -Depth 10 | Set-Content $ManifestPath -Encoding UTF8

Write-Host ""
Write-Host "Payload is ready:"
Write-Host $BundlePath
Write-Host ""
Write-Host "Files:"
Get-ChildItem $BundlePath -File | Select-Object FullName, Length

Write-Host ""
Write-Host "Archive parts count:"
(Get-ChildItem $BundlePath -File -Filter "*.7z.*").Count

