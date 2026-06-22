# Python LDAP build dependencies for a closed contour

This recipe prepares only the files that cannot be downloaded from GitHub in the closed contour:

- OpenSSL headers and libraries.
- OpenLDAP headers and libraries.
- Patched `python-ldap==3.4.5` source distribution.
- Minimal Python wheels required by pip build isolation and `python-ldap` runtime.

The repository itself contains scripts and documentation only. Generated binaries and third-party archives are published as GitHub Release assets.

## Internet-side build

Prerequisites:

```text
1. VS Build Tools 2019 already installed in C:\BuildTools\VS2019.
2. Git.
3. Perl for OpenSSL build, for example Strawberry Perl or Git/MSYS Perl.
4. Python 3.14 launcher available as py -3.14.
5. GitHub CLI only if you also upload the release assets.
```

Build payload:

```powershell
cd "C:\offline\infra-offline-bundle"

powershell -ExecutionPolicy Bypass `
  -File ".\Build-PythonLdapBuildDeps-Payload.ps1"
```

The output directory is:

```text
C:\offline\python-ldap-builddeps-release
```

Upload release assets:

```powershell
$Repo = "eccodolf/infra-offline-bundle"
$Tag = "python-ldap-3.4.5-builddeps-2026-06"
$BundlePath = "C:\offline\python-ldap-builddeps-release"

gh release create $Tag `
  --repo $Repo `
  --title "python-ldap 3.4.5 build dependencies" `
  --notes "OpenSSL/OpenLDAP SDK and local pip inputs for building python-ldap from source in a closed contour."

gh release upload $Tag `
  --repo $Repo `
  --clobber `
  "$BundlePath\python-ldap-builddeps-manifest.json" `
  "$BundlePath\Install-PythonLdapBuildDeps.ps1" `
  "$BundlePath\python-ldap-builddeps.zip"
```

## Closed-contour install

Download and run the installer from GitHub Release:

```powershell
cd "C:\offline"

$Repo = "eccodolf/infra-offline-bundle"
$Tag = "python-ldap-3.4.5-builddeps-2026-06"

New-Item -ItemType Directory -Force ".\python-ldap-builddeps-bootstrap" | Out-Null

Invoke-WebRequest `
  -UseBasicParsing `
  -Uri "https://github.com/$Repo/releases/download/$Tag/Install-PythonLdapBuildDeps.ps1" `
  -OutFile ".\python-ldap-builddeps-bootstrap\Install-PythonLdapBuildDeps.ps1"

powershell -ExecutionPolicy Bypass `
  -File ".\python-ldap-builddeps-bootstrap\Install-PythonLdapBuildDeps.ps1" `
  -VenvPath "C:\PyCharmProjects\rescalc\venv" `
  -NoIndex
```

If GitHub requires a proxy for the first download, add:

```powershell
-Proxy "http://host:port"
```

If proxy is not required, do not pass `-Proxy`. The installer asks for proxy only when it actually has to download a missing asset.

After the installer has configured the venv, run the normal pip install:

```powershell
C:\PyCharmProjects\rescalc\venv\Scripts\python.exe -m pip install python-ldap==3.4.5
```

For an interactive shell without `-VenvPath`, activate the local paths first:

```powershell
. "C:\offline\python-ldap-builddeps\Use-PythonLdapBuildDeps.ps1" -NoIndex
python -m pip install python-ldap==3.4.5
```

## What pip sees

The installer writes:

```text
C:\offline\python-ldap-builddeps\pip.ini
C:\PyCharmProjects\rescalc\venv\pip.ini    when -VenvPath is passed
```

The config points pip to:

```text
C:\offline\python-ldap-builddeps\wheelhouse
```

That wheelhouse contains the patched `python_ldap-3.4.5.tar.gz` and the minimal build/runtime wheels. The final `_ldap` extension is still compiled by `pip install` on the target machine.

## Based on Gohlke recipe

The native dependency build follows the pinned Windows recipe from:

```text
https://github.com/cgohlke/python-ldap-build
commit fab7165a2e543e7aebee5d38ef6df538e2ae8ee1
```

It uses OpenSSL `openssl-3.0.18`, OpenLDAP `openldap-2.4.59`, and disables Cyrus SASL for the `python-ldap` extension build. The Gohlke OpenLDAP project files are retargeted to `PlatformToolset=v142` for VS Build Tools 2019. For the PyPI source distribution the build script writes the equivalent Gohlke `_ldap` settings into `setup.cfg`, using `builddeps_include` and `builddeps_lib` inside the sdist to avoid a Windows path collision with the package's `Lib` directory.
