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

## A2. Создать скрипты упаковки и установки

В repo должны лежать два скрипта:

```text
Build-VSBT2019-Payload.ps1
Install-VSBT2019-Offline.ps1
```

`Build-VSBT2019-Payload.ps1` собирает release payload и кладет в bundle актуальный `Install-VSBT2019-Offline.ps1` из той же директории.

`Install-VSBT2019-Offline.ps1` используется в закрытом контуре. Он:

```text
1. Работает от текущей директории запуска.
2. Создает .\vsbt2019-install\assets и .\vsbt2019-install\layout.
3. Сначала проверяет уже скачанные файлы в .\vsbt2019-bootstrap, рядом со скриптом, в .\assets и в .\vsbt2019-install\assets.
4. Скопирует SHA256-valid файлы в .\vsbt2019-install\assets.
5. Докачивает только отсутствующие или поврежденные файлы.
6. Если нужен proxy, просит URL в формате http://host:port только при фактической докачке.
7. Если proxy не задан, не использует proxy.
8. Использует готовый layout из .\vs2019-buildtools или распаковывает layout в .\vsbt2019-install\layout.
9. Устанавливает root certificates из layout\certificates в LocalMachine Root.
10. Создает response-файл с локальными ChannelManifest.json и Catalog.json.
11. Запускает vs_buildtools.exe из корня layout с --noWeb, response-файлом, нужными --add компонентами и проверкой установленного результата.
12. Показывает пассивный UI установщика, чтобы был виден процесс.
13. Сохраняет логи в .\vsbt2019-install\logs.
```

Скопируй оба скрипта из repo в `C:\offline` рядом друг с другом, если их там еще нет.

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

Открой PowerShell:

```powershell
New-Item -ItemType Directory -Force "C:\offline\vsbt2019-bootstrap" | Out-Null
cd "C:\offline"
```

Скачай `Install-VSBT2019-Offline.ps1` напрямую из публичного GitHub Release:

```powershell
$Repo = "eccodolf/infra-offline-bundle"
$Tag = "vsbt2019-v142-winsdk19041-2026-06"

$ScriptUrl = "https://github.com/$Repo/releases/download/$Tag/Install-VSBT2019-Offline.ps1"

Invoke-WebRequest `
  -UseBasicParsing `
  -Uri $ScriptUrl `
  -OutFile ".\vsbt2019-bootstrap\Install-VSBT2019-Offline.ps1"
```

Проверить, что файл скачался:

```powershell
Test-Path ".\vsbt2019-bootstrap\Install-VSBT2019-Offline.ps1"
```

Если для скачивания самого скрипта нужен proxy, добавь к `Invoke-WebRequest` параметр:

```powershell
-Proxy "http://host:port"
```

Если proxy не нужен, не указывай `-Proxy`.

## B1a. Скачать и сразу запустить из консоли

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

---

## B2. Запустить установку из закрытого контура без PAT

```powershell
powershell -ExecutionPolicy Bypass `
  -File ".\vsbt2019-bootstrap\Install-VSBT2019-Offline.ps1"
```

Стандартная локальная раскладка:

```text
C:\offline\vsbt2019-bootstrap      уже скачанные manifest/assets/части архива
C:\offline\vs2019-buildtools       уже распакованный Visual Studio Build Tools layout
C:\offline\vsbt2019-install        рабочая папка, которую создаст скрипт
C:\BuildTools\VS2019               целевая папка установки
```

Скрипт выполнит:

```text
1. Создаст .\vsbt2019-install\assets, .\vsbt2019-install\layout и C:\BuildTools\VS2019.
2. Сначала проверит уже скачанные файлы в .\vsbt2019-bootstrap, рядом со скриптом, в .\assets и в .\vsbt2019-install\assets.
3. Скопирует SHA256-valid файлы в .\vsbt2019-install\assets.
4. Докачает из GitHub Release только отсутствующие или поврежденные файлы.
5. Проверит SHA256 каждого файла.
6. Использует готовый layout из .\vs2019-buildtools или распакует split-архив через вложенный 7z.exe, если готового layout нет.
7. Установит root certificates из .\vs2019-buildtools\certificates в LocalMachine Root.
8. Создаст .\vsbt2019-install\Install-VSBT2019-Offline.response.json с локальными ChannelManifest.json и Catalog.json.
9. Запустит vs_buildtools.exe из корня layout с --noWeb, response-файлом, нужными --add компонентами и рабочей директорией layout.
10. Проверит, что после установки доступны VsDevCmd.bat, cl.exe, MSBuild.exe и Windows SDK 10.0.19041.0.
11. Покажет пассивный UI установщика, чтобы был виден процесс.
12. Сохранит логи в .\vsbt2019-install\logs.
13. Установит C++ Build Tools, MSVC v142 x86/x64 и Windows 10 SDK 19041.
```

Если для докачки с GitHub нужен proxy, передай его параметром:

```powershell
powershell -ExecutionPolicy Bypass `
  -File ".\vsbt2019-bootstrap\Install-VSBT2019-Offline.ps1" `
  -Proxy "http://host:port"
```

Если `-Proxy` не задан и скрипту реально нужно что-то докачать, он спросит proxy URL интерактивно. Если proxy не нужен, нажми Enter: тогда proxy использоваться не будет.

Если все assets уже скачаны и SHA256 совпадает, скрипт не обращается к GitHub и proxy не спрашивает.

Логи:

```text
.\vsbt2019-install\logs\Install-VSBT2019-Offline-*.log
.\vsbt2019-install\logs\dd_*.log
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
Test-Path ".\vsbt2019-install\layout\vs_buildtools.exe"
```

Должно быть:

```text
True
```

## D2. Проверить, что installer не ходит в интернет

В команде установки должен быть ключ:

```powershell
--noWeb
```

Он уже есть в скрипте. Скрипт запускает `vs_buildtools.exe` с рабочей директорией, равной корню layout, чтобы installer видел локальные `Response.json`, `Catalog.json` и `ChannelManifest.json`.

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
Get-Content ".\vsbt2019-install\assets\manifest.json" -Raw
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

