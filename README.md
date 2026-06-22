# VS Build Tools 2019 offline install

Инструкция для закрытого контура. Репозиторий публичный, поэтому PAT/token для скачивания не нужен.

## Что должно быть доступно

На сетевом шлюзе закрытого контура должны быть разрешены GitHub Release endpoints:

```text
https://github.com
https://objects.githubusercontent.com
https://release-assets.githubusercontent.com
```

На Windows-машине нужны:

```text
1. PowerShell.
2. Админские права для установки Visual Studio Build Tools.
```

## Скачать установочный скрипт

Открой PowerShell и выполни:

```powershell
New-Item -ItemType Directory -Force "C:\offline\vsbt2019-bootstrap" | Out-Null
cd "C:\offline\vsbt2019-bootstrap"

$Repo = "eccodolf/infra-offline-bundle"
$Tag = "vsbt2019-v142-winsdk19041-2026-06"

Invoke-WebRequest `
  -UseBasicParsing `
  -Uri "https://github.com/$Repo/releases/download/$Tag/Install-VSBT2019-Offline.ps1" `
  -OutFile ".\Install-VSBT2019-Offline.ps1"

Test-Path ".\Install-VSBT2019-Offline.ps1"
```

Последняя команда должна вернуть:

```text
True
```

## Запустить установку

Запусти PowerShell от администратора:

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

Скрипт скачает `manifest.json`, все release assets и части архива, проверит SHA256, распакует offline layout и запустит `vs_buildtools.exe` с `--noweb`.

Устанавливаются:

```text
Microsoft.VisualStudio.Workload.VCTools
Microsoft.VisualStudio.Component.VC.Tools.x86.x64
Microsoft.VisualStudio.Component.Windows10SDK.19041
```

## Проверить установку

Открой новый PowerShell от администратора:

```powershell
& "C:\BuildTools\VS2019\Common7\Tools\VsDevCmd.bat"

where cl
cl
where msbuild
msbuild -version
```

Если `cl` найден и показывает Microsoft C/C++ Compiler 19.2x, MSVC v142 установлен.

Если installer вернул код `3010`, установка завершилась успешно, но требуется перезагрузка.
