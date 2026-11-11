#!/usr/bin/env bash
# Run the packaged client and server in the same no-uplink namespace.
# The second argument contains grpcio-tools installed for /usr/bin/python3.
set -euo pipefail
image=$(realpath -e "${1:?usage: $0 <AppImage> <Python site-packages> <Reality echo fixture>}")
client_modules=$(realpath -e "${2:?missing Python client modules}")
reality=$(realpath -e "${3:?missing Reality echo fixture from the pinned core tests}")
tests=$(dirname "$(realpath -e "$0")")
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
bwrap --die-with-parent --new-session --unshare-net --unshare-pid --unshare-ipc \
  --ro-bind /usr /usr --ro-bind /etc /etc --symlink usr/bin /bin \
  --ro-bind /lib /lib --ro-bind-try /lib64 /lib64 --proc /proc --dev /dev \
  --dir /dev/net --dev-bind /dev/net/tun /dev/net/tun --tmpfs /tmp --tmpfs /run \
  --ro-bind "$image" /fixture.AppImage --ro-bind "$tests" /tests --ro-bind "$client_modules" /client \
  --ro-bind "$reality" /reality-server \
  --bind "$scratch" /work --chdir /work --clearenv --setenv PATH /usr/bin:/bin \
  --setenv TMPDIR /work --setenv PYTHONDONTWRITEBYTECODE 1 --setenv PYTHONPATH /client \
  /usr/bin/python3 /tests/verify_appimage_default_vless.py /fixture.AppImage /reality-server
