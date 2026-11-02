#!/bin/bash
# Rebuild PHP packages for Ubuntu 18.04 (bionic), or 20.04 (focal) with UBUNTU=20.04, with
# the fix for CVE-2026-109618 and CVE-2026-109619, in Docker:
#   php7.2        Ubuntu's own 7.2.24-0ubuntu0.18.04.17 + php7.2-CVE-2026-109618_CVE-2026-109619.patch
#                 -> 7.2.24-0ubuntu0.18.04.17+cve2026.1, installs over the stock packages
#   php7.4        deb.sury.org's 1:7.4.33-31 (already fixed), rebuilt unchanged for 18.04/20.04
#                 -> 1:7.4.33-31+ubuntu18.04.1+cve2026.1 (or +ubuntu20.04.1+cve2026.1), installs
#                 over deb.sury.org's 18.04/20.04 packages
#   php8.2        deb.sury.org's 8.2.35-1 (upstream 8.2.35, with the complete fix), rebuilt
#                 unchanged for 18.04 -> 8.2.35-1+ubuntu18.04.1+cve2026.1
#   php-defaults  deb.sury.org's php-common & co., which php7.4 and php8.2 from deb.sury.org
#                 need (machines that already run them from deb.sury.org have it)
#   php-apcu      deb.sury.org's APCu 5.1.22+4.0.11-2, rebuilt unchanged for php7.4 only, against
#                 the php7.4 packages built here (build php7.4 and php-defaults first)
#
# php7.2 is for 18.04 only (20.04 never had it).
#
# usage: ubuntu-18.04/build.sh [php7.2] [php7.4] [php8.2] [php-defaults] [php-apcu]
#                                                     (default: all but php-apcu)
#        UBUNTU=20.04 ubuntu-18.04/build.sh [php7.4] [php8.2] [php-defaults] [php-apcu]
#                                                     (default: php7.4 php-defaults php-apcu)
# Output: ubuntu-18.04/out/<source package>/*.deb (out-20.04/ for 20.04), plus build logs.
# Works from Linux or Git Bash on Windows (Docker Desktop). Needs docker.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
UBUNTU=${UBUNTU:-18.04}
case $UBUNTU in
  18.04) CODENAME=bionic; out=$here/out; default="php7.2 php7.4 php8.2 php-defaults" ;;
  20.04) CODENAME=focal; out=$here/out-20.04; default="php7.4 php-defaults php-apcu" ;;
  *) echo "UBUNTU must be 18.04 or 20.04" >&2; exit 2 ;;
esac
mkdir -p "$out"
hostpath() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }

SUFFIX=+cve2026.1
SURY_POOL=https://ppa.launchpadcontent.net/ondrej/php/ubuntu/pool/main/p
SURY_KEY=6A1AAD7AE5B401C6E259A7B257067BAA1314C7FC   # key that signs deb.sury.org's .dsc files (Oct 2026)
# Sources to rebuild. Launchpad drops superseded versions from the pool after a while:
# override these if a newer upload replaced them.
PHP74_DSC=${PHP74_DSC:-php7.4/php7.4_7.4.33-31+ubuntu22.04.1+deb.sury.org+1.dsc}
PHP82_DSC=${PHP82_DSC:-php8.2/php8.2_8.2.35-1+ubuntu22.04.1+deb.sury.org+1.dsc}
DEFAULTS_DSC=${DEFAULTS_DSC:-php-defaults/php-defaults_101~+ubuntu22.04.1+deb.sury.org+1.dsc}
APCU_DSC=${APCU_DSC:-php-apcu/php-apcu_5.1.22+4.0.11-2+ubuntu22.04.1+deb.sury.org+1.dsc}
DHPHP_DSC=${DHPHP_DSC:-../d/dh-php/dh-php_5.21+ubuntu22.04.1+deb.sury.org+1.dsc}   # build tool for php-apcu
UBUNTU_PHP72=7.2.24-0ubuntu0.18.04.17

packages=${*:-$default}

# Runs inside ubuntu:$UBUNTU. $1 = source package. /in = this directory, /out = output.
read -r -d '' builder <<'SCRIPT' || true
set -euo pipefail
pkg=$1
export DEBIAN_FRONTEND=noninteractive DEBEMAIL=builder@localhost DEBFULLNAME="Local rebuild"
sed -i 's/^# deb-src/deb-src/' /etc/apt/sources.list
apt-get update -qq
apt-get install -y -qq --no-install-recommends build-essential devscripts equivs quilt gnupg dirmngr ca-certificates curl xz-utils > /dev/null
mkdir -p /build && cd /build

fetch_sury() {   # $1 = pool path of the .dsc; downloads it and the files it lists
  local dsc=$1 dir=${1%/*}
  curl -fsSL -o "${dsc##*/}" "$SURY_POOL/$dsc"
  awk '/^Files:/{f=1;next} /^[^ ]/{f=0} f{print $3}' "${dsc##*/}" | while read -r f; do
    curl -fsSL -o "$f" "$SURY_POOL/$dir/$f"
  done
  if gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$SURY_KEY" > /dev/null 2>&1 \
     && gpg --batch --verify "${dsc##*/}" > /dev/null 2>&1; then
    echo "${dsc##*/}: valid signature from $SURY_KEY"
    # dpkg-source checks again with gpgv, which reads trustedkeys.gpg only.
    gpg --batch --export "$SURY_KEY" | gpg --batch --no-default-keyring --keyring trustedkeys.gpg --import > /dev/null 2>&1 || true
  else
    echo "WARNING: ${dsc##*/}: signature not verified (key $SURY_KEY unavailable or no match); only the checksums are checked"
  fi
  dpkg-source -x "${dsc##*/}" src   # checks the files against the checksums in the .dsc
}

entry() {   # $1 = package, $2 = version, $3 = text: prepends a debian/changelog entry
  { printf '%s (%s) %s; urgency=high\n\n%s\n\n -- %s <%s>  %s\n\n' "$1" "$2" "$CODENAME" "$3" "$DEBFULLNAME" "$DEBEMAIL" "$(date -R)"
    cat debian/changelog; } > /tmp/changelog
  mv /tmp/changelog debian/changelog
}

case $pkg in
  php7.2)
    [ "$UBUNTU" = 18.04 ] || { echo "php7.2 is for Ubuntu 18.04 only" >&2; exit 2; }
    apt-get source -qq "php7.2=$UBUNTU_PHP72" > /dev/null   # from the signed Ubuntu archive
    mv php7.2-7.2.24 src && cd src
    cp /in/php7.2-CVE-2026-109618_CVE-2026-109619.patch debian/patches/CVE-2026-109618_CVE-2026-109619.patch
    echo CVE-2026-109618_CVE-2026-109619.patch >> debian/patches/series
    entry php7.2 "$UBUNTU_PHP72$SUFFIX" "  * SECURITY UPDATE: state corruption via bailout
    - debian/patches/CVE-2026-109618_CVE-2026-109619.patch: backport of the
      PHP 7.4 fix; also regenerates Zend/zend_vm_execute.h.
    - CVE-2026-109618
    - CVE-2026-109619"
    ;;
  php7.4|php8.2)
    if [ "$pkg" = php7.4 ]; then dsc=$PHP74_DSC; else dsc=$PHP82_DSC; fi
    fetch_sury "$dsc" && cd src
    v=$(dpkg-parsechangelog -S Version | sed 's/+ubuntu[0-9.]*+deb\.sury\.org+[0-9]*$//')
    entry "$pkg" "$v+ubuntu$UBUNTU.1$SUFFIX" "  * No-change rebuild for Ubuntu $UBUNTU of $v from deb.sury.org,
    which includes the fix for CVE-2026-109618 and CVE-2026-109619."
    ;;
  php-defaults)
    fetch_sury "$DEFAULTS_DSC" && cd src
    v=$(dpkg-parsechangelog -S Version | sed 's/+ubuntu[0-9.]*+deb\.sury\.org+[0-9]*$//')
    entry php-defaults "$v+ubuntu$UBUNTU.1$SUFFIX" "  * No-change rebuild for Ubuntu $UBUNTU of $v from deb.sury.org."
    ;;
  php-apcu)
    # Build-depends on dh-php (built here from its source, not shipped) and php-all-dev (every
    # PHP version): use our php7.4-dev instead, so dh-php builds the extension for 7.4 only.
    apt-get install -y -qq --no-install-recommends /out/php-defaults/php-common_*.deb \
      /out/php7.4/php7.4-{common,cli,json,opcache,readline,dev}_*.deb > /dev/null
    mkdir dh-php && (cd dh-php && fetch_sury "$DHPHP_DSC" && cd src \
      && mk-build-deps -i -r -t 'apt-get -y -qq --no-install-recommends' debian/control > /dev/null \
      && dpkg-buildpackage -b -uc -us > /dev/null && apt-get install -y -qq --no-install-recommends ../dh-php_*.deb > /dev/null)
    mkdir apcu && cd apcu && fetch_sury "$APCU_DSC" && cd src
    sed -i 's/php-all-dev/php7.4-dev/' debian/control debian/control.in
    v=$(dpkg-parsechangelog -S Version | sed 's/+ubuntu[0-9.]*+deb\.sury\.org+[0-9]*$//')
    entry php-apcu "$v+ubuntu$UBUNTU.1$SUFFIX" "  * No-change rebuild for Ubuntu $UBUNTU of $v from deb.sury.org, for PHP 7.4 only."
    ;;
  *) echo "unknown package $pkg" >&2; exit 2 ;;
esac

mk-build-deps -i -r -t 'apt-get -y -qq --no-install-recommends' debian/control > /dev/null
DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -uc -us
mkdir -p "/out/$pkg" && cp ../*.deb "/out/$pkg/"
SCRIPT

rel=ubuntu-18.04/${out##*/}   # for messages
for pkg in $packages; do
  echo "===== $pkg for Ubuntu $UBUNTU (log: $rel/$pkg.log)"
  MSYS_NO_PATHCONV=1 docker run --rm \
    -e SUFFIX="$SUFFIX" -e SURY_POOL="$SURY_POOL" -e SURY_KEY="$SURY_KEY" -e UBUNTU="$UBUNTU" -e CODENAME="$CODENAME" \
    -e PHP74_DSC="$PHP74_DSC" -e PHP82_DSC="$PHP82_DSC" -e DEFAULTS_DSC="$DEFAULTS_DSC" -e UBUNTU_PHP72="$UBUNTU_PHP72" \
    -e APCU_DSC="$APCU_DSC" -e DHPHP_DSC="$DHPHP_DSC" \
    -v "$(hostpath "$here"):/in:ro" -v "$(hostpath "$out"):/out" \
    "ubuntu:$UBUNTU" bash -c "$builder" builder "$pkg" > "$out/$pkg.log" 2>&1 \
    && echo "  $(ls "$out/$pkg" | wc -l) packages in $rel/$pkg" \
    || { echo "  FAILED, see $rel/$pkg.log"; exit 1; }
done
