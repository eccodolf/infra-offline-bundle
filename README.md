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
cd "C:\offline"

$Repo = "eccodolf/infra-offline-bundle"
$Tag = "vsbt2019-v142-winsdk19041-2026-06"

New-Item -ItemType Directory -Force ".\vsbt2019-bootstrap" | Out-Null

Invoke-WebRequest `
  -UseBasicParsing `
  -Uri "https://github.com/$Repo/releases/download/$Tag/Install-VSBT2019-Offline.ps1" `
  -OutFile ".\vsbt2019-bootstrap\Install-VSBT2019-Offline.ps1"

Test-Path ".\vsbt2019-bootstrap\Install-VSBT2019-Offline.ps1"
```

Последняя команда должна вернуть:

```text
True
```

Если для скачивания самого скрипта нужен proxy, добавь `-Proxy "http://host:port"` к `Invoke-WebRequest`. Если proxy не нужен, параметр `-Proxy` не указывай.

## Скачать и сразу запустить

Открой PowerShell от администратора:

```powershell
cd "C:\offline"

$Repo = "eccodolf/infra-offline-bundle"
$Tag = "vsbt2019-v142-winsdk19041-2026-06"

New-Item -ItemType Directory -Force ".\vsbt2019-bootstrap" | Out-Null

Invoke-WebRequest `
  -UseBasicParsing `
  -Uri "https://github.com/$Repo/releases/download/$Tag/Install-VSBT2019-Offline.ps1" `
  -OutFile ".\vsbt2019-bootstrap\Install-VSBT2019-Offline.ps1"

powershell -ExecutionPolicy Bypass `
  -File ".\vsbt2019-bootstrap\Install-VSBT2019-Offline.ps1"
```

Если для GitHub нужен proxy, добавь `-Proxy "http://host:port"` в `Invoke-WebRequest`. Сам установочный скрипт также спросит proxy только если ему нужно докачивать отсутствующие файлы. Если proxy не задан, proxy не используется.

## Запустить установку

Запусти PowerShell от администратора:

```powershell
cd "C:\offline"

powershell -ExecutionPolicy Bypass `
  -File ".\vsbt2019-bootstrap\Install-VSBT2019-Offline.ps1"
```

Скрипт работает от текущей директории. Для стандартной раскладки:

```text
C:\offline\vsbt2019-bootstrap      уже скачанные manifest/assets/части архива
C:\offline\vs2019-buildtools       уже распакованный Visual Studio Build Tools layout
C:\offline\vsbt2019-install        рабочая папка, которую создаст скрипт
C:\BuildTools\VS2019               целевая папка установки
```

Если `C:\offline\vs2019-buildtools` уже содержит полный layout, скрипт не будет распаковывать архив заново.

Порядок работы:

```text
1. Проверит уже скачанные файлы в .\vsbt2019-bootstrap, рядом со скриптом, в .\assets и в .\vsbt2019-install\assets.
2. Скопирует найденные SHA256-valid файлы в .\vsbt2019-install\assets.
3. Докачает только отсутствующие или поврежденные файлы.
4. Использует готовый layout из .\vs2019-buildtools или распакует layout в .\vsbt2019-install\layout, если готового layout нет.
5. Установит root certificates из .\vs2019-buildtools\certificates в LocalMachine Root.
6. Установит встроенный Microsoft Windows Code Signing PCA 2024 в LocalMachine Intermediate Certification Authorities.
7. Создаст .\vsbt2019-install\Install-VSBT2019-Offline.response.json с локальными ChannelManifest.json и Catalog.json.
8. Запустит vs_buildtools.exe из корня layout с --noWeb, response-файлом, нужными --add компонентами и рабочей директорией layout.
9. Покажет пассивный UI установщика, чтобы был виден процесс.
10. Сохранит логи в .\vsbt2019-install\logs.
11. Проверит, что после установки доступны VsDevCmd.bat, cl.exe, MSBuild.exe и Windows SDK 10.0.19041.0.
```

Если для скачивания с GitHub нужен proxy, скрипт спросит его при первой докачке. Введи URL в формате `http://host:port`. Если proxy не нужен, просто нажми Enter, тогда proxy использоваться не будет.

Если все assets уже скачаны и валидны, скрипт не будет обращаться к GitHub и не спросит proxy.

Логи:

```text
.\vsbt2019-install\logs\Install-VSBT2019-Offline-*.log
.\vsbt2019-install\logs\dd_*.log
```

В логе скрипта также сохраняются аргументы запуска Visual Studio Installer и путь к сгенерированному response-файлу.

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

Если установщик завершился с кодом `0`, но нужные инструменты не появились, скрипт завершится ошибкой и покажет, какой именно файл или SDK путь не найден.
