$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Assert-FileExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $Path = Join-Path $Root $RelativePath
    if (-not (Test-Path $Path)) {
        throw "Missing expected file: $RelativePath"
    }
}

function Assert-FileContains {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $Path = Join-Path $Root $RelativePath
    $Content = Get-Content -Raw $Path
    if ($Content -notmatch $Pattern) {
        throw "Expected $RelativePath to match pattern: $Pattern"
    }
}

function Assert-PowerShellParses {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $Path = Join-Path $Root $RelativePath
    $Tokens = $null
    $Errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors) | Out-Null
    if ($Errors.Count -gt 0) {
        $Messages = ($Errors | ForEach-Object { $_.Message }) -join "; "
        throw "PowerShell parse errors in ${RelativePath}: $Messages"
    }
}

Assert-FileExists "Build-PythonLdapBuildDeps-Payload.ps1"
Assert-FileExists "Install-PythonLdapBuildDeps.ps1"
Assert-FileExists "python_ldap_builddeps_public_repo.md"

Assert-PowerShellParses "Build-PythonLdapBuildDeps-Payload.ps1"
Assert-PowerShellParses "Install-PythonLdapBuildDeps.ps1"

Assert-FileContains "Build-PythonLdapBuildDeps-Payload.ps1" 'fab7165a2e543e7aebee5d38ef6df538e2ae8ee1'
Assert-FileContains "Build-PythonLdapBuildDeps-Payload.ps1" 'openssl-3\.0\.18'
Assert-FileContains "Build-PythonLdapBuildDeps-Payload.ps1" 'openldap-2\.4\.59'
Assert-FileContains "Build-PythonLdapBuildDeps-Payload.ps1" 'PythonLdapVersion = "3\.4\.5"'
Assert-FileContains "Build-PythonLdapBuildDeps-Payload.ps1" 'python-ldap=='
Assert-FileContains "Build-PythonLdapBuildDeps-Payload.ps1" 'OpenLdapPlatformToolset = "v142"'
Assert-FileContains "Build-PythonLdapBuildDeps-Payload.ps1" 'PlatformToolset'
Assert-FileContains "Build-PythonLdapBuildDeps-Payload.ps1" 'builddeps_include'
Assert-FileContains "Build-PythonLdapBuildDeps-Payload.ps1" 'builddeps_lib'
Assert-FileContains "Build-PythonLdapBuildDeps-Payload.ps1" 'setuptools-scm'
Assert-FileContains "Build-PythonLdapBuildDeps-Payload.ps1" 'pyasn1_modules==0\.4\.2'

Assert-FileContains "Install-PythonLdapBuildDeps.ps1" 'python-ldap-builddeps-manifest\.json'
Assert-FileContains "Install-PythonLdapBuildDeps.ps1" 'PIP_FIND_LINKS'
Assert-FileContains "Install-PythonLdapBuildDeps.ps1" 'pip\.ini'
Assert-FileContains "Install-PythonLdapBuildDeps.ps1" 'include\\lber\.h'
Assert-FileContains "Install-PythonLdapBuildDeps.ps1" 'olber32_a\.lib'
Assert-FileContains "Install-PythonLdapBuildDeps.ps1" 'NoIndex'
Assert-FileContains "Install-PythonLdapBuildDeps.ps1" 'InstallPythonLdap'
Assert-FileContains "Install-PythonLdapBuildDeps.ps1" 'PIP_CONFIG_FILE'
Assert-FileContains "Install-PythonLdapBuildDeps.ps1" 'Restore-EnvironmentVariable'

Assert-FileContains "README.md" 'Python LDAP'
Assert-FileContains "README.md" 'Install-PythonLdapBuildDeps\.ps1'
Assert-FileContains "README.md" '\$VenvPath = "C:\\PyCharmProjects\\rescalc\\venv"'
Assert-FileContains "README.md" 'InstallPythonLdap'

$InstallerContent = Get-Content -Raw (Join-Path $Root "Install-PythonLdapBuildDeps.ps1")
if ($InstallerContent -match 'Join-Path \$VenvPath "pip\.ini"') {
    throw "Installer must not write persistent pip.ini into the venv."
}

Write-Host "All repository checks passed."
