param(
    [string]$Repo = "eccodolf/infra-offline-bundle",

    [string]$ReleaseTag = "python-ldap-3.4.5-builddeps-2026-06",

    [string]$WorkDir = "C:\offline\python-ldap-builddeps-work",

    [string]$BundlePath = "C:\offline\python-ldap-builddeps-release",

    [string]$PackageDirName = "python-ldap-builddeps",

    [string]$VSInstallPath = "C:\BuildTools\VS2019",

    [string]$PythonExe = "py",

    [string[]]$PythonArgs = @("-3.14"),

    [string]$PerlExe = "",

    [string]$OpenLdapPlatformToolset = "v142",

    [string]$Proxy = "",

    [switch]$SkipNativeBuild
)

$ErrorActionPreference = "Stop"

$GohlkeCommit = "fab7165a2e543e7aebee5d38ef6df538e2ae8ee1"
$OpenSslVersion = "openssl-3.0.18"
$OpenLdapVersion = "openldap-2.4.59"
$PythonLdapVersion = "3.4.5"
$PythonLdapTag = "python-ldap-$PythonLdapVersion"

function Get-FullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path)
}

function New-CleanDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $FullPath = Get-FullPath $Path
    if ($FullPath.Length -lt 10) {
        throw "Refusing to clean suspiciously short path: $FullPath"
    }

    if (Test-Path $FullPath) {
        Remove-Item -LiteralPath $FullPath -Recurse -Force
    }

    New-Item -ItemType Directory -Force $FullPath | Out-Null
    return $FullPath
}

function Download-File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$OutFile
    )

    if (Test-Path $OutFile) {
        Write-Host "Using existing download: $OutFile"
        return
    }

    Write-Host "Downloading: $Uri"
    $Request = @{
        UseBasicParsing = $true
        Uri = $Uri
        OutFile = $OutFile
    }

    if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
        $Request.Proxy = $Proxy
    }

    Invoke-WebRequest @Request
}

function Resolve-ToolPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string[]]$Fallbacks = @()
    )

    if (-not [string]::IsNullOrWhiteSpace($Name) -and (Test-Path $Name)) {
        return (Resolve-Path $Name).Path
    }

    $Command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($Command) {
        return $Command.Source
    }

    foreach ($Fallback in $Fallbacks) {
        if (Test-Path $Fallback) {
            return (Resolve-Path $Fallback).Path
        }
    }

    return $null
}

function Test-PerlForOpenSsl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $false
    }

    & $Path -MLocale::Maketext::Simple -e "print qq(ok\n)" | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Resolve-PerlForOpenSsl {
    param(
        [string]$RequestedPath
    )

    $Candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $Candidates += $RequestedPath
    }

    $Candidates += @(
        "C:\Strawberry\perl\bin\perl.exe",
        "C:\msys64\usr\bin\perl.exe",
        "perl.exe",
        "C:\Program Files\Git\usr\bin\perl.exe"
    )

    foreach ($Candidate in $Candidates) {
        $Resolved = Resolve-ToolPath -Name $Candidate
        if ($Resolved -and (Test-PerlForOpenSsl -Path $Resolved)) {
            return $Resolved
        }
    }

    return $null
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $true)]
        [string]$ErrorMessage
    )

    & $ScriptBlock
    if ($LASTEXITCODE -ne 0) {
        throw "$ErrorMessage Exit code: $LASTEXITCODE"
    }
}

function Invoke-Python {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & $PythonExe @PythonArgs @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Python command failed: $PythonExe $($PythonArgs -join ' ') $($Arguments -join ' ')"
    }
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Write-TextFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Content
    )

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Set-PythonLdapSetupCfgForWindows {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "setup.cfg not found: $Path"
    }

    $Settings = @(
        "library_dirs = builddeps_lib",
        "include_dirs = builddeps_include",
        "defines = HAVE_TLS HAVE_LIBLDAP_R",
        "libs = olber32_a oldap32 oldap_r libssl libcrypto ws2_32 gdi32 advapi32 crypt32 user32"
    )

    $Lines = Get-Content -Path $Path
    $Output = New-Object System.Collections.Generic.List[string]
    $InLdapSection = $false
    $Inserted = $false
    $SectionFound = $false

    foreach ($Line in $Lines) {
        if ($Line -match '^\s*\[.+\]\s*$') {
            if ($InLdapSection -and -not $Inserted) {
                foreach ($Setting in $Settings) {
                    $Output.Add($Setting)
                }
                $Inserted = $true
            }

            $InLdapSection = ($Line.Trim() -eq "[_ldap]")
            if ($InLdapSection) {
                $SectionFound = $true
            }

            $Output.Add($Line)

            if ($InLdapSection) {
                foreach ($Setting in $Settings) {
                    $Output.Add($Setting)
                }
                $Inserted = $true
            }

            continue
        }

        if ($InLdapSection -and ($Line -match '^\s*(library_dirs|include_dirs|defines|libs)\s*=')) {
            continue
        }

        $Output.Add($Line)
    }

    if ($InLdapSection -and -not $Inserted) {
        foreach ($Setting in $Settings) {
            $Output.Add($Setting)
        }
        $Inserted = $true
    }

    if (-not $SectionFound) {
        throw "setup.cfg does not contain an [_ldap] section: $Path"
    }

    Write-TextFile -Path $Path -Content (($Output.ToArray()) -join [Environment]::NewLine)
}

function Set-OpenLdapPlatformToolset {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDir,

        [Parameter(Mandatory = $true)]
        [string]$PlatformToolset
    )

    $ProjectDir = Join-Path $SourceDir "win32\vc17"
    $Projects = Get-ChildItem -Path $ProjectDir -File -Filter "*.vcxproj"
    if (-not $Projects) {
        throw "OpenLDAP Visual Studio project files not found: $ProjectDir"
    }

    foreach ($Project in $Projects) {
        [xml]$Xml = Get-Content -Path $Project.FullName -Raw
        $Nodes = $Xml.SelectNodes("//*[local-name()='PlatformToolset']")
        if ($Nodes.Count -eq 0) {
            throw "No PlatformToolset nodes found in: $($Project.FullName)"
        }

        foreach ($Node in $Nodes) {
            $Node.InnerText = $PlatformToolset
        }

        $Xml.Save($Project.FullName)
    }
}

$WorkDir = Get-FullPath $WorkDir
$BundlePath = Get-FullPath $BundlePath
$PackageRoot = Join-Path $WorkDir $PackageDirName
$DownloadsDir = Join-Path $WorkDir "downloads"
$RecipeDir = Join-Path $WorkDir "gohlke-recipe"
$SourcesDir = Join-Path $WorkDir "sources"
$ExtractDir = Join-Path $WorkDir "extract"
$PatchedSourceDir = Join-Path $WorkDir "python-ldap-patched"

$VsDevCmd = Join-Path $VSInstallPath "Common7\Tools\VsDevCmd.bat"
if (-not (Test-Path $VsDevCmd)) {
    throw "VsDevCmd.bat not found. Install VS Build Tools first: $VsDevCmd"
}

$GitExe = Resolve-ToolPath -Name "git"
if (-not $GitExe) {
    throw "git.exe is required to apply pinned recipe patches."
}

$PerlExe = Resolve-PerlForOpenSsl -RequestedPath $PerlExe

if (-not $PerlExe) {
    throw "perl.exe with Locale::Maketext::Simple is required to build OpenSSL. Install Strawberry/MSYS Perl or pass -PerlExe."
}

New-Item -ItemType Directory -Force $DownloadsDir, $RecipeDir, $SourcesDir | Out-Null
New-CleanDirectory $ExtractDir | Out-Null
New-CleanDirectory $PackageRoot | Out-Null
New-CleanDirectory $BundlePath | Out-Null

New-Item -ItemType Directory -Force `
    (Join-Path $PackageRoot "include"), `
    (Join-Path $PackageRoot "lib"), `
    (Join-Path $PackageRoot "wheelhouse"), `
    (Join-Path $PackageRoot "metadata") | Out-Null

Write-Host "[1/7] Downloading pinned Gohlke recipe files..."
foreach ($RecipeFile in @("openssl.diff", "openldap.diff", "python-ldap.diff")) {
    $Url = "https://raw.githubusercontent.com/cgohlke/python-ldap-build/$GohlkeCommit/$RecipeFile"
    Download-File -Uri $Url -OutFile (Join-Path $RecipeDir $RecipeFile)
}

Write-Host "[2/7] Downloading source archives from non-GitHub upstreams..."
$OpenSslArchive = Join-Path $DownloadsDir "$OpenSslVersion.tar.gz"
$OpenLdapArchive = Join-Path $DownloadsDir "$OpenLdapVersion.tgz"
Download-File -Uri "https://www.openssl.org/source/$OpenSslVersion.tar.gz" -OutFile $OpenSslArchive
Download-File -Uri "https://www.openldap.org/software/download/OpenLDAP/openldap-release/$OpenLdapVersion.tgz" -OutFile $OpenLdapArchive

Write-Host "[3/7] Extracting and patching native sources..."
$OpenSslSource = Join-Path $ExtractDir $OpenSslVersion
$OpenLdapSource = Join-Path $ExtractDir $OpenLdapVersion
Invoke-Checked -ErrorMessage "Extracting OpenSSL failed." -ScriptBlock { tar -xf $OpenSslArchive -C $ExtractDir }
Invoke-Checked -ErrorMessage "Extracting OpenLDAP failed." -ScriptBlock { tar -xf $OpenLdapArchive -C $ExtractDir }
Push-Location $ExtractDir
try {
    Invoke-Checked -ErrorMessage "Applying OpenSSL patch failed." -ScriptBlock { & $GitExe apply -p1 --verbose "--directory=$OpenSslVersion" (Join-Path $RecipeDir "openssl.diff") }
    Invoke-Checked -ErrorMessage "Applying OpenLDAP patch failed." -ScriptBlock { & $GitExe apply -p1 --verbose "--directory=$OpenLdapVersion" (Join-Path $RecipeDir "openldap.diff") }
}
finally {
    Pop-Location
}

Set-OpenLdapPlatformToolset -SourceDir $OpenLdapSource -PlatformToolset $OpenLdapPlatformToolset

if (-not $SkipNativeBuild) {
    Write-Host "[4/7] Building OpenSSL and OpenLDAP SDK with VS Build Tools..."
    $BuildCmd = Join-Path $WorkDir "build-native-deps.cmd"
    $CmdContent = @(
        "@echo on",
        "setlocal",
        "set MSBUILDTREATHIGHERTOOLSVERSIONASCURRENT=1",
        "set PACKAGE_ROOT=$PackageRoot",
        "set OPENSSL_SRC=$OpenSslSource",
        "set OPENLDAP_SRC=$OpenLdapSource",
        "set OPENSSL_CONFIG=VC-WIN64A-masm",
        "set VS_PLATFORM=x64",
        "set PATH=$(Split-Path -Parent $PerlExe);%PATH%",
        "",
        'cd /d "%OPENSSL_SRC%"',
        "if errorlevel 1 exit /B 1",
        "`"$PerlExe`" Configure %OPENSSL_CONFIG% no-shared no-makedepend no-zlib --prefix=`"%PACKAGE_ROOT%`" --openssldir=openssl",
        "if errorlevel 1 exit /B 1",
        "`"$PerlExe`" configdata.pm --dump",
        "if errorlevel 1 exit /B 1",
        "nmake /nologo build_all_generated",
        "if errorlevel 1 exit /B 1",
        "nmake /nologo PERL=no-perl",
        "if errorlevel 1 exit /B 1",
        "nmake /nologo install_sw",
        "if errorlevel 1 exit /B 1",
        "nmake /nologo install_ssldirs",
        "if errorlevel 1 exit /B 1",
        "",
        'cd /d "%OPENLDAP_SRC%"',
        "if errorlevel 1 exit /B 1",
        'xcopy include "%PACKAGE_ROOT%\include\" /E /H /C /R /Q /Y',
        "if errorlevel 1 exit /B 1",
        'set INCLUDE=%INCLUDE%;%PACKAGE_ROOT%\include',
        'set LIB=%LIB%;%PACKAGE_ROOT%\lib',
        "msbuild win32\vc17\liblber.sln /m /t:Clean;Rebuild /p:UseEnv=true /p:Configuration=Release /p:Platform=%VS_PLATFORM%",
        "if errorlevel 1 exit /B 1",
        'copy /Y /B Release\*.lib "%PACKAGE_ROOT%\lib"',
        "if errorlevel 1 exit /B 1",
        "",
        "endlocal"
    ) -join [Environment]::NewLine
    Write-TextFile -Path $BuildCmd -Content $CmdContent

    & cmd.exe /d /c "`"$VsDevCmd`" -arch=amd64 && `"$BuildCmd`""
    if ($LASTEXITCODE -ne 0) {
        throw "Native SDK build failed. Exit code: $LASTEXITCODE"
    }
}
else {
    Write-Host "[4/7] Skipping native build by request."
}

Write-Host "[5/7] Preparing patched python-ldap source distribution and pip wheelhouse..."
$Wheelhouse = Join-Path $PackageRoot "wheelhouse"
$PythonLdapDownloadDir = Join-Path $SourcesDir "python-ldap"
New-CleanDirectory $PythonLdapDownloadDir | Out-Null

Invoke-Python -Arguments @(
    "-m", "pip", "download",
    "--no-binary=:all:",
    "--no-deps",
    "--dest", $PythonLdapDownloadDir,
    "python-ldap==$PythonLdapVersion"
)

$PythonLdapSourceArchive = Get-ChildItem $PythonLdapDownloadDir -File -Filter "python_ldap-$PythonLdapVersion.tar.gz" |
    Select-Object -First 1
if (-not $PythonLdapSourceArchive) {
    throw "python-ldap sdist was not downloaded."
}

New-CleanDirectory $PatchedSourceDir | Out-Null
Invoke-Checked -ErrorMessage "Extracting python-ldap sdist failed." -ScriptBlock { tar -xf $PythonLdapSourceArchive.FullName -C $PatchedSourceDir }
$ExtractedPythonLdap = Get-ChildItem $PatchedSourceDir -Directory | Select-Object -First 1
if (-not $ExtractedPythonLdap) {
    throw "Extracted python-ldap source directory not found."
}

Copy-Item -Path (Join-Path $PackageRoot "include") -Destination (Join-Path $ExtractedPythonLdap.FullName "builddeps_include") -Recurse -Force
Copy-Item -Path (Join-Path $PackageRoot "lib") -Destination (Join-Path $ExtractedPythonLdap.FullName "builddeps_lib") -Recurse -Force
Set-PythonLdapSetupCfgForWindows -Path (Join-Path $ExtractedPythonLdap.FullName "setup.cfg")

$PatchedArchive = Join-Path $Wheelhouse "python_ldap-$PythonLdapVersion.tar.gz"
Push-Location $PatchedSourceDir
try {
    Invoke-Checked -ErrorMessage "Creating patched python-ldap sdist failed." -ScriptBlock { tar -czf $PatchedArchive $ExtractedPythonLdap.Name }
}
finally {
    Pop-Location
}

Invoke-Python -Arguments @(
    "-m", "pip", "download",
    "--only-binary=:all:",
    "--dest", $Wheelhouse,
    "setuptools",
    "setuptools-scm",
    "packaging",
    "pyasn1==0.6.3",
    "pyasn1_modules==0.4.2"
)

Write-Host "[6/7] Writing offline helper files..."
$UseScript = @'
param(
    [switch]$NoIndex
)

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$IncludeDir = Join-Path $Root "include"
$LibDir = Join-Path $Root "lib"
$Wheelhouse = Join-Path $Root "wheelhouse"
$PipConfig = Join-Path $Root "pip.ini"

$env:PYTHONLDAP_BUILDDEPS_ROOT = $Root
$env:PYTHONLDAP_WHEELHOUSE = $Wheelhouse
$env:INCLUDE = "$IncludeDir;$env:INCLUDE"
$env:LIB = "$LibDir;$env:LIB"
$env:PIP_FIND_LINKS = "$Wheelhouse $env:PIP_FIND_LINKS".Trim()
$env:PIP_CONFIG_FILE = $PipConfig

if ($NoIndex) {
    $env:PIP_NO_INDEX = "1"
}

Write-Host "python-ldap build dependencies are active."
Write-Host "Wheelhouse: $Wheelhouse"
Write-Host "Include: $IncludeDir"
Write-Host "Lib: $LibDir"
'@
Write-TextFile -Path (Join-Path $PackageRoot "Use-PythonLdapBuildDeps.ps1") -Content $UseScript

$PackageReadme = @(
    "# python-ldap build dependencies",
    "",
    "This directory is generated by Build-PythonLdapBuildDeps-Payload.ps1.",
    "",
    "It contains:",
    "",
    "- OpenSSL $OpenSslVersion headers and static libraries.",
    "- OpenLDAP $OpenLdapVersion headers and static libraries.",
    "- A patched python-ldap $PythonLdapVersion source distribution for local pip builds.",
    "- Minimal Python wheels needed by pip build isolation and python-ldap runtime.",
    "",
    "Activate in a shell:",
    "",
    '```powershell',
    ". `"$PackageDirName\Use-PythonLdapBuildDeps.ps1`" -NoIndex",
    "python -m pip install python-ldap==$PythonLdapVersion",
    '```',
    "",
    "The extension build is based on the pinned Gohlke recipe commit:",
    "",
    '```text',
    $GohlkeCommit,
    '```'
) -join [Environment]::NewLine
Write-TextFile -Path (Join-Path $PackageRoot "README.md") -Content $PackageReadme

$Notices = @(
    "Third-party material in this generated payload",
    "==============================================",
    "",
    "OpenSSL",
    "  Version: $OpenSslVersion",
    "  Source: https://www.openssl.org/source/$OpenSslVersion.tar.gz",
    "",
    "OpenLDAP",
    "  Version: $OpenLdapVersion",
    "  Source: https://www.openldap.org/software/download/OpenLDAP/openldap-release/$OpenLdapVersion.tgz",
    "",
    "python-ldap",
    "  Version: $PythonLdapVersion",
    "  Source distribution: PyPI python-ldap==$PythonLdapVersion",
    "",
    "Gohlke Windows build recipe",
    "  Repository: https://github.com/cgohlke/python-ldap-build",
    "  Commit: $GohlkeCommit",
    "  Applied files: openssl.diff, openldap.diff, python-ldap.diff"
) -join [Environment]::NewLine
Write-TextFile -Path (Join-Path $PackageRoot "metadata\THIRD_PARTY_NOTICES.txt") -Content $Notices

$Metadata = [ordered]@{
    name = $PackageDirName
    repo = $Repo
    release_tag = $ReleaseTag
    created_at = (Get-Date).ToString("s")
    gohlke_commit = $GohlkeCommit
    openssl = $OpenSslVersion
    openldap = $OpenLdapVersion
    python_ldap = $PythonLdapVersion
    includes_prebuilt_python_ldap_wheel = $false
    includes_cyrus_sasl = $false
    package_layout = @("include", "lib", "wheelhouse", "Use-PythonLdapBuildDeps.ps1", "pip.ini")
}
$Metadata | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $PackageRoot "metadata\builddeps.json") -Encoding UTF8

$RequiredPaths = @(
    "include\lber.h",
    "include\ldap.h",
    "lib\olber32_a.lib",
    "lib\oldap32.lib",
    "lib\oldap_r.lib",
    "lib\libssl.lib",
    "lib\libcrypto.lib",
    "wheelhouse\python_ldap-$PythonLdapVersion.tar.gz"
)

if (-not $SkipNativeBuild) {
    foreach ($RelativePath in $RequiredPaths) {
        $Path = Join-Path $PackageRoot $RelativePath
        if (-not (Test-Path $Path)) {
            throw "Generated package is missing required file: $RelativePath"
        }
    }
}

Write-Host "[7/7] Creating release payload and manifest..."
$ZipPath = Join-Path $BundlePath "$PackageDirName.zip"
if (Test-Path $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
}
Compress-Archive -Path $PackageRoot -DestinationPath $ZipPath -Force

$InstallerScriptSource = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Install-PythonLdapBuildDeps.ps1"
if (Test-Path $InstallerScriptSource) {
    Copy-Item -Path $InstallerScriptSource -Destination (Join-Path $BundlePath "Install-PythonLdapBuildDeps.ps1") -Force
}
else {
    Write-Host "Installer script not found near builder yet: $InstallerScriptSource"
}

$Files = Get-ChildItem $BundlePath -File | ForEach-Object {
    [pscustomobject]@{
        name = $_.Name
        size = $_.Length
        sha256 = Get-Sha256 $_.FullName
    }
}

$Manifest = [ordered]@{
    name = $PackageDirName
    repo = $Repo
    release_tag = $ReleaseTag
    created_at = (Get-Date).ToString("s")
    gohlke_commit = $GohlkeCommit
    openssl = $OpenSslVersion
    openldap = $OpenLdapVersion
    python_ldap = $PythonLdapVersion
    public_download = $true
    closed_contour_non_github_downloads = $false
    includes_prebuilt_python_ldap_wheel = $false
    includes_cyrus_sasl = $false
    files = $Files
}

$ManifestPath = Join-Path $BundlePath "python-ldap-builddeps-manifest.json"
$Manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $ManifestPath -Encoding UTF8

Write-Host ""
Write-Host "Python LDAP build dependency payload is ready:"
Write-Host $BundlePath
Write-Host ""
Get-ChildItem $BundlePath -File | Select-Object FullName, Length
