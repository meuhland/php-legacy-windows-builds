# Building PHP 7.4 (NTS, x64) on Windows: a worked run

A complete run of `build.ps1` and `compare.ps1` for **PHP 7.4.33 NTS x64** on a clean
Windows 11 machine, on 22 October 2026, against this repository at `4d4bbb7`. It records
the toolchain that worked, the checks done before running anything, the three problems hit
on the way and their fixes, and the results.

Results: on the full test pack, the patched build shows exactly the 9 expected differences
from the official build. It also lacks the `DOTNET` class, because VS2017 Build Tools doesn't
put a .NET Framework SDK on the include path (section 7).

Short version: the build works, but `build.ps1` as of `4d4bbb7` stops in `phpsdk_deps` for
7.2-7.4 until two lines of the PHP SDK 2.2.0 it downloads are fixed (section 5). Commit
`c88c8f4` (branch `fix-sdk-2.2.0-deps`) makes `build.ps1` apply those fixes itself, and was
tested with a fresh `-Root` (section 8). With it, sections 5a and 5b need no manual steps.

## 1. Machine

| | |
|---|---|
| OS | Windows 11, x64 |
| Visual Studio | **Build Tools 2017 15.9.37627.17**, alongside an unrelated VS 2026 |
| MSVC | toolset 14.16.27023, `cl` 19.16.27054 for x64 |
| Windows SDK | 10.0.19041.0 |
| Git | Git for Windows 2.55.0 |
| PowerShell | Windows PowerShell 5.1 |

Only the 7.4 NTS flavor was built. TS (`-Flavors TS`) and 7.2/7.3 use the same compiler and
should hit the same SDK problem; 7.0 and 5.6 were not tried.

## 2. Toolchain

7.2-7.4 build with VC15. `build.ps1` starts the compiler through the PHP SDK 2.2.0 starter
`phpsdk-vc15-x64.bat`, whose `bin\phpsdk_setshell.bat` looks for Visual Studio with:

```
vswhere -version [15,16) -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64
```

So it needs an actual **VS 15.x (2017)** instance. A newer Visual Studio with the v141
toolset added is not found. The smallest install that works is VS2017 Build Tools, from an
elevated prompt (about 5 GB, side by side with newer Visual Studio versions):

```bat
vs_buildtools.exe --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive --norestart
```

The installer is https://aka.ms/vs/15/release/vs_buildtools.exe. `--includeRecommended` adds
the VC++ 2017 x86/x64 tools and a Windows 10 SDK; here it picked 10.0.19041.

Check it the way the SDK will. `phpsdk_setshell.bat` first queries without `-products`,
which only lists Community/Professional/Enterprise and misses Build Tools; its second query
adds `-products Microsoft.VisualStudio.Product.BuildTools`. Query the same way:

```sh
"/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe" -nologo -version "[15,16)" -products Microsoft.VisualStudio.Product.BuildTools -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath -format text
```

```
installationPath: C:\Program Files (x86)\Microsoft Visual Studio\2017\BuildTools
```

The SDK also requires `Windows.h` under `C:\Program Files (x86)\Windows Kits\10\Include\<version>\um\`.
To confirm the compiler starts, from a `.cmd` file:

```bat
@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2017\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" amd64 >nul || exit /b 1
cl 2>&1 | findstr /i "Version"
echo WindowsSdkVersion=%WindowsSdkVersion%
where nmake
```

```
Microsoft (R) C/C++ Optimizing Compiler Version 19.16.27054 for x64
WindowsSdkVersion=10.0.19041.0\
C:\Program Files (x86)\Microsoft Visual Studio\2017\BuildTools\VC\Tools\MSVC\14.16.27023\bin\Hostx64\x64\nmake.exe
```

## 3. Check the 7.4 patch against php-src

`patches/7.4` is described as the PHP security team's backport,
[php-src `712e60f`](https://github.com/php/php-src/commit/712e60f9edfd03f0960fc4fc3c2c375f42b90aa2),
which is on php-src's `PHP-7.4-CVE-2026-109618-109619` branch. This compares every added and
removed line of the two (Git Bash, with `gh`):

```sh
gh api -H "Accept: application/vnd.github.diff" repos/php/php-src/commits/712e60f9edfd03f0960fc4fc3c2c375f42b90aa2 > /tmp/up.diff
norm(){ grep -E '^[-+]' "$1" | grep -vE '^(\+\+\+|---) ' ; }
norm /tmp/up.diff > /tmp/up.lines
sed -n '/^diff --git/,$p' patches/7.4/0001-Avoid-state-corruption-via-bailout.patch | grep -vE '^-- ?$|^[0-9]+\.[0-9]+' > /tmp/p.diff
norm /tmp/p.diff > /tmp/p.lines
diff /tmp/up.lines /tmp/p.lines && echo IDENTICAL
```

Result: 299 added/removed lines on each side, **identical**.

## 4. Dry run

From PowerShell, `.\build.ps1` works. From Git Bash, `.\build.ps1` reaches PowerShell as
`.build.ps1` and fails, so pass the full path:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\php-legacy-windows-builds\build.ps1 -Version 7.4 -PrepareOnly
```

```
Cloning php-sdk-2.2.0 into C:\php-sdk
===== PHP 7.4 (php-7.4.33 + patches\7.4, vc15 x64, TS+NTS) =====
warning: refs/tags/php-7.4.33 005f0cbace2d58e74867606f6b9a335491566bb0 is not a commit!
Applying 0001-Avoid-state-corruption-via-bailout.patch
Prepared C:\php-sdk\phpdev\vc15\x64\php-7.4\src; build task: C:\php-sdk\phpdev\vc15\x64\php-7.4\build-task.cmd
```

36 s. The `is not a commit!` warning is git's normal output when a shallow clone checks out
an annotated tag (`005f0cb` is the tag object). The checked-out source is the tag's commit,
`dca8d5565b947270a29f232bc54efd9df3b92b94`, the same as `php-7.4.33^{}` on github.com.
`git status` in the source shows the patch's 17 files plus `configure.ac` and
`main\php_version.h`, which now read `7.4.33-cve2026`.

For 7.2-7.4 `-PrepareOnly` does **not** test the dependency download: `phpsdk_deps` runs
inside `build-task.cmd`, which the dry run doesn't execute. That is where the next problem
shows up.

## 5. Problems and fixes

This section describes the run with `build.ps1` at `4d4bbb7`, fixed by hand. `build.ps1`
from `c88c8f4` handles 5a and 5b itself; see section 8.

### 5a. SDK 2.2.0 can't read the new dependency server's listing

```
Fatal error: Uncaught SDK\Exception: Failed to fetch supported branches in C:\php-sdk\lib\php\libsdk\SDK\Config.php:170
#0 C:\php-sdk\lib\php\libsdk\SDK\Config.php(180): SDK\Config::getKnownBranches()
#1 C:\php-sdk\bin\phpsdk_deps.php(105): SDK\Config::setCurrentBranchName('7.4')
```

The build stops 11 s in, before compiling. SDK 2.2.0 reads its branch list from
`https://windows.php.net/downloads/php-sdk/deps/series/`, which now 302-redirects to
`https://downloads.php.net/~windows/php-sdk/deps/series/`. Two separate bugs in 2.2.0 break
this; both are fixed in current php-sdk-binary-tools `master`. Both are in
`C:\php-sdk\lib\php\libsdk\SDK\Config.php`.

**User agent with a line break.** `getSdkVersion()` returns the `VERSION` file unmodified,
and in the 2.2.0 tag that file is `2.2.0\r\n`. The CR/LF lands inside the `User-Agent` header
and corrupts the request. Reproduced with the SDK's own PHP (7.3.6, curl 7.64.0 / OpenSSL
1.1.1b):

```
clean UA            http=200 len=16978 err=0
UA as 2.2.0 sends   http=0 len=0 err=55 Failed sending HTTP request
```

Upstream fixed this in `b3d87e14` "Fix HTTP request corruption by the user agent (GH-32)".

**Link pattern.** The new server writes relative links (`href="packages-7.4-vc15-x64-stable.txt"`).
2.2.0's pattern requires a `/` before `packages-`, so even a successful fetch finds no
branches. `master` dropped the `/` (and moved the host to `downloads.php.net`). It is the
only pattern in the 2.2.0 `libsdk` that parses the listing.

Fixing only the pattern is not enough; the request itself has to succeed first. With Git
Bash, after `build.ps1` has cloned the SDK (for example after `-PrepareOnly`):

```sh
F=/c/php-sdk/lib/php/libsdk/SDK/Config.php
cp -n "$F" "$F.orig"
sed -i 's#preg_match_all(",/packages-#preg_match_all(",packages-#' "$F"
sed -i '346s#return file_get_contents(\$path);#return trim(file_get_contents($path));#' "$F"
diff "$F.orig" "$F"
```

```
149c149
< 				if (preg_match_all(",/packages-(.+)-(v[cs]\d+)-(x86|x64)-(stable|staging)\.txt,U", $tmp, $m, PREG_SET_ORDER)) {
---
> 				if (preg_match_all(",packages-(.+)-(v[cs]\d+)-(x86|x64)-(stable|staging)\.txt,U", $tmp, $m, PREG_SET_ORDER)) {
346c346
< 		return file_get_contents($path);
---
> 		return trim(file_get_contents($path));
```

After both changes, `Config::getSdkUserAgentName()` returns `PHP-SDK-BINARY-TOOLS/2.2.0`
(26 characters) and `Fetcher::getByUri()` on the series listing returns 16978 bytes with
104 link matches, including `7.4 vc15 x64 stable`.

`build.ps1` only clones the SDK when `<Root>\phpsdk-starter.bat` is missing, so later runs
keep the fixed file. A fresh `<Root>` needs the changes again.

When testing the SDK's PHP by hand, pass what `bin\php\do_php.bat` passes
(`-c bin\php\php.ini -d extension_dir=bin\php\ext`). Without it, PHP looks for its
extensions in `C:\php\ext` and `curl` is missing, which looks like a different failure.

### 5b. `'buildconf.bat' is not recognized`

With the SDK fixed, `phpsdk_deps` reported `Configuration: 7.4-vc15-x64-stable`, unpacked 36
packages and printed `Updates performed successfully.` The build then stopped:

```
'buildconf.bat' is not recognized as an internal or external command,
operable program or batch file.
```

The file was present and the working directory correct. The cause was
`NoDefaultCurrentDirectoryInExePath=1` in the environment the build was started from. Some
shells and automation tools set it. With it set, `cmd` won't run a bare script name from
the current directory, so `call buildconf.bat` in `build-task.cmd` fails, and
`configure.bat` would fail next. A normal Command Prompt or PowerShell window doesn't have
it. If yours does, clear it for the build:

```sh
env -u NoDefaultCurrentDirectoryInExePath powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\path\to\php-legacy-windows-builds\build.ps1' -Version 7.4 -Flavors NTS
```

```bat
set NoDefaultCurrentDirectoryInExePath=
powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\php-legacy-windows-builds\build.ps1 -Version 7.4 -Flavors NTS
```

## 6. Build

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\php-legacy-windows-builds\build.ps1 -Version 7.4 -Flavors NTS
```

About 10.5 minutes.

`build.log` is **UTF-16** (written by `Tee-Object` in Windows PowerShell 5.1), so plain
`grep` finds nothing in it. Convert it first:

```sh
iconv -f UTF-16LE -t UTF-8 /c/php-sdk/phpdev/vc15/x64/php-7.4/build.log | tr -d '\r' > build.log.utf8.txt
grep -cE 'error C[0-9]{4}|error LNK|NMAKE : fatal' build.log.utf8.txt
grep -E 'warning C[0-9]{4}' build.log.utf8.txt | sed -E 's/.*(warning C[0-9]{4}).*/\1/' | sort | uniq -c | sort -rn
```

- 0 compiler, linker or `NMAKE : fatal` errors.
- 1,599 compiler warnings, from PHP's own sources: C4244 835, C4267 552, C4018 98, C4146 48,
  C4090 30, C4028 15, C4995 8, C4005 3. C4244/C4267 are integer-conversion warnings (e.g.
  `size_t` to `int`), usual for PHP's x64 Windows builds.
- 13 configure `WARNING:` lines for optional libraries that weren't found (Apache module
  needs ZTS, dba handlers, oci8, pspell, pdo_dblib and similar).

Packages in `C:\php-sdk\dist`:

| File | Bytes |
|---|---|
| `php-7.4.33-cve2026-nts-Win32-vc15-x64.zip` | 25,599,716 |
| `php-debug-pack-7.4.33-cve2026-nts-Win32-vc15-x64.zip` | 21,419,003 |
| `php-test-pack-7.4.33-cve2026.zip` | 14,202,360 |
| `php-devel-pack-7.4.33-cve2026-nts-Win32-vc15-x64.zip` | 1,140,916 |
| `pecl-7.4.33-cve2026-nts-Win32-vc15-x64.zip` | 22 (empty: no PECL extensions) |

SHA-256 of this run's main zip:

```
1141e5f1fd57aad69b4be2b1c0683c0a13e734a61bb28408dbf1ecc1d9ed7065  php-7.4.33-cve2026-nts-Win32-vc15-x64.zip
```

That hash identifies this run's output; another build won't reproduce it byte for byte
(timestamps are embedded).

Unpacked, without a `php.ini`:

```
> php -n -v
PHP 7.4.33-cve2026 (cli) (built: Oct 22 2026 15:28:00) ( NTS Visual C++ 2017 x64 )
Copyright (c) The PHP Group
Zend Engine v3.4.0, Copyright (c) Zend Technologies
```

- Built in: bcmath calendar Core ctype date dom filter hash iconv json libxml mysqlnd pcre
  PDO Phar readline Reflection session SimpleXML SPL standard tokenizer xml xmlreader
  xmlwriter zip zlib
- Shared in `ext\` (38): bz2 com_dotnet curl dba enchant exif ffi fileinfo ftp gd2 gettext
  gmp imap intl ldap mbstring mysqli odbc opcache openssl pdo_firebird pdo_mysql pdo_odbc
  pdo_pgsql pdo_sqlite pgsql phpdbg_webhelper shmop snmp soap sockets sodium sqlite3 sysvshm
  tidy xmlrpc xsl zend_test
- `ini_get("max_multipart_body_parts")` returns `-1`, the new default.

`php_zend_test.dll` is PHP's internal test extension, included by `--enable-snapshot-build`.
Don't enable it on a server.

## 7. Comparison with the official build

```sh
env -u NoDefaultCurrentDirectoryInExePath powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\path\to\php-legacy-windows-builds\compare.ps1' -Version 7.4 -TargetedOnly -Flavor NTS
```

About 4 minutes, including the downloads:

```
===== PHP 7.4 NTS: official 7.4.33 vs patched 7.4.33-cve2026 =====
Downloading https://windows.php.net/downloads/releases/archives/php-7.4.33-nts-Win32-vc15-x64.zip
Downloading https://windows.php.net/downloads/releases/archives/php-test-pack-7.4.33.zip
PHP 7.4 NTS x64
  official: php-7.4.33-nts-Win32-vc15-x64.zip
  patched:  php-7.4.33-cve2026-nts-Win32-vc15-x64.zip
  extensions enabled in both (34): mbstring bz2 com_dotnet curl dba enchant exif ffi fileinfo ftp gd2 gettext gmp imap intl ldap mysqli odbc openssl pdo_mysql pdo_odbc pdo_pgsql pdo_sqlite pgsql shmop soap sockets sodium sqlite3 sysvshm tidy xmlrpc xsl zend_test
  not loadable in both, left out: pdo_firebird snmp
  official php -v: PHP 7.4.33 (cli) (built: Nov  2 2022 15:06:48) ( NTS Visual C++ 2017 x64 )
  patched php -v: PHP 7.4.33-cve2026 (cli) (built: Oct 22 2026 15:28:00) ( NTS Visual C++ 2017 x64 )

Targeted tests (tests\*.phpt):
  official 2 of 5 passed; failed: cve2026_memory_limit_exit.phpt, cve2026_multipart_body_parts.phpt, cve2026_session_upload_progress.phpt
  patched  5 of 5 passed
```

That is the expected result: the official build fails the 3 tests that check the fix, and
the patched build passes all 5.

`pdo_firebird` and `snmp` were left out because they didn't load in at least one build;
both need client DLLs that aren't in the zip. Check them on the target server if it uses
them.

### Full test pack

`compare.ps1` without `-TargetedOnly` runs php.net's `php-test-pack-7.4.33.zip` (`ext`,
`Sapi`, `tests`, `Zend`) against both builds. `-Jobs 8` was used on a machine with 16
logical CPUs and 8 GB RAM; more jobs risk memory-hungry tests failing on one side only.

```sh
env -u NoDefaultCurrentDirectoryInExePath powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\path\to\php-legacy-windows-builds\compare.ps1' -Version 7.4 -Flavor NTS -Jobs 8
```

About 1.5 hours: 45 minutes for the official build, 48 for the patched one.

```
Test pack (ext, Sapi, tests, Zend):
  official: Tests skipped : 2907 ( 18.1%) --------; Tests failed : 61 ( 0.4%) ( 0.5%); Tests passed : 13096 ( 81.3%) ( 99.2%)
  patched: Tests skipped : 2907 ( 18.1%) --------; Tests failed : 72 ( 0.4%) ( 0.5%); Tests passed : 13085 ( 81.3%) ( 99.2%)
  failing in both builds: 61 (not a difference)

Failing only with the patches, expected (9 of 9):
  ext/session/tests/rfc1867.phpt
  ext/session/tests/rfc1867_inter.phpt
  ext/session/tests/rfc1867_sid_cookie.phpt
  ext/session/tests/rfc1867_sid_get.phpt
  ext/session/tests/rfc1867_sid_get_2.phpt
  ext/session/tests/rfc1867_sid_invalid.phpt
  ext/session/tests/rfc1867_sid_only_cookie.phpt
  ext/session/tests/rfc1867_sid_post.phpt
  tests/lang/bug45392.phpt

Failing only with the patches, NOT expected (2) - look at the .diff next to each test in C:\php-sdk\compare\7.4-NTS\tests-patched:
  ext/com_dotnet/tests/bug73679.phpt
  ext/com_dotnet/tests/bug77177.phpt

Failing only on the official build (0):
```

All 9 expected changes, and nothing fails only on the official build. The 2 unexpected
failures both fail with `Class 'DOTNET' not found`. That comes from the build environment,
not the patch.

### No `DOTNET` class with VS2017 Build Tools

`ext/com_dotnet/config.w32` only defines `HAVE_MSCOREE_H`, which compiles in the `DOTNET`
class, when configure finds the .NET Framework SDK header `mscoree.h`. In this run it didn't:

```
Checking for mscoree.h ...  <not found>
```

| | Official 7.4.33 | This build |
|---|---|---|
| `COM`, `VARIANT` | yes | yes |
| `DOTNET` | yes | **no** |

The machine had the .NET Framework 4.8 and 4.8.1 SDKs, from a newer Visual Studio. VS2017's
`Common7\Tools\vsdevcmd\ext\netfxsdk.bat` only looks for the 4.6.1 and 4.6 SDKs in the
registry, so `NETFXSDKDir` stays empty and no .NET SDK path reaches `INCLUDE`. Installing
VS2017 Build Tools with `--includeRecommended` (section 2) doesn't add a .NET Framework SDK.

This only matters to code that uses `new DOTNET(...)`; `COM` objects are unaffected. To get
`DOTNET`, there are two options. **Neither was tested here.**

- Install the .NET Framework 4.6.1 SDK component in VS2017 Build Tools.
- Put a newer SDK's `Include\um` on `INCLUDE` before running `build.ps1`. com_dotnet only
  checks for the header and links no .NET library, and VS2017's environment scripts prepend
  to an existing `INCLUDE`.

Either way, check that configure reports `Checking for mscoree.h ... <found>`, and that
`php -n -d extension_dir=ext -d extension=php_com_dotnet.dll -r 'var_dump(class_exists("DOTNET"));'` prints
`bool(true)`.

## 8. `build.ps1` fix

Commit `c88c8f4` on branch `fix-sdk-2.2.0-deps` changes `build.ps1` so 5a and 5b need no
manual steps:

- **5a.** Right after the SDK is cloned, it applies both `Config.php` changes: trim the
  version, drop the `/` from the pattern. It runs on every build, so an SDK cloned by an
  older `build.ps1` is fixed too, and prints `Fixing <Root>\lib\php\libsdk\SDK\Config.php
  for downloads.php.net` when it changes the file. If the file doesn't look like 2.2.0's
  afterwards, it warns that `phpsdk_deps` may fail instead of failing silently.
- **5b.** `build-task.cmd` starts with `set "NoDefaultCurrentDirectoryInExePath="` inside
  its `setlocal`, so the variable is cleared for the build's own commands only.

Tested with a fresh root, from a shell with `NoDefaultCurrentDirectoryInExePath=1` still
set:

```sh
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\path\to\php-legacy-windows-builds\build.ps1' -Version 7.4 -Flavors NTS -Root 'C:\php-sdk-test'
```

```
Cloning php-sdk-2.2.0 into C:\php-sdk-test
Fixing C:\php-sdk-test\lib\php\libsdk\SDK\Config.php for downloads.php.net
Configuration: 7.4-vc15-x64-stable
Updates performed successfully.
===== Configuring PHP 7.4 NTS =====
===== Building PHP 7.4 NTS =====
PHP 7.4 done:
  C:\php-sdk-test\dist\php-7.4.33-cve2026-nts-Win32-vc15-x64.zip
```

About 13 minutes, including the SDK clone and dependency download. The fixed `Config.php` was
byte-identical to the one fixed by hand in 5a. `php -v` reports
`PHP 7.4.33-cve2026 (cli) ... ( NTS Visual C++ 2017 x64 )`. Errors, compiler warnings
(1,599, same codes and counts) and configure warnings (13) match the hand-fixed build in
section 6.

Not changed: the SDK version (a newer php-sdk-binary-tools tag that still supports VC15
would be an alternative), and `compare.ps1`. It was only run with
`NoDefaultCurrentDirectoryInExePath` cleared (section 7), not tested with it set.
