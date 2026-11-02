#!/bin/bash
# Test the packages from build.sh against a reference, in Docker: the targeted tests in
# tests/ and PHP's own test suites (Zend, tests, ext/session, ext/standard), then list
# the tests that fail on one side only.
#   php7.2: ours vs stock Ubuntu 7.2.24-0ubuntu0.18.04.17, both on 18.04
#   php7.4, php8.2: ours on 18.04 (or 20.04) vs deb.sury.org's build on Ubuntu 22.04 (same source)
#
# usage: ubuntu-18.04/test.sh php7.2|php7.4|php8.2   QUICK=1 for the targeted tests only
#        UBUNTU=20.04 ubuntu-18.04/test.sh php7.4|php8.2   for the 20.04 packages (out-20.04/)
# Expected: ours passes all targeted tests. php7.2 fails 9 suite tests more than stock
# Ubuntu (8 ext/session/tests/rfc1867* and tests/lang/bug45392.phpt, see README);
# php7.4 and php8.2 fail exactly the same tests as the reference. (8.2.35 has the complete
# fix, so some targeted tests, written for the minimal 5.6-7.4 mitigation, may differ.)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
proj=$(dirname "$here")
hostpath() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }
pkg=${1:?usage: test.sh php7.2|php7.4|php8.2}
UBUNTU=${UBUNTU:-18.04}
case $UBUNTU in
  18.04) out=$here/out ;;
  20.04) out=$here/out-20.04 ;;
  *) echo "UBUNTU must be 18.04 or 20.04" >&2; exit 2 ;;
esac
rel=ubuntu-18.04/${out##*/}   # for messages
res=$out/test-$pkg
mkdir -p "$res" && rm -f "${res:?}"/*   # no stale results from an earlier run

case $pkg in
  php7.2) ver=7.2; upstream=7.2.24
    ours_image=ubuntu:18.04
    ours_install="apt-get install -y -qq /debs/php7.2/php7.2-{common,cli,cgi,json,opcache,readline}_*.deb"
    ref_image=ubuntu:18.04
    ref_install="apt-get install -y -qq php7.2-cli php7.2-cgi" ;;
  php7.4|php8.2) ver=${pkg#php}
    if [ "$ver" = 7.4 ]; then upstream=7.4.33; extra=json; else upstream=8.2.35; extra=; fi
    ours_image=ubuntu:$UBUNTU
    ours_install="apt-get install -y -qq /debs/php-defaults/php-common_*.deb $(for p in common cli cgi opcache readline $extra; do printf '/debs/%s/%s-%s_*.deb ' "$pkg" "$pkg" "$p"; done)"
    ref_image=ubuntu:22.04
    ref_install="apt-get install -y -qq software-properties-common gpg-agent > /dev/null && add-apt-repository -y ppa:ondrej/php > /dev/null && apt-get update -qq && apt-get install -y -qq $pkg-cli $pkg-cgi" ;;
  *) echo "unknown package $pkg" >&2; exit 2 ;;
esac
[ -d "$out/$pkg" ] || { echo "No packages in $rel/$pkg: run build.sh $pkg first." >&2; exit 1; }

# Runs inside the container: installs PHP, gets the php.net sources for the tests, runs them.
read -r -d '' tester <<'SCRIPT' || true
set -uo pipefail
label=$1 ver=$2 upstream=$3 install=$4
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /dev/null
apt-get install -y -qq curl ca-certificates > /dev/null
bash -c "$install" > /res/$label.install.log 2>&1 || { echo "install failed, see $label.install.log"; exit 1; }
dpkg-query -W -f '${Package} ${Version}\n' 'php*' > /res/$label.packages
curl -fsSL https://www.php.net/distributions/php-$upstream.tar.gz | tar -xz -C /tmp
src=/tmp/php-$upstream
mkdir -p /tmp/t && cp /tests/*.phpt /tmp/t/
export TEST_PHP_EXECUTABLE=/usr/bin/php$ver TEST_PHP_CGI_EXECUTABLE=/usr/bin/php-cgi$ver NO_INTERACTION=1 REPORT_EXIT_STATUS=0 SKIP_ONLINE_TESTS=1
php$ver -v | head -1 > /res/$label.version
php$ver $src/run-tests.php /tmp/t > /res/$label.targeted.log 2>&1
# PHP 8 doesn't print a line per passed test: read failures from the summary sections.
for t in /tmp/t/*.phpt; do
  name=$(sed -n '2p' "$t")
  if sed -n '/^\(FAILED\|BORKED\) TEST SUMMARY/,/^=====/p' /res/$label.targeted.log | grep -qF "[$t]"; then
    echo "FAIL $name"
  elif grep -qE "^SKIP .*\[$t\]" /res/$label.targeted.log; then
    echo "SKIP $name"
  else
    echo "PASS $name"
  fi
done | sort > /res/$label.targeted
if [ "${QUICK:-0}" != 1 ]; then
  cd $src
  php$ver run-tests.php -q --offline --set-timeout 300 Zend tests ext/session ext/standard/tests > /res/$label.tests.log 2>&1
  sed -n '/^FAILED TEST SUMMARY/,/^=====/p' /res/$label.tests.log | grep -oE '\[[^]]+\.phpt\]' | tr -d '[]' | sed "s|^$src/||" | sort -u > /res/$label.fails
  grep -E '^Tests (passed|failed)' /res/$label.tests.log | tr -s ' ' > /res/$label.summary
fi
SCRIPT

for side in ours ref; do
  image=${side}_image install=${side}_install
  docker rm -f "test-$pkg-$side" > /dev/null 2>&1 || true
  MSYS_NO_PATHCONV=1 docker run -d --name "test-$pkg-$side" -e QUICK="${QUICK:-0}" \
    -v "$(hostpath "$out"):/debs:ro" -v "$(hostpath "$proj/tests"):/tests:ro" -v "$(hostpath "$res"):/res" \
    "${!image}" bash -c "$tester" tester "$side" "$ver" "$upstream" "${!install}" > /dev/null
done
echo "Testing $pkg: ours vs reference (results in $rel/test-$pkg)..."
docker wait "test-$pkg-ours" "test-$pkg-ref" > /dev/null
docker rm "test-$pkg-ours" "test-$pkg-ref" > /dev/null

for side in ours ref; do
  echo "== $side: $(cat "$res/$side.version" 2>/dev/null)"
  sed 's/^/   /' "$res/$side.targeted" 2>/dev/null
  [ -f "$res/$side.summary" ] && sed 's/^/   /' "$res/$side.summary"
done
if [ -f "$res/ours.fails" ] && [ -f "$res/ref.fails" ]; then
  echo "== failing only with ours:"; comm -13 "$res/ref.fails" "$res/ours.fails" | sed 's/^/   /'
  echo "== failing only with the reference:"; comm -23 "$res/ref.fails" "$res/ours.fails" | sed 's/^/   /'
fi
