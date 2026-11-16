# Building PHP 7.4 (NTS, x64) on Windows with VS2017 Build Tools

Notes from building and comparing **PHP 7.4.33 NTS x64** with `build.ps1` and
`compare.ps1` on Windows 11 (22 October 2026). They cover what the README's
[Building on Windows](../README.md#building-on-windows) section leaves out: which Visual
Studio install the PHP SDK finds, how to check it beforehand, and why a VS2017 Build Tools
build lacks the `DOTNET` class.

Result: the patched build shows exactly the 9 expected differences from the official build
on php.net's full test pack, plus 2 `com_dotnet` tests that fail because the build has no
`DOTNET` class ([No `DOTNET` class](#no-dotnet-class-with-vs2017-build-tools)).

## Toolchain

7.2-7.4 build with VC15. `build.ps1` starts the compiler through the PHP SDK 2.2.0 starter
`phpsdk-vc15-x64.bat`, whose `bin\phpsdk_setshell.bat` looks for Visual Studio with:

```
vswhere -version [15,16) -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64
```

So it needs an actual **VS 15.x (2017)** instance; a newer Visual Studio with the v141
toolset added is not found. The smallest install that works is VS2017 Build Tools
(https://aka.ms/vs/15/release/vs_buildtools.exe, about 5 GB, side by side with newer Visual
Studio versions), from an elevated prompt:

```bat
vs_buildtools.exe --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive --norestart
```

`--includeRecommended` adds the VC++ 2017 x86/x64 tools and a Windows 10 SDK (10.0.19041
here), but no .NET Framework SDK; see [No `DOTNET` class](#no-dotnet-class-with-vs2017-build-tools).

Check it the way the SDK will. `phpsdk_setshell.bat` first queries without `-products`,
which only lists Community/Professional/Enterprise and misses Build Tools; its second query
adds `-products Microsoft.VisualStudio.Product.BuildTools`. Query the same way:

```sh
"/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe" -nologo -version "[15,16)" -products Microsoft.VisualStudio.Product.BuildTools -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath -format text
```

```
installationPath: C:\Program Files (x86)\Microsoft Visual Studio\2017\BuildTools
```

The SDK also requires `Windows.h` under
`C:\Program Files (x86)\Windows Kits\10\Include\<version>\um\`. To confirm the compiler
starts, from a `.cmd` file:

```bat
@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2017\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" amd64 >nul || exit /b 1
cl 2>&1 | findstr /i "Version"
echo WindowsSdkVersion=%WindowsSdkVersion%
where nmake
```

This run used Build Tools 15.9.37627.17: MSVC toolset 14.16.27023, `cl` 19.16.27054 for x64,
Windows SDK 10.0.19041.0.

## Running the scripts

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\php-legacy-windows-builds\build.ps1 -Version 7.4 -Flavors NTS
powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\php-legacy-windows-builds\compare.ps1 -Version 7.4 -Flavor NTS -Jobs 8
```

- From Git Bash, `.\build.ps1` reaches PowerShell as `.build.ps1` and fails; pass the full
  path, as above.
- On a fresh `-Root`, `build.ps1` prints `Fixing <Root>\lib\php\libsdk\SDK\Config.php for
  downloads.php.net` after cloning the SDK. That is expected: SDK 2.2.0 can't read the
  dependency listing on downloads.php.net without it.
- `-PrepareOnly` doesn't test the dependency download for 7.2-7.4: `phpsdk_deps` runs
  inside `build-task.cmd`, which a dry run doesn't execute.
- `build.log` is **UTF-16** (written by `Tee-Object` in Windows PowerShell 5.1), so plain
  `grep` finds nothing in it. Convert it first:
  `iconv -f UTF-16LE -t UTF-8 build.log | tr -d '\r' > build.log.utf8.txt`.
- `NoDefaultCurrentDirectoryInExePath=1`, which some shells and automation tools set, needs
  no workaround: `build.ps1` calls `.\buildconf.bat` and `.\configure.bat`, and
  `compare.ps1` starts PHP by full path (`-TargetedOnly` checked with it set, 16 November
  2026).

## Results

| | |
|---|---|
| Build | about 10.5 minutes (13 with a fresh `-Root`); 0 compiler, linker or `NMAKE : fatal` errors |
| Compiler warnings | 1,599, from PHP's own sources, mostly C4244/C4267 integer conversions, usual for PHP's x64 Windows builds |
| `php -n -v` | `PHP 7.4.33-cve2026 (cli) ... ( NTS Visual C++ 2017 x64 )` |
| Shared extensions | 38 in `ext\`, including `php_zend_test.dll` (PHP's test extension, from `--enable-snapshot-build`; don't enable it on a server) |
| `compare.ps1` extensions | 34 enabled in both; `pdo_firebird` and `snmp` left out (they need client DLLs that aren't in the zip) |
| Targeted tests | official 2/5, patched 5/5 |
| Full test pack, `-Jobs 8` | about 1.5 hours; failed: official 61, patched 72 |
| One side only | the 9 expected changes; 2 unexpected (`ext/com_dotnet/tests/bug73679.phpt`, `bug77177.phpt`); 0 official only |

`patches/7.4` was also compared with
[php-src `712e60f`](https://github.com/php/php-src/commit/712e60f9edfd03f0960fc4fc3c2c375f42b90aa2):
the 299 added and removed lines are identical.

The test pack was run before 01c04b7, which made `compare.ps1` list known-flaky tests
(`sapi/phpdbg/tests/watch_*.phpt`) separately. None of them failed on one side only in this
run, so the counts above are what the current script reports too; its output only gains a
`Known-flaky` section when one does.

## No `DOTNET` class with VS2017 Build Tools

Both unexpected failures fail with `Class 'DOTNET' not found`. That comes from the build
environment, not the patches.

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
registry, so `NETFXSDKDir` stays empty and no .NET SDK path reaches `INCLUDE`.

This only matters to code that uses `new DOTNET(...)`; `COM` objects are unaffected. Two ways
to get `DOTNET`, **neither tested**:

- Install the .NET Framework 4.6.1 SDK component in VS2017 Build Tools.
- Put a newer SDK's `Include\um` on `INCLUDE` before running `build.ps1`. com_dotnet only
  checks for the header and links no .NET library, and VS2017's environment scripts prepend
  to an existing `INCLUDE`.

Either way, check that configure reports `Checking for mscoree.h ... <found>`, and that
`php -n -d extension_dir=ext -d extension=php_com_dotnet.dll -r 'var_dump(class_exists("DOTNET"));'`
prints `bool(true)`.
