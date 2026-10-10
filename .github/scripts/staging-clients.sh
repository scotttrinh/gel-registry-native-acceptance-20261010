#!/usr/bin/env bash
set -euo pipefail
# This runs only in disposable hosted fixtures; repository metadata is signed in CI.
uv run gel-registry validate --repo .
export GNUPGHOME="$(mktemp -d "$RUNNER_TEMP/client-key.XXXXXX")"
chmod 700 "$GNUPGHOME"
server=''
trap 'test -z "$server" || kill "$server"; gpgconf --kill gpg-agent || true; rm -rf "$GNUPGHOME"' EXIT
printf '%s' "$REGISTRY_SIGNING_KEY" | gpg --batch --import
unset REGISTRY_SIGNING_KEY
uv run gel-registry native render --repo . --cache "$RUNNER_TEMP/cache" --out public --base-url http://127.0.0.1:8765
uv run gel-registry native sign --repo .
uv run gel-registry native validate --repo .
mkdir "$RUNNER_TEMP/original"
export FIXTURE_ORIGINAL="$RUNNER_TEMP/original"
python3 - <<'PY'
import hashlib,json,os,platform
from pathlib import Path
from urllib.request import urlopen
records=[json.loads(p.read_text()) for p in Path('releases').rglob('*.json')]
old=next(r for r in records if r['source']['tag']=='pkg-gel-7-7.1-1')
arch='aarch64' if platform.machine()=='aarch64' else 'x86_64'
deb_arch='arm64' if arch=='aarch64' else 'amd64'
yanked={e['sha256'] for e in json.loads(Path('native/yanked.json').read_text())}
locked=json.loads(Path('native/packages.lock.json').read_text())
assert len(locked)==4 and all(p['version']=='1:7.1-2' and p['sha256'] not in yanked for p in locked)
for fmt,arch in [('deb',deb_arch),('rpm',arch)]:
    p=next(p for p in old['native']['packages'] if p['url'].endswith(f'-{arch}.{fmt}'))
    assert p['sha256'] in yanked
    raw=urlopen(p['url'],timeout=60).read()
    assert len(raw)==p['size'] and hashlib.sha256(raw).hexdigest()==p['sha256']
    (Path(os.environ['FIXTURE_ORIGINAL'])/f'original.{fmt}').write_bytes(raw)
PY
python3 .github/scripts/staging-http.py public > "$RUNNER_TEMP/client-http.log" 2>&1 &
server=$!
for attempt in {1..30}; do
  if curl -fsS http://127.0.0.1:8765/keys/gelstable.asc >/dev/null; then break; fi
  sleep 1
done
docker run --rm --network host -v "$PWD/public/keys:/keys:ro" -v "$RUNNER_TEMP/original:/original:ro" debian:12 bash -ceu '
  apt-get update -qq
  apt-get install -y -qq gnupg ca-certificates
  gpg --dearmor < /keys/gelstable.asc > /usr/share/keyrings/staging.gpg
  dpkg -i /original/original.deb
  test "$(dpkg-query -W -f="\${Version}" gel-server-7)" = "1:7.1-1"
  printf "%s\n" "deb [signed-by=/usr/share/keyrings/staging.gpg] http://127.0.0.1:8765/apt stable main" > /etc/apt/sources.list.d/staging.list
  apt-get update
  apt-get install -y gel-server-7
  test "$(dpkg-query -W -f="\${Version}" gel-server-7)" = "1:7.1-2"
  grep "revision 2" /usr/share/gel-server-7/fixture
  ! apt-cache madison gel-server-7 | grep "1:7.1-1"
  echo "Signed APT revision 1 to 2 upgrade passed"
'
docker run --rm --network host -v "$PWD/public/keys:/keys:ro" -v "$RUNNER_TEMP/original:/original:ro" rockylinux:9 bash -ceu '
  rpm --import /keys/gelstable.asc
  dnf -y --disablerepo="*" --setopt=localpkg_gpgcheck=1 install /original/original.rpm
  test "$(rpm -q --queryformat "%{EPOCH}:%{VERSION}-%{RELEASE}" gel-server-7)" = "1:7.1-1"
  printf "%s\n" "[staging]" "name=Disposable staging" "baseurl=http://127.0.0.1:8765/rpm/stable/\$basearch" "gpgcheck=1" "repo_gpgcheck=1" "gpgkey=file:///keys/gelstable.asc" "enabled=1" > /etc/yum.repos.d/staging.repo
  dnf -y --disablerepo="*" --enablerepo=staging --refresh upgrade gel-server-7
  test "$(rpm -q --queryformat "%{EPOCH}:%{VERSION}-%{RELEASE}" gel-server-7)" = "1:7.1-2"
  grep "revision 2" /usr/share/gel-server-7/fixture
  ! dnf --disablerepo="*" --enablerepo=staging list --showduplicates gel-server-7 | grep "1:7.1-1"
  echo "Signed DNF revision 1 to 2 upgrade passed"
'
