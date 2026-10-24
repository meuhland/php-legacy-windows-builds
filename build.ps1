<#
.SYNOPSIS
    Builds patched legacy PHP (5.6, 7.0, 7.2, 7.3, 7.4) for Windows, with every
    extension the official dependency packages support.

.DESCRIPTION
    For each requested version:
      1. Gets the PHP SDK 2.2.0 (always: it provides 7za and the VC14/VC15 shells)
         and, for 5.6, the 2011 PHP binary tools (bison/re2c for the VC11 build).
      2. Clones the final upstream release tag of php-src and applies
         patches\<version>\*.patch in order.
      3. Appends $VersionSuffix (default -cve2026) to the version string.
      4. Gets the dependency libraries: phpsdk_deps for 7.2-7.4, the archived
         2018-12 bundles for 7.0 and 5.6.
      5. Runs buildconf, then configure --enable-snapshot-build, nmake and
         nmake snap once per flavor (TS and/or NTS) inside the matching Visual
         Studio environment, and copies the resulting zips to <Root>\dist.

    Version  Compiler  Visual Studio
    -------  --------  ------------------------------------------------------------
    7.2-7.4  VC15      VS2017 with "Desktop development with C++"
    7.0      VC14      VS2015, or VS2017 + "VC++ 2015.3 v14.00 (v140) toolset for desktop"
                       (or pass -Vc14WithVs2017 to use the VS2017 compiler instead)
    5.6      VC11      VS2012 (Update 5)

    Re-running is safe: sources are reset to the tag and re-patched, and
    dependencies are reused.

.EXAMPLE
    .\build.ps1 -Version 7.3,7.2
.EXAMPLE
    .\build.ps1 -Version all -Flavors TS
.EXAMPLE
    .\build.ps1 -Version 7.0 -Vc14WithVs2017
#>
[CmdletBinding()]
param(
    # 5.6, 7.0, 7.2, 7.3, 7.4 or all; several as 7.3,7.2 (validated below: powershell -File
    # passes "7.3,7.2" as a single string, which ValidateSet would reject).
    [Parameter(Mandatory)]
    [string[]] $Version,

    # SDK, build trees and dist folder. Must not contain spaces.
    [string] $Root = 'C:\php-sdk',

    [ValidateSet('x64', 'x86')]
    [string] $Arch = 'x64',

    # TS = thread-safe (Apache mod_php); NTS = non-thread-safe (IIS/FastCGI, php-cgi). Both as TS,NTS.
    [string[]] $Flavors = @('TS', 'NTS'),

    # Appended to the release version: php -v shows e.g. 7.3.33-cve2026.
    [ValidatePattern('^[-.+~\w]*$')]
    [string] $VersionSuffix = '-cve2026',

    # Appended to every configure call, e.g. '--without-enchant'. With powershell -File, pass
    # several as one space-separated string: values such as 'C:\sdk,shared' contain commas.
    [string[]] $ExtraConfigureArgs = @(),

    # Build 7.0 with the VS2017 (VC15) compiler when the VC14 toolset is missing.
    # The output is binary compatible (same vcruntime140); PHP 7.0 reports the compiler as untested.
    [switch] $Vc14WithVs2017,

    # Stop after preparing the patched sources, archived deps and build-task.cmd (no Visual Studio needed).
    [switch] $PrepareOnly
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SdkRepo      = 'https://github.com/php/php-sdk-binary-tools.git'
$SdkTag       = 'php-sdk-2.2.0'
$LegacySdkUrl = 'https://downloads.php.net/~windows/php-sdk/php-sdk-binary-tools-20110915.zip'
$DepsArchives = 'https://downloads.php.net/~windows/php-sdk/archives'
$PhpRepo      = 'https://github.com/php/php-src.git'

$Releases = [ordered]@{
    # 5.6 builds in the source tree: its Makefile links php5ts.dll without a response file,
    # and the absolute paths of an object directory overflow nmake's command line.
    # The snapshot build would also enable SAPIs and extensions php.net left out of its own
    # 5.6 builds (ISAPI uses 32-bit inline assembly, MSSQL needs a library not in the deps).
    '5.6' = @{ Tag = 'php-5.6.40'; Crt = 'vc11'; DepsArchive = 'deps-5.6-vc11-{0}_2018-12.7z'; InTree = $true
               Configure = @('--disable-isapi', '--disable-nsapi', '--without-pi3web', '--without-mssql', '--without-pdo-mssql') }
    '7.0' = @{ Tag = 'php-7.0.33'; Crt = 'vc14'; DepsArchive = 'deps-7.0-vc14-{0}_2018-12.7z' }
    '7.2' = @{ Tag = 'php-7.2.34'; Crt = 'vc15'; DepsBranch = '7.2' }
    '7.3' = @{ Tag = 'php-7.3.33'; Crt = 'vc15'; DepsBranch = '7.3' }
    '7.4' = @{ Tag = 'php-7.4.33'; Crt = 'vc15'; DepsBranch = '7.4' }
}

function Invoke-Git {
    & git @args
    if ($LASTEXITCODE) { throw "git $($args -join ' ') failed with exit code $LASTEXITCODE" }
}

function Get-File([string] $Url, [string] $Path) {
    if (-not (Test-Path $Path)) {
        Write-Host "Downloading $Url"
        Invoke-WebRequest -Uri $Url -OutFile "$Path.part" -UseBasicParsing
        Move-Item "$Path.part" $Path
    }
}

# --- Preflight -------------------------------------------------------------

if ($Root -match '\s') { throw "Root must not contain spaces (the PHP SDK can't handle them): $Root" }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git was not found on PATH.' }

function Split-List([string[]] $Values) {
    @($Values | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
}

# From a PowerShell prompt, -Version 7.3,7.0 is an array of numbers and 7.0 arrives as "7".
$Version = @(Split-List $Version | ForEach-Object { if ($_ -match '^\d+$') { "$_.0" } else { $_ } })
$unknown = @($Version | Where-Object { $_ -ne 'all' -and -not $Releases.Contains($_) })
if ($unknown) { throw "Unknown version(s): $($unknown -join ', '). Use 5.6, 7.0, 7.2, 7.3, 7.4 or all." }

$Flavors = Split-List $Flavors | ForEach-Object { $_.ToUpperInvariant() }
$unknown = @($Flavors | Where-Object { $_ -notin 'TS', 'NTS' })
if ($unknown -or -not $Flavors) { throw "Unknown flavor(s): $($unknown -join ', '). Use TS, NTS or TS,NTS." }

$selected = if ($Version -contains 'all') { @($Releases.Keys) } else { $Releases.Keys | Where-Object { $Version -contains $_ } }

$dist = Join-Path $Root 'dist'
New-Item -ItemType Directory -Force -Path $Root, $dist | Out-Null

# --- SDKs ------------------------------------------------------------------

if (-not (Test-Path (Join-Path $Root 'phpsdk-starter.bat'))) {
    Write-Host "Cloning $SdkTag into $Root"
    Invoke-Git -c core.autocrlf=false clone -q --depth 1 --branch $SdkTag $SdkRepo (Join-Path $Root '.sdk-tmp')
    # Root may already hold dist/, so move the clone's content in rather than cloning into Root.
    Get-ChildItem -Force (Join-Path $Root '.sdk-tmp') | Move-Item -Destination $Root
    Remove-Item (Join-Path $Root '.sdk-tmp')
}

# SDK 2.2.0 predates the move of its dependency server to downloads.php.net, and phpsdk_deps
# (7.2-7.4) fails with "Failed to fetch supported branches" until two later upstream fixes
# are applied. Done in place on every run, so an SDK cloned by an older build.ps1 is fixed too.
#  - VERSION ends in CRLF, which lands in the User-Agent header and corrupts the request
#    (php-sdk-binary-tools GH-32): trim it.
#  - The series listing now has relative links (href="packages-..."), which the pattern
#    requiring "/packages-" doesn't match: drop the slash, as php-sdk-binary-tools master does.
$sdkConfig = Join-Path $Root 'lib\php\libsdk\SDK\Config.php'
$text = [IO.File]::ReadAllText($sdkConfig)
$fixed = $text.Replace('return file_get_contents($path);', 'return trim(file_get_contents($path));')
$fixed = $fixed.Replace('preg_match_all(",/packages-', 'preg_match_all(",packages-')
if ($fixed -ne $text) {
    Write-Host "Fixing $sdkConfig for downloads.php.net"
    [IO.File]::WriteAllText($sdkConfig, $fixed)
}
if (-not $fixed.Contains('return trim(file_get_contents($path));') -or -not $fixed.Contains('preg_match_all(",packages-')) {
    Write-Warning "$sdkConfig doesn't look like SDK 2.2.0's; phpsdk_deps may fail to fetch dependencies."
}

$sevenZip = Join-Path $Root 'bin\7za.exe'

$legacySdk = Join-Path $Root 'legacy-2011'
if ($selected -contains '5.6' -and -not (Test-Path (Join-Path $legacySdk 'bin\bison.exe'))) {
    $zip = Join-Path $Root 'php-sdk-binary-tools-20110915.zip'
    Get-File $LegacySdkUrl $zip
    Expand-Archive -Path $zip -DestinationPath $legacySdk -Force
}

# --- Per version -----------------------------------------------------------

foreach ($ver in $selected) {
    $rel     = $Releases[$ver]
    $started = Get-Date
    $base    = Join-Path $Root "phpdev\$($rel.Crt)\$Arch\php-$ver"
    $src     = Join-Path $base 'src'
    $deps    = Join-Path $base 'deps'
    $log     = Join-Path $base 'build.log'
    # Start from an empty object directory: the source is reset below, which deletes files
    # generated into it (win32\wsyslog.h), while their stamps here (wsyslog.rc) would
    # survive and stop nmake from regenerating them. configure's
    # --enable-object-out-dir=../obj/ also refuses a directory that doesn't exist yet.
    $obj = Join-Path $base 'obj'
    if (Test-Path $obj) { Remove-Item -LiteralPath $obj -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $base, $obj | Out-Null

    Write-Host ''
    Write-Host "===== PHP $ver ($($rel.Tag) + patches\$ver, $($rel.Crt) $Arch, $($Flavors -join '+')) =====" -ForegroundColor Cyan

    # Source: the release tag, reset and re-patched on every run.
    if (-not (Test-Path (Join-Path $src '.git'))) {
        Invoke-Git -c core.autocrlf=false -c advice.detachedHead=false clone -q --depth 1 --branch $rel.Tag $PhpRepo $src
    } else {
        Invoke-Git -C $src fetch -q --depth 1 origin "refs/tags/$($rel.Tag):refs/tags/$($rel.Tag)"
        Invoke-Git -C $src reset -q --hard $rel.Tag
        Invoke-Git -C $src clean -q -fdx
    }
    Invoke-Git -C $src config core.autocrlf false

    $patches = Get-ChildItem (Join-Path $PSScriptRoot "patches\$ver") -Filter *.patch | Sort-Object Name
    if (-not $patches) { throw "No patches found in patches\$ver" }
    foreach ($p in $patches) {
        Write-Host "Applying $($p.Name)"
        Invoke-Git -C $src apply --whitespace=nowarn $p.FullName
    }

    # Version suffix. 7.4 takes the version from AC_INIT in configure.ac;
    # 5.6-7.3 from the PHP_*_VERSION= lines in configure.in / configure.ac.
    $cfgFile = @('configure.ac', 'configure.in') | ForEach-Object { Join-Path $src $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
    $text = [IO.File]::ReadAllText($cfgFile)
    if ($text -match 'AC_INIT\(\[PHP\],\[') {
        $text = $text -replace 'AC_INIT\(\[PHP\],\[(\d+\.\d+\.\d+)[^\]]*\]', ('AC_INIT([PHP],[${1}' + $VersionSuffix + ']')
    } else {
        $text = $text -replace '(?m)^PHP_EXTRA_VERSION="[^"]*"', "PHP_EXTRA_VERSION=`"$VersionSuffix`""
    }
    [IO.File]::WriteAllText($cfgFile, $text)

    $versionH = Join-Path $src 'main\php_version.h'
    $text = [IO.File]::ReadAllText($versionH)
    $text = $text -replace '(?m)^#define PHP_EXTRA_VERSION "[^"]*"', "#define PHP_EXTRA_VERSION `"$VersionSuffix`""
    $text = $text -replace '(?m)^#define PHP_VERSION "(\d+\.\d+\.\d+)[^"]*"', ('#define PHP_VERSION "${1}' + $VersionSuffix + '"')
    [IO.File]::WriteAllText($versionH, $text)

    # Dependencies: archived bundles unpack to deps\ next to src\ (configure's default ..\deps).
    if ($rel.DepsArchive -and -not (Test-Path (Join-Path $deps 'include'))) {
        $archive = Join-Path $Root ($rel.DepsArchive -f $Arch)
        Get-File "$DepsArchives/$(Split-Path $archive -Leaf)" $archive
        & $sevenZip x -y "-o$base" $archive | Out-Null
        if ($LASTEXITCODE) { throw "7za failed to extract $archive" }
    }

    # Build task, run by cmd inside the Visual Studio environment.
    $configureArgs = @(
        '--enable-snapshot-build'          # every extension whose deps are present, shared where possible
        '--enable-debug-pack'              # .pdb files in a separate debug-pack zip
        '--enable-com-dotnet=shared'
        '--without-analyzer'
    ) + @($rel.Configure | Where-Object { $_ }) + $ExtraConfigureArgs
    if (-not $rel.InTree) {
        $configureArgs += '--enable-object-out-dir=../obj/'  # outside the source tree, reset on every run
    }

    # Some shells and tools set NoDefaultCurrentDirectoryInExePath; cmd then won't run
    # buildconf.bat and configure.bat from the source directory by name.
    $lines = @('@echo off', 'setlocal', 'set "NoDefaultCurrentDirectoryInExePath="')
    if ($rel.Crt -eq 'vc11') {
        $vcArch = if ($Arch -eq 'x64') { 'amd64' } else { 'x86' }
        $lines += @(
            'if not defined VS110COMNTOOLS (echo Visual Studio 2012 was not found: VS110COMNTOOLS is not set. & exit /b 3)'
            'set "VC11=%VS110COMNTOOLS%..\..\VC"'
            # Express editions only ship the x86-hosted x64 cross compiler.
            "set `"VCARCH=$vcArch`""
            'if "%VCARCH%"=="amd64" if not exist "%VC11%\bin\amd64\cl.exe" set "VCARCH=x86_amd64"'
            'call "%VC11%\vcvarsall.bat" %VCARCH% || exit /b 1'
            "call `"$legacySdk\bin\phpsdk_setvars.bat`""
        )
    }
    $lines += "cd /d `"$src`""
    if ($rel.DepsBranch) {
        $lines += "call phpsdk_deps --update --branch $($rel.DepsBranch) --deps `"$deps`" || exit /b 1"
    }
    $lines += 'call buildconf.bat || exit /b 1'
    foreach ($flavor in $Flavors) {
        $flavorArgs = if ($flavor -eq 'NTS') { @('--disable-zts') } else { @() }
        $lines += @(
            "echo ===== Configuring PHP $ver $flavor ====="
            "call configure.bat $(($configureArgs + $flavorArgs) -join ' ') || exit /b 1"
            "echo ===== Building PHP $ver $flavor ====="
            'nmake || exit /b 1'
            'nmake snap || exit /b 1'
        )
    }
    $lines += 'exit /b 0'

    $task = Join-Path $base 'build-task.cmd'
    [IO.File]::WriteAllLines($task, $lines)

    if ($PrepareOnly) {
        Write-Host "Prepared $src; build task: $task"
        continue
    }

    if ($rel.Crt -eq 'vc11') {
        $command = "$task 2>&1"
    } else {
        $starterCrt = if ($rel.Crt -eq 'vc14' -and $Vc14WithVs2017) { 'vc15' } else { $rel.Crt }
        $command = "$Root\phpsdk-$starterCrt-$Arch.bat -t $task 2>&1"
    }

    Write-Host "Building; full output also goes to $log"
    # 2>&1 inside cmd so Windows PowerShell doesn't turn compiler stderr into terminating errors.
    $ErrorActionPreference = 'Continue'
    & cmd.exe /c $command | Tee-Object -FilePath $log
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($exitCode) { throw "PHP $ver build failed with exit code $exitCode. See $log." }

    # Packages are written to the build directories (x64\Release_TS, Release, ...) only:
    # the source tree has .zip test fixtures of its own.
    $outRoot = if ($rel.InTree) { $src } else { $obj }
    $zips = @($outRoot, (Join-Path $outRoot 'x64')) | Where-Object { Test-Path $_ } |
            ForEach-Object { Get-ChildItem -Path $_ -Directory -Filter 'Release*' } |
            ForEach-Object { Get-ChildItem -Path $_.FullName -File -Filter *.zip } |
            Where-Object { $_.LastWriteTime -ge $started }
    $zips | Copy-Item -Destination $dist -Force
    Write-Host "PHP $ver done:" -ForegroundColor Green
    $zips | ForEach-Object { Write-Host "  $(Join-Path $dist $_.Name)" }
}

Write-Host ''
Write-Host "All packages are in $dist. Deploy the php-*.zip that matches your server ('nts' in the name = IIS/FastCGI, none = Apache mod_php),"
Write-Host "then check that 'php -v' shows the $VersionSuffix suffix and compare 'php -m' with the server you are replacing."
