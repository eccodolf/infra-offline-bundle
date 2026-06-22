# Сценарий переноса VS Build Tools 2019 в закрытый контур через публичный GitHub Release

## 0. Исходные условия

Публичный репозиторий для доставки:

```text
https://github.com/eccodolf/infra-offline-bundle
```

Полное имя repo для команд:

```powershell
$Repo = "eccodolf/infra-offline-bundle"
```

На машине с интернетом уже есть готовый offline layout:

```powershell
C:\offline\vs2019-buildtools
```

Внутри этой папки должен быть файл:

```powershell
C:\offline\vs2019-buildtools\vs_buildtools.exe
```

Цель: упаковать этот layout, разбить архив на чанки по **100 MB**, загрузить их в публичный GitHub Release, а в закрытом контуре скачать без PAT/token, проверить SHA256, распаковать и установить без обращения к Microsoft CDN.

---

## 1. Важное изменение по сравнению с private repo

Так как repo публичный, в закрытом контуре **PAT не нужен**.

Скачивание будет идти через прямые публичные release URLs вида:

```text
https://github.com/eccodolf/infra-offline-bundle/releases/download/<TAG>/<ASSET_NAME>
```

То есть закрытому контуру нужны только разрешённые GitHub/release endpoints.

При этом на машине, где ты **публикуешь release assets**, авторизация всё равно нужна, потому что загрузка файлов в GitHub Release требует прав на repo. Проще всего использовать `gh auth login`.

---

## 2. Требования к доступам

Для машины с интернетом:

```text
1. Доступ к GitHub.
2. Установленный GitHub CLI: gh.
3. Установленный 7-Zip.
4. Готовый layout в C:\offline\vs2019-buildtools.
5. Права на запись в repo eccodolf/infra-offline-bundle.
```

Для закрытого контура:

```text
1. Доступ к GitHub/release assets:
   - github.com
   - objects.githubusercontent.com
   - release-assets.githubusercontent.com

2. PowerShell.
3. Админские права Windows для установки Build Tools.
```

`api.github.com` в закрытом контуре больше не обязателен: сценарий не использует GitHub REST API для скачивания.

Если прямые ссылки `github.com/.../releases/download/...` редиректятся на asset endpoints, то эти endpoints тоже должны быть разрешены на сетевом шлюзе.

---

## 3. Почему чанки по 100 MB

В этом сценарии split-архив создаётся частями по 100 MB:

```powershell
-v100m
```

Плюсы:

```text
1. Легче докачивать при сетевых сбоях.
2. Проще проходить через прокси/DLP/шлюзы с ограничением на размер файла.
3. Удобнее вручную проверять/перезаливать отдельные части.
```

Минус:

```text
Будет больше release assets.
```

Если итоговых частей окажется больше 1000, GitHub Release упрётся в лимит количества assets на один release. Тогда нужно увеличить размер чанка, например до `200m` или `500m`.

---

# Часть A. Машина с интернетом

## A1. Проверить, что layout на месте

Открой PowerShell:

```powershell
Test-Path "C:\offline\vs2019-buildtools\vs_buildtools.exe"
```

Должно вернуть:

```text
True
```

Если `False`, значит layout собран не в ту папку или скачивание Build Tools не завершилось.

---

## A2. Создать скрипт упаковки

Выполни:

```powershell
$ScriptPath = "C:\offline\Build-VSBT2019-Payload.ps1"

@'
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

Write-Host "[3/4] Creating installer script for closed contour..."

$InstallerScript = @'
param(
    [string]$Repo = "eccodolf/infra-offline-bundle",

    [string]$Tag = "vsbt2019-v142-winsdk19041-2026-06",

    [string]$WorkDir = "C:\offline\vsbt2019-install",

    [string]$InstallPath = "C:\BuildTools\VS2019"
)

$ErrorActionPreference = "Stop"

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

function Download-File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$OutFile
    )

    Write-Host "Downloading: $Url"
    Invoke-WebRequest `
        -UseBasicParsing `
        -Uri $Url `
        -OutFile $OutFile
}

$AssetsDir = Join-Path $WorkDir "assets"
$LayoutDir = Join-Path $WorkDir "layout"

New-Item -ItemType Directory -Force $AssetsDir | Out-Null
New-Item -ItemType Directory -Force $LayoutDir | Out-Null

Write-Host "[1/6] Downloading manifest.json from public GitHub Release..."

$ManifestPath = Join-Path $AssetsDir "manifest.json"
$ManifestUrl = Get-GitHubReleaseAssetUrl -Repo $Repo -Tag $Tag -AssetName "manifest.json"

Download-File -Url $ManifestUrl -OutFile $ManifestPath

Write-Host "[2/6] Reading manifest..."

$Manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

if (-not $Manifest.files -or $Manifest.files.Count -eq 0) {
    throw "Manifest has no files."
}

Write-Host "[3/6] Downloading release assets..."

foreach ($File in $Manifest.files) {
    $OutFile = Join-Path $AssetsDir $File.name
    $NeedDownload = $true

    if (Test-Path $OutFile) {
        $Actual = (Get-FileHash $OutFile -Algorithm SHA256).Hash.ToUpperInvariant()
        $Expected = $File.sha256.ToUpperInvariant()

        if ($Actual -eq $Expected) {
            Write-Host "Already exists and SHA256 OK: $($File.name)"
            $NeedDownload = $false
        }
        else {
            Write-Host "Existing file has wrong SHA256, re-downloading: $($File.name)"
            Remove-Item -Force $OutFile
        }
    }

    if ($NeedDownload) {
        $Url = Get-GitHubReleaseAssetUrl -Repo $Repo -Tag $Tag -AssetName $File.name
        Download-File -Url $Url -OutFile $OutFile
    }
}

Write-Host "[4/6] Verifying SHA256..."

foreach ($File in $Manifest.files) {
    $Path = Join-Path $AssetsDir $File.name

    if (-not (Test-Path $Path)) {
        throw "Missing file: $($File.name)"
    }

    $Actual = (Get-FileHash $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    $Expected = $File.sha256.ToUpperInvariant()

    if ($Actual -ne $Expected) {
        throw "SHA256 mismatch for $($File.name). Expected $Expected, got $Actual"
    }

    Write-Host "OK: $($File.name)"
}

Write-Host "[5/6] Extracting offline layout..."

$SevenZip = Join-Path $AssetsDir "7z.exe"

if (-not (Test-Path $SevenZip)) {
    throw "7z.exe not found: $SevenZip"
}

$FirstPart = Get-ChildItem $AssetsDir -Filter "*.7z.001" | Select-Object -First 1

if (-not $FirstPart) {
    throw "Archive first part *.7z.001 not found."
}

& $SevenZip x $FirstPart.FullName "-o$LayoutDir" -y

if ($LASTEXITCODE -ne 0) {
    throw "7-Zip extraction failed with exit code $LASTEXITCODE"
}

$Installer = Join-Path $LayoutDir "vs_buildtools.exe"

if (-not (Test-Path $Installer)) {
    throw "vs_buildtools.exe not found after extraction: $Installer"
}

Write-Host "[6/6] Installing Visual Studio Build Tools 2019 offline..."

& $Installer `
    --noweb `
    --wait `
    --norestart `
    --passive `
    --installPath $InstallPath `
    --add Microsoft.VisualStudio.Workload.VCTools `
    --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    --add Microsoft.VisualStudio.Component.Windows10SDK.19041 `
    --includeRecommended

$ExitCode = $LASTEXITCODE

if ($ExitCode -eq 0) {
    Write-Host "VS Build Tools installed successfully."
}
elseif ($ExitCode -eq 3010) {
    Write-Host "VS Build Tools installed successfully. Reboot required."
}
else {
    throw "VS Build Tools installer failed with exit code $ExitCode"
}
'@

$InstallerScriptPath = Join-Path $BundlePath "Install-VSBT2019-Offline.ps1"
$InstallerScript | Set-Content $InstallerScriptPath -Encoding UTF8

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
    install_command = "vs_buildtools.exe --noweb --wait --norestart --passive --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows10SDK.19041 --includeRecommended"
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
'@ | Set-Content $ScriptPath -Encoding UTF8
```

---

## A3. Запустить упаковку

```powershell
powershell -ExecutionPolicy Bypass -File "C:\offline\Build-VSBT2019-Payload.ps1"
```

После выполнения должна появиться папка:

```powershell
C:\offline\vs2019-buildtools-release
```

В ней будут:

```text
manifest.json
Install-VSBT2019-Offline.ps1
7z.exe
7z.dll
vsbt2019-v142-winsdk19041.7z.001
vsbt2019-v142-winsdk19041.7z.002
vsbt2019-v142-winsdk19041.7z.003
...
```

Каждая часть архива будет примерно по **100 MB**.

Проверить количество частей:

```powershell
(Get-ChildItem "C:\offline\vs2019-buildtools-release" -Filter "*.7z.*").Count
```

Если частей больше 1000, нужно увеличить размер чанка в скрипте упаковки:

```powershell
-v100m
```

например на:

```powershell
-v200m
```

или:

```powershell
-v500m
```

---

## A4. Авторизоваться в GitHub CLI

На машине с интернетом:

```powershell
gh auth login
```

Проверить:

```powershell
gh auth status
```

Это нужно только для публикации release assets. В закрытом контуре PAT/token не нужен.

---

## A5. Создать GitHub Release

```powershell
$Repo = "eccodolf/infra-offline-bundle"
$Tag = "vsbt2019-v142-winsdk19041-2026-06"

gh release create $Tag `
  --repo $Repo `
  --title "VS Build Tools 2019 v142 WinSDK 19041 offline bundle" `
  --notes "Offline bundle for closed contour installation. Archive split into 100 MB chunks. Public download, no PAT required."
```

Если release уже существует, этот шаг пропусти.

---

## A6. Загрузить assets в GitHub Release

```powershell
$Repo = "eccodolf/infra-offline-bundle"
$Tag = "vsbt2019-v142-winsdk19041-2026-06"
$BundlePath = "C:\offline\vs2019-buildtools-release"

gh release upload $Tag `
  --repo $Repo `
  --clobber `
  "$BundlePath\manifest.json" `
  "$BundlePath\Install-VSBT2019-Offline.ps1" `
  "$BundlePath\7z.exe" `
  "$BundlePath\7z.dll" `
  "$BundlePath\*.7z.*"
```

Проверить список assets:

```powershell
gh release view $Tag --repo $Repo
```

Проверить количество assets:

```powershell
gh release view $Tag --repo $Repo --json assets --jq ".assets | length"
```

---

# Часть B. Закрытый контур

## B1. Скачать установочный скрипт без PAT

Создай временную папку:

```powershell
New-Item -ItemType Directory -Force "C:\offline\vsbt2019-bootstrap" | Out-Null
cd "C:\offline\vsbt2019-bootstrap"
```

Скачай `Install-VSBT2019-Offline.ps1` напрямую из публичного GitHub Release:

```powershell
$Repo = "eccodolf/infra-offline-bundle"
$Tag = "vsbt2019-v142-winsdk19041-2026-06"

$ScriptUrl = "https://github.com/$Repo/releases/download/$Tag/Install-VSBT2019-Offline.ps1"

Invoke-WebRequest `
  -UseBasicParsing `
  -Uri $ScriptUrl `
  -OutFile ".\Install-VSBT2019-Offline.ps1"
```

Проверить, что файл скачался:

```powershell
Test-Path ".\Install-VSBT2019-Offline.ps1"
```

---

## B2. Запустить установку из закрытого контура без PAT

```powershell
$Repo = "eccodolf/infra-offline-bundle"
$Tag = "vsbt2019-v142-winsdk19041-2026-06"

powershell -ExecutionPolicy Bypass `
  -File ".\Install-VSBT2019-Offline.ps1" `
  -Repo $Repo `
  -Tag $Tag `
  -WorkDir "C:\offline\vsbt2019-install" `
  -InstallPath "C:\BuildTools\VS2019"
```

Скрипт выполнит:

```text
1. Скачает manifest.json из публичного GitHub Release.
2. По manifest.json скачает все assets, включая чанки по 100 MB.
3. Проверит SHA256 каждого файла.
4. Распакует split-архив через вложенный 7z.exe.
5. Запустит vs_buildtools.exe с --noweb.
6. Установит C++ Build Tools, MSVC v142 x86/x64 и Windows 10 SDK 19041.
```

---

## B3. Проверить установку

Открой новый PowerShell от администратора:

```powershell
& "C:\BuildTools\VS2019\Common7\Tools\VsDevCmd.bat"
```

Потом:

```powershell
where cl
cl
where msbuild
msbuild -version
```

Если `cl` найден и показывает версию Microsoft C/C++ Compiler 19.2x, MSVC v142 установлен.

---

# Часть C. Дальше для проекта rescalc

После установки Build Tools возвращайся к проекту:

```powershell
cd C:\PyCharmProjects\rescalc

.\venv\Scripts\Activate.ps1

python -VV
python -m pip install -U pip setuptools wheel
python -m pip install -r .\requirements\base.txt
```

Потом:

```powershell
python manage.py check
powershell -File .\scripts\local-dev.ps1
```

---

# Часть D. Если установка Build Tools падает

## D1. Проверить, что layout распаковался

```powershell
Test-Path "C:\offline\vsbt2019-install\layout\vs_buildtools.exe"
```

Должно быть:

```text
True
```

## D2. Проверить, что installer не ходит в интернет

В команде установки должен быть ключ:

```powershell
--noweb
```

Он уже есть в скрипте.

## D3. Если ошибка “package not found”

Это значит, что в исходном layout не было нужного компонента.

Тогда на машине с интернетом нужно пересобрать layout с нужными компонентами и заново выполнить части A3–A6.

Базовый layout для текущего сценария должен быть собран с компонентами:

```powershell
--add Microsoft.VisualStudio.Workload.VCTools
--add Microsoft.VisualStudio.Component.VC.Tools.x86.x64
--add Microsoft.VisualStudio.Component.Windows10SDK.19041
--includeRecommended
```

## D4. Если GitHub download не работает

Проверь, что из закрытого контура доступны:

```text
https://github.com
https://objects.githubusercontent.com
https://release-assets.githubusercontent.com
```

Проверка:

```powershell
Invoke-WebRequest -UseBasicParsing https://github.com -TimeoutSec 10
```

Проверка прямой ссылки на release asset после публикации:

```powershell
$Repo = "eccodolf/infra-offline-bundle"
$Tag = "vsbt2019-v142-winsdk19041-2026-06"

Invoke-WebRequest `
  -UseBasicParsing `
  -Uri "https://github.com/$Repo/releases/download/$Tag/manifest.json" `
  -TimeoutSec 30 `
  -OutFile "$env:TEMP\manifest.json"
```

## D5. Если скрипт скачал manifest.json, но не качает чанки

Проверь, что asset имена в release совпадают с именами из manifest:

```powershell
Get-Content "C:\offline\vsbt2019-install\assets\manifest.json" -Raw
```

В release должны быть assets:

```text
7z.exe
7z.dll
Install-VSBT2019-Offline.ps1
vsbt2019-v142-winsdk19041.7z.001
vsbt2019-v142-winsdk19041.7z.002
...
```

---

# Резюме команд

На машине с интернетом:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\offline\Build-VSBT2019-Payload.ps1"

$Repo = "eccodolf/infra-offline-bundle"
$Tag = "vsbt2019-v142-winsdk19041-2026-06"
$BundlePath = "C:\offline\vs2019-buildtools-release"

gh auth login

gh release create $Tag `
  --repo $Repo `
  --title "VS Build Tools 2019 v142 WinSDK 19041 offline bundle" `
  --notes "Offline bundle for closed contour installation. Archive split into 100 MB chunks. Public download, no PAT required."

gh release upload $Tag `
  --repo $Repo `
  --clobber `
  "$BundlePath\manifest.json" `
  "$BundlePath\Install-VSBT2019-Offline.ps1" `
  "$BundlePath\7z.exe" `
  "$BundlePath\7z.dll" `
  "$BundlePath\*.7z.*"
```

В закрытом контуре:

```powershell
New-Item -ItemType Directory -Force "C:\offline\vsbt2019-bootstrap" | Out-Null
cd "C:\offline\vsbt2019-bootstrap"

$Repo = "eccodolf/infra-offline-bundle"
$Tag = "vsbt2019-v142-winsdk19041-2026-06"

Invoke-WebRequest `
  -UseBasicParsing `
  -Uri "https://github.com/$Repo/releases/download/$Tag/Install-VSBT2019-Offline.ps1" `
  -OutFile ".\Install-VSBT2019-Offline.ps1"

powershell -ExecutionPolicy Bypass `
  -File ".\Install-VSBT2019-Offline.ps1" `
  -Repo $Repo `
  -Tag $Tag `
  -WorkDir "C:\offline\vsbt2019-install" `
  -InstallPath "C:\BuildTools\VS2019"
```
