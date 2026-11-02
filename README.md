# Legacy PHP Windows builds: CVE-2026-109618 / CVE-2026-109619

Patches and scripts to build **PHP 5.6, 7.0, 7.2, 7.3 and 7.4 for Windows** (and fixed
`.deb` packages of php7.2, php7.4 and php8.2 for Ubuntu 18.04, and php7.4 with APCu for 20.04) with the
fixes for the two critical remote code execution bugs announced on
[21 October 2026](https://www.php.net/archive/2026.php#2026-10-21-5):

- [CVE-2026-109618](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w): RCE via OOM corruption
- [CVE-2026-109619](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp): RCE via stale global state

php.net only released fixed builds for 8.2 and later, and Windows binaries for
nothing older. These versions are end of life: this is a stopgap to keep legacy
applications running while they are migrated, not a supported PHP.

**PHP 5.2.17** (Visual C++ 6.0, core only, with a wider set of security backports) is in
[`php52/`](php52/README.md).

## What is in the patches

| Version | Base tag | Patches | Source of the CVE fix |
|---|---|---|---|
| 7.4 | `php-7.4.33` | 1 | The PHP security team's backport, [`712e60f`](https://github.com/php/php-src/commit/712e60f9edfd03f0960fc4fc3c2c375f42b90aa2), applied to the 7.4.33 tag |
| 7.3 | `php-7.3.33` | 3 | Freexian ELTS backport (Debian `php7.3 7.3.31-1~deb10u16`), context adjusted for upstream 7.3.33 |
| 7.2 | `php-7.2.34` | 4 | Ported here from the 7.4 fix, using the 7.3 and 7.0 ELTS backports as references (patch 0004 only makes the packaging script run on the SDK's PHP 8) |
| 7.0 | `php-7.0.33` | 3 | Freexian ELTS backport (Debian `php7.0 7.0.33-0+deb9u26`), context adjusted for upstream 7.0.33 |
| 5.6 | `php-5.6.40` | 3 | Ported here from the 7.4 fix, following the 7.0 backport where the engines are alike; C89 for VS2012 (patch 0003 only fixes packaging of in-tree x64 builds) |

5.6 through 7.3 also get two prerequisites from the Freexian ELTS packages:
`max_multipart_body_parts` (CVE-2023-0662, which these versions never received
upstream and which the fix relies on), and, for 7.x, the `ZSTR_MAX_LEN` macro.
Each patch's commit message lists its origin and every deviation from the 7.4 fix.

Cross-checked against the independent backports in deb.sury.org's packages (21-22
October 2026): the 7.3 (`7.3.33-35`), 7.2 (`7.2.34-66`) and 7.0 (`7.0.33-92`) fixes change
exactly the same code lines, including the generated `zend_vm_execute.h`; the only
difference is an equivalent `(unsigned char)` cast in `rfc1867.c`. The 5.6 fix
(`5.6.40-105`) follows the same design; ours adds the VS2012 handling and took over his
reset of `SG(callback_func)`. His 5.6 multipart limit lacks the second half of the
upstream CVE-2023-0662 fix (empty file uploads counting against `max_file_uploads`),
which ours has.

## Behaviour changes to know before deploying

These come from the upstream fix itself and are the same on every version:

- **Hitting `memory_limit` ends the process.** "Allowed memory size exhausted", out of
  memory and allocation overflow errors are written to stderr and the process exits
  with code 1. Shutdown functions, destructors and output buffer flushing no longer
  run after such an error, and the client gets no response body.
  - **Apache `mod_php` on Windows** (`mpm_winnt`) runs every request in one child
    process, so one request hitting the memory limit takes down every request in
    flight while Apache restarts the child. Prefer FastCGI (IIS, or Apache with
    `mod_fcgid`) with the NTS build, where only one `php-cgi` process dies.
- **Session upload progress is disabled**, whatever `session.upload_progress.enabled` says.
- **`max_multipart_body_parts`** (new INI setting, default `-1` =
  `max_input_vars + max_file_uploads`) limits the parts of a multipart request.
- Multipart parts keep only their `Content-Disposition` and `Content-Type` headers,
  and the first of each; nothing in PHP used the others.

The advisory's mitigations are still worth applying, in `php.ini` or the server
config (not `.user.ini`): `session.upload_progress.enabled=0`, a modest
`post_max_size`, and request size limits at the web server or proxy.

## Building on Windows

Requirements per version (they can all live on one machine):

| Version | Compiler | Install |
|---|---|---|
| 7.2, 7.3, 7.4 | VC15 | Visual Studio 2017 with *Desktop development with C++* |
| 7.0 | VC14 | Visual Studio 2015, or VS2017's *VC++ 2015.3 v14.00 (v140) toolset for desktop* component |
| 5.6 | VC11 | Visual Studio 2012, Update 5 (Express for Windows Desktop is enough) |

Plus Git and internet access (github.com, windows.php.net, downloads.php.net).

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Version all
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Version 7.3,7.2 -Flavors TS
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Version 7.0 -Vc14WithVs2017
```

For each version the script clones the release tag, applies `patches\<version>`,
sets the version to e.g. `7.3.33-cve2026`, fetches the official dependency
libraries, and runs `configure --enable-snapshot-build` (every extension the
dependencies support, shared where possible), `nmake` and `nmake snap` for each
flavor. Packages land in `C:\php-sdk\dist`:

- `php-<version>-Win32-<vc>-x64.zip`: thread-safe, for Apache `mod_php`
- `php-<version>-nts-Win32-<vc>-x64.zip`: non-thread-safe, for IIS/FastCGI and `php-cgi`

`-Vc14WithVs2017` builds 7.0 with the VS2017 compiler when the VC14 toolset is
missing. The output links the same `vcruntime140`, but PHP 7.0 labels the compiler
"untested" and its API ID differs from official VC14 builds, which only matters for
loading separately built PECL DLLs.

Then check `php -v` shows the `-cve2026` suffix and compare `php -m` with the server
you are replacing.

> `build.ps1` has not yet been run end to end on Windows: the patches were validated
> on Linux (below). Expect the first run of each toolchain, 5.6 and 7.0 especially,
> to need small fixes.

### Comparing a build with the official one

`compare.ps1` checks a build from `build.ps1` against php.net's official build of the
same release, with php.net's own test pack:

```powershell
powershell -ExecutionPolicy Bypass -File .\compare.ps1 -Version 7.3 -TargetedOnly   # about a minute
powershell -ExecutionPolicy Bypass -File .\compare.ps1 -Version all -TargetedOnly   # every version built so far
powershell -ExecutionPolicy Bypass -File .\compare.ps1 -Version 7.3                 # full test pack, hours
powershell -ExecutionPolicy Bypass -File .\compare.ps1 -Version 7.4 -Jobs 8 -Flavor NTS
```

It downloads the official zip and test pack, enables in both builds the extensions that
load cleanly in both (the same `php.ini` for each), runs the targeted tests (the official
build fails the 3 that check the fix, the patched one must pass all 5), then the test pack
against each build. The report, `C:\php-sdk\compare\<version>-<flavor>\report.txt`, lists
the tests failing on one side only. Expect exactly the 9 tests the fix changes (the 8
`ext/session/tests/rfc1867*` tests and `tests/lang/bug45392.phpt`); anything else is worth
a look at its `.diff`. `-TestDirs Zend,tests,ext\standard` runs a subset. A watchdog kills
stuck PHP processes when no test finishes for 15 minutes (`-StallMinutes`): some server
tests (e.g. `ext\openssl`) can otherwise block a run on Windows forever.

### OpenSSL and other bundled libraries

The official dependency sets are as old as these PHP versions:

| Version | OpenSSL | DLLs |
|---|---|---|
| 7.4 / 7.3 / 7.2 | 1.1.1s / 1.1.1l / 1.1.1g | `libcrypto-1_1-x64.dll`, `libssl-1_1-x64.dll` |
| 7.0, 5.6 | 1.0.2q | `libeay32.dll`, `ssleay32.dll` |

For 7.2-7.4 the two OpenSSL DLLs can be replaced next to `php.exe` with any
OpenSSL 1.1.1 build, e.g. FireDaemon's signed 1.1.1w (the last public 1.1.1).
With Apache `mod_php`, the copy Apache loads first wins: update `Apache24\bin` too
if it ships `*-1_1-x64.dll`. `php -i` then shows the new *OpenSSL Library Version*.
5.6 and 7.0 would need a 1.0.2 build (1.0.2u was the last public one).

## Ubuntu 18.04 and 20.04 packages

For 18.04 machines without Ubuntu Pro, `ubuntu-18.04/` rebuilds fixed `.deb` packages in
Docker, as drop-in upgrades of what those machines run:

| Machines running | Rebuilt from | New version |
|---|---|---|
| stock Ubuntu php7.2 (`7.2.24-0ubuntu0.18.04.17`) | Ubuntu's own source + `ubuntu-18.04/php7.2-CVE-2026-109618_CVE-2026-109619.patch` | `7.2.24-0ubuntu0.18.04.17+cve2026.1` |
| php7.4 from deb.sury.org (`1:7.4.33-5+ubuntu18.04.1+deb.sury.org+1` or similar) | deb.sury.org's `1:7.4.33-31`, which already has the fix, unchanged | `1:7.4.33-31+ubuntu18.04.1+cve2026.1` |
| php8.2 from deb.sury.org (`8.2.6-1+ubuntu18.04.1+deb.sury.org+1` or similar) | deb.sury.org's `8.2.35-1`: upstream 8.2.35, with the complete fix, unchanged | `8.2.35-1+ubuntu18.04.1+cve2026.1` |
| (dependency of the above) | deb.sury.org's `php-defaults` (`php-common`) | `2:101~+ubuntu18.04.1+cve2026.1` |

```bash
ubuntu-18.04/build.sh            # all four, ~1.5 hours; packages in ubuntu-18.04/out/<source>/
ubuntu-18.04/test.sh php7.2      # ours vs stock Ubuntu
ubuntu-18.04/test.sh php7.4      # ours vs deb.sury.org's build of the same source on 22.04
ubuntu-18.04/test.sh php8.2      # likewise
```

**Ubuntu 20.04:** deb.sury.org no longer builds for 20.04 either, so the same scripts with
`UBUNTU=20.04` rebuild, into `ubuntu-18.04/out-20.04/`, for 20.04 machines that run php7.4
from deb.sury.org. That includes machines upgraded in place from 18.04 that still run its
18.04 builds (`1:7.4.33-5+ubuntu18.04.1+deb.sury.org+1` and the like), whose packages
still link against 18.04 libraries:

| Package | Rebuilt from | New version |
|---|---|---|
| php7.4 | deb.sury.org's `1:7.4.33-31`, unchanged | `1:7.4.33-31+ubuntu20.04.1+cve2026.1` |
| php7.4-apcu | deb.sury.org's `php-apcu` `5.1.22+4.0.11-2`, unchanged, built for 7.4 only against the php7.4 above | `5.1.22+4.0.11-2+ubuntu20.04.1+cve2026.1` |
| php-common | deb.sury.org's `php-defaults` | `2:101~+ubuntu20.04.1+cve2026.1` |

APCu itself has no change for the CVEs (the fix is in PHP); it is rebuilt so that a 20.04
machine gets it built for 20.04, as deb.sury.org's 20.04 and 18.04 builds are gone.
(Ubuntu's own 20.04 php7.4, `7.4.3-4ubuntu2.*`, is not covered.)

```bash
UBUNTU=20.04 ubuntu-18.04/build.sh             # php7.4, php-defaults, then php-apcu (~40 min)
UBUNTU=20.04 ubuntu-18.04/test.sh php7.4       # ours on 20.04 vs deb.sury.org's on 22.04
```

Ubuntu's source comes from the signed 18.04 archive; deb.sury.org's from its Launchpad
PPA, with the `.dsc` signature and checksums verified. The 7.2 patch is the same fix as
`patches/7.2`, adapted to Ubuntu's 7.2.24 tree (see its header): Ubuntu had already
backported `max_multipart_body_parts` and `ZSTR_MAX_LEN`, and `zend_vm_execute.h` is
regenerated, which also repairs Ubuntu's 2017 concat check that had landed in the wrong
handlers.

The versions sort above what is installed, and below a later official update (Ubuntu
Pro's `+esm` builds, a deb.sury.org build of the same release), which then replaces them.
To install, copy `out/php7.2` (or `out/php7.4`; on 20.04 `out-20.04/php7.4` plus
`out-20.04/php-apcu/php7.4-apcu_*.deb`, in one directory) to the machine and upgrade only
the PHP packages already installed:

```bash
cd php7.2 && sudo apt install --no-install-recommends $(for p in $(dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 'php7.2*' 'libapache2-mod-php7.2' 'libphp7.2-embed' 2>/dev/null | awk '$1 == "ii" {print $2}'); do ls ./${p}_*.deb 2>/dev/null; done)
```

For php7.4 and php8.2 the same with `7.4` or `8.2`; add `../php-defaults/php-common_*.deb`
only if `apt` asks for a newer `php-common`. Then restart PHP-FPM or Apache.
The `ii` filter matters: `dpkg-query -W` also lists packages dpkg only knows of (removed,
or never installed), and without it the command would install them, `php7.2-fpm` for
instance. `--no-install-recommends` keeps apt from adding recommended packages
(`pkg-php-tools` for `php7.4-dev` on 20.04).

A machine with only `php8.2-common` and `php8.2-xml` (pulled in by deb.sury.org's `php-xml`
metapackage) has no PHP 8.2 that can run, so nothing exposed; upgrading them is harmless.

**APCu and the 5.6-7.4 fix:** `apcu_entry()` runs its callback, and `apcu_cache_info()`
builds its result, while holding APCu's lock in shared memory. If either hits
`memory_limit`, the process now exits with the lock held and the other Apache/FPM
processes block on their next APCu call; only a full restart (not a graceful reload)
clears it. Plain `apcu_fetch()` / `apcu_store()` are not affected. This comes with the
minimal mitigation itself (also in the Debian and Ubuntu 7.x packages), not with 8.2.35's
complete fix. APCu 5.1.22 itself was checked against the rebuilt php7.4: its own test
suite passes (58/58).

Results (22 October 2026):

- php7.2: passes the 5 targeted tests (stock Ubuntu fails 2; it already had the
  multipart limit). PHP's test suites, 6,900 tests: the 9 expected failures more than
  stock, nothing else.
- php7.4: passes the 5 targeted tests and fails exactly the same suite tests as
  deb.sury.org's own build of `-31` on 22.04 (29, environment related).
- php8.2: the same targeted and suite results as deb.sury.org's own build of `8.2.35-1`
  on 22.04 (8,165 passed, the same 12 failures). 8.2.35 has the complete upstream fix,
  so 2 of the targeted tests, which describe the minimal 5.6-7.4 mitigation, fail on both
  by design: memory exhaustion is handled gracefully (shutdown functions still run), and
  session upload progress is fixed rather than disabled.

Results (2 November 2026):

- php7.4 for 20.04: passes the 5 targeted tests and fails exactly the same suite tests
  as deb.sury.org's own build of `-31` on 22.04 (6,889 passed, the same 29 failures).
- php7.4-apcu for 20.04: APCu 5.1.22's own test suite passes (58/58; 3 of its tests
  start a separate `php -n` server that loads APCu from a source tree's `modules/`, so
  they need that directory pointed at `/usr/lib/php/20190902`).
- Upgrade of a 20.04 machine running deb.sury.org's 18.04 builds (php7.4 `-5` with
  Apache, apcu, pear, `php-xml`/`php8.2-xml`; recreated with stand-in packages, since
  those builds can no longer be downloaded): the 15 php7.4 packages upgrade, nothing is
  removed, `php-common` 2:93 is enough and stays, `mod_php` serves 7.4.33 with APCu shared
  across requests.
- Upgrade of a stock 18.04 php7.2 machine (Apache, the `php` metapackages, pear,
  phpMyAdmin 4.6.6) from the Ubuntu archive with the release packages: the 15 php7.2
  packages upgrade, nothing is added or removed, phpMyAdmin's login page loads.

## Validation

`validate/` builds each release tag with and without its patches on Linux
(Docker, Debian 9 toolchain, minimal extensions), then runs PHP's own test suites
(`Zend`, `tests`, `ext/session`, `ext/standard`) and the targeted tests in `tests/`.

```bash
validate/validate.sh                 # all versions, ~30 minutes
QUICK=1 validate/validate.sh 7.3     # targeted tests only
```

Results when the patches were written (21 October 2026):

- All patched builds compile; regenerating `zend_vm_execute.h` from `zend_vm_def.h`
  gives back the patched file.
- PHP's test suites (5,700-7,000 tests per version): every patched version fails the
  same 9 tests more than its base tag, all expected:
  the 8 `ext/session/tests/rfc1867*` upload progress tests, and `tests/lang/bug45392.phpt`
  (output buffered before a memory limit error is no longer flushed).
- Each patched version is also built thread-safe, as on Windows (`zts` in the output):
  the targeted tests must pass there too, and integer/pointer argument mix-ups in the
  compiler warnings are flagged. This caught a missing `TSRMLS_CC` in the 5.6 backport of
  CVE-2023-0662 that only crashed thread-safe builds.
- 5.6 and 7.2, the ports done here, were also run as debug builds (internal assertions
  and hash table consistency checks): no additional failures.
- `tests/`: every base tag fails the 3 tests of the fix (memory limit exit, session
  upload progress, multipart part limit) and passes the 2 behaviour tests (multipart
  headers, nested input arrays); every patched build passes all 5.

## Not covered

- **Other vulnerabilities fixed after these versions' end of life.** The Debian ELTS
  packages carry many more (e.g. CVE-2026-7258, out-of-bounds read in `urldecode()`);
  their `debian/patches` are a good source for further backports.
- The bundled libraries (OpenSSL, curl, libxml2, ...) beyond the DLL swap above.
- PHP 7.1 (no patches here; it sits between the 7.0 and 7.2 ports).

## Layout

```
build.ps1           Windows build for all versions
compare.ps1         patched build vs official build, with the official test pack
patches/<version>/  git format-patch series, applied in name order
tests/              targeted .phpt tests for the fix
ubuntu-18.04/       .deb rebuilds for Ubuntu 18.04 and 20.04 (build.sh, test.sh, the 7.2 patch)
validate/           Linux validation (Dockerfile, ci.sh, validate.sh, run-targeted.sh)
php52/             PHP 5.2.17 + backports: VC6 build kit, patches, tests, validation
```

## Credits

The fix is by Arnaud Le Blanc and Ilija Tovilo (PHP security team). The 7.3 and 7.0
backports and the CVE-2023-0662 and `ZSTR_MAX_LEN` patches are by Guilhem Moulin
and Markus Koschany for Debian ELTS / Freexian. The patches are derived from PHP and
are under the [PHP License 3.01](https://www.php.net/license/3_01.txt).
