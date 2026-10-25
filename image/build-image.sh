#!/usr/bin/env bash
set -euo pipefail

SUITE="${SUITE:-trixie}"
NODE_VERSION="${NODE_VERSION:-22.23.4}"
NODE_SHA256="${NODE_SHA256:-6287aa46b6c375d816e63ae66d024fbbfd70404825aabdfdf898a970871d2f4b}"
export NODE_VERSION NODE_SHA256
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
SECURITY_MIRROR="${SECURITY_MIRROR:-http://deb.debian.org/debian-security}"
ARCH="arm64"
IMG_SIZE="${IMG_SIZE:-5G}"
WORKDIR="${WORKDIR:-$PWD/work}"
OUTDIR="${OUTDIR:-$PWD/out}"
ROOTFS="$WORKDIR/rootfs"
IMAGE="$OUTDIR/devbox-rootfs.ext4"

log() { printf '\n== %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Phải chạy bằng root: sudo bash image/build-image.sh" >&2
  exit 1
fi

rm -rf "$WORKDIR" "$OUTDIR"
mkdir -p "$WORKDIR" "$OUTDIR"

export DEBIAN_FRONTEND=noninteractive

log "Cài công cụ build"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  debootstrap zstd e2fsprogs util-linux kmod

FOREIGN=""
if [ "$(uname -m)" != "aarch64" ]; then
  log "Host không phải arm64 → dùng qemu-user + binfmt"
  apt-get install -y -qq --no-install-recommends qemu-user-static binfmt-support
  update-binfmts --enable qemu-aarch64 2>/dev/null || true

  if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
    echo ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:CF' \
      > /proc/sys/fs/binfmt_misc/register 2>/dev/null || true
  fi

  if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo "Không đăng ký được binfmt aarch64. Dùng repo public để chạy runner ubuntu-24.04-arm." >&2
    exit 1
  fi

  FOREIGN="--foreign"
fi

log "debootstrap $SUITE/$ARCH"
debootstrap $FOREIGN --arch="$ARCH" --variant=minbase \
  --include=systemd,systemd-sysv,dbus,apt-utils,locales,ca-certificates \
  "$SUITE" "$ROOTFS" "$MIRROR"

cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free-firmware
deb $MIRROR $SUITE-updates main contrib non-free-firmware
deb $SECURITY_MIRROR $SUITE-security main contrib non-free-firmware
EOF

log "Mount /dev, /proc, /sys cho chroot"
mount --bind /dev "$ROOTFS/dev"
mkdir -p "$ROOTFS/dev/pts"
mount --bind /dev/pts "$ROOTFS/dev/pts" || true
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sysfs "$ROOTFS/sys"
mount -t tmpfs tmpfs "$ROOTFS/run" || true
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

cleanup() {
  set +e
  umount -lf "$ROOTFS/run" 2>/dev/null
  umount -lf "$ROOTFS/sys" 2>/dev/null
  umount -lf "$ROOTFS/proc" 2>/dev/null
  umount -lf "$ROOTFS/dev/pts" 2>/dev/null
  umount -lf "$ROOTFS/dev" 2>/dev/null
}
trap cleanup EXIT

if [ -n "$FOREIGN" ]; then
  cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
  log "Chạy debootstrap second stage (qemu-user)"
  chroot "$ROOTFS" /debootstrap/debootstrap --second-stage
fi

log "Cài Python, Node, kernel và cấu hình guest"
chroot "$ROOTFS" /bin/bash -s <<'CHROOT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  python3 python3-venv python3-pip python3-dev \
  build-essential pkg-config cmake \
  libssl-dev libffi-dev zlib1g-dev libbz2-dev liblzma-dev libreadline-dev \
  libsqlite3-dev libncurses-dev libgdbm-dev libnss3-dev libxml2-dev libxslt1-dev \
  libjpeg-dev libpng-dev libfreetype6-dev libpq-dev \
  git curl wget nano less htop unzip xz-utils ca-certificates gnupg \
  locales sudo bash \
  linux-image-arm64

cat > /etc/pip.conf <<'EOF'
[global]
timeout = 120
retries = 5
disable-pip-version-check = true
EOF

rm -f /usr/lib/python3*/EXTERNALLY-MANAGED

python3 -m pip install --no-cache-dir --ignore-installed --upgrade pip setuptools wheel

if python3 -m venv /opt/pysmoke \
   && /opt/pysmoke/bin/pip install -q --no-cache-dir requests numpy pandas \
   && SMOKE="$(/opt/pysmoke/bin/python -c 'import requests, numpy, pandas; print("requests %s, numpy %s, pandas %s" % (requests.__version__, numpy.__version__, pandas.__version__))')"; then
  printf '%s\n' "$SMOKE" > /etc/devbox-python-smoke
  echo "python smoke OK: $SMOKE"
else
  echo "python smoke FAILED" > /etc/devbox-python-smoke
  echo "python smoke FAILED (xem log pip ở trên)"
fi
rm -rf /opt/pysmoke

NODE_TARBALL="node-v${NODE_VERSION}-linux-arm64.tar.xz"
curl -fsSL -o "/tmp/$NODE_TARBALL" "https://nodejs.org/dist/v${NODE_VERSION}/$NODE_TARBALL"
echo "${NODE_SHA256}  /tmp/${NODE_TARBALL}" | sha256sum -c -
tar -xJf "/tmp/$NODE_TARBALL" -C /usr/local --strip-components=1
rm -f "/tmp/$NODE_TARBALL"
node -v
npm -v

sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/default/locale

if ! id dev >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo dev
fi
echo 'dev:dev' | chpasswd
echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev
chmod 440 /etc/sudoers.d/dev

echo devbox > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1 localhost
127.0.1.1 devbox
EOF

mkdir -p /home/dev/projects /mnt/share
chown -R dev:dev /home/dev
cat > /etc/fstab <<'EOF'
share /mnt/share 9p trans=virtio,version=9p2000.L,nofail,noatime 0 0
EOF

mkdir -p /etc/systemd/system/serial-getty@ttyAMA0.service.d
cat > /etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin dev --noclear %I $TERM
EOF
mkdir -p /etc/systemd/system/getty.target.wants
ln -sf /lib/systemd/system/serial-getty@.service \
  /etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service
ln -sf /lib/systemd/system/multi-user.target /etc/systemd/system/default.target

cat > /usr/local/bin/portwatch.sh <<'EOF'
#!/bin/bash
OUT=/mnt/share/.ports
while true; do
  if mountpoint -q /mnt/share 2>/dev/null; then
    {
      awk 'NR > 1 && $4 == "0A" {split($2, a, ":"); print a[2]}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null \
        | while read -r hex; do
            [ -n "$hex" ] && printf '%d\n' "0x$hex"
          done
    } | awk '$1 >= 1024 && $1 != 631 && $1 != 5353' | sort -un > "$OUT.tmp" 2>/dev/null \
      && mv "$OUT.tmp" "$OUT" 2>/dev/null
  fi
  sleep 1
done
EOF
chmod 755 /usr/local/bin/portwatch.sh

cat > /etc/systemd/system/portwatch.service <<'EOF'
[Unit]
Description=Devbox port watcher
After=local-fs.target

[Service]
ExecStart=/usr/local/bin/portwatch.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/portwatch.service \
  /etc/systemd/system/multi-user.target.wants/portwatch.service

cat > /home/dev/.bashrc <<'EOF'
export PS1='\[\e[32m\]dev@devbox\[\e[0m\]:\[\e[34m\]\w\[\e[0m\]\$ '
export LANG=en_US.UTF-8
export MAKEFLAGS="-j4"
export PIP_DISABLE_PIP_VERSION_CHECK=1
cd /home/dev/projects 2>/dev/null || true
EOF
chown dev:dev /home/dev/.bashrc

echo 'nameserver 10.0.2.3' > /etc/resolv.conf

rm -f /etc/systemd/system/timers.target.wants/apt-daily.timer \
      /etc/systemd/system/timers.target.wants/apt-daily-upgrade.timer \
      /etc/systemd/system/timers.target.wants/man-db.timer 2>/dev/null || true

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.npm /home/dev/.npm 2>/dev/null || true
rm -f /etc/machine-id
: > /etc/machine-id
CHROOT

log "Thu thập kernel + phiên bản package"
KERNEL="$(find "$ROOTFS/boot" -maxdepth 1 -name 'vmlinuz-*' | sort | head -n1)"
INITRD="$(find "$ROOTFS/boot" -maxdepth 1 -name 'initrd.img-*' | sort | head -n1)"
if [ -z "$KERNEL" ] || [ -z "$INITRD" ]; then
  echo "Không tìm thấy kernel/initrd trong $ROOTFS/boot" >&2
  ls -la "$ROOTFS/boot" >&2
  exit 1
fi
cp "$KERNEL" "$OUTDIR/vmlinuz"
cp "$INITRD" "$OUTDIR/initrd.img"

PY_VERSION="$(chroot "$ROOTFS" python3 --version 2>&1 || echo unknown)"
PIP_VERSION="$(chroot "$ROOTFS" python3 -m pip --version 2>&1 || echo unknown)"
PY_SMOKE_RESULT="$(cat "$ROOTFS/etc/devbox-python-smoke" 2>/dev/null || echo skipped)"
NODE_INSTALLED="$(chroot "$ROOTFS" node -v 2>&1 || echo unknown)"
NPM_VERSION="$(chroot "$ROOTFS" npm -v 2>&1 || echo unknown)"
KERNEL_VERSION="$(basename "$KERNEL")"

log "Đóng gói ext4"
cleanup
trap - EXIT

rm -f "$IMAGE"
truncate -s "$IMG_SIZE" "$IMAGE"
mkfs.ext4 -q -F -L devbox -d "$ROOTFS" "$IMAGE"
e2fsck -fy "$IMAGE" >/dev/null 2>&1 || true
resize2fs -M "$IMAGE" >/dev/null 2>&1 || true

BLOCKS="$(dumpe2fs -h "$IMAGE" 2>/dev/null | awk -F: '/^Block count:/ {gsub(/ /, "", $2); print $2}')"
BLOCK_SIZE="$(dumpe2fs -h "$IMAGE" 2>/dev/null | awk -F: '/^Block size:/ {gsub(/ /, "", $2); print $2}')"
if [ -n "${BLOCKS:-}" ] && [ -n "${BLOCK_SIZE:-}" ]; then
  truncate -s "$((BLOCKS * BLOCK_SIZE))" "$IMAGE"
fi

log "Nén bằng zstd"
zstd -T0 -12 -f -o "$OUTDIR/devbox-rootfs.ext4.zst" "$IMAGE"
rm -f "$IMAGE"

SHA_IMAGE="$(sha256sum "$OUTDIR/devbox-rootfs.ext4.zst" | awk '{print $1}')"
SHA_KERNEL="$(sha256sum "$OUTDIR/vmlinuz" | awk '{print $1}')"
SHA_INITRD="$(sha256sum "$OUTDIR/initrd.img" | awk '{print $1}')"
SIZE_IMAGE="$(stat -c %s "$OUTDIR/devbox-rootfs.ext4.zst")"

export SUITE PY_VERSION PIP_VERSION PY_SMOKE_RESULT NODE_INSTALLED NPM_VERSION KERNEL_VERSION
export SHA_IMAGE SHA_KERNEL SHA_INITRD SIZE_IMAGE

python3 - <<'PY'
import json
import os

manifest = {
    "name": "devbox-debian",
    "version": 1,
    "suite": os.environ["SUITE"],
    "arch": "arm64",
    "kernelVersion": os.environ["KERNEL_VERSION"],
    "packages": {
        "python": os.environ["PY_VERSION"],
        "pip": os.environ["PIP_VERSION"],
        "node": os.environ["NODE_INSTALLED"],
        "npm": os.environ["NPM_VERSION"],
    },
    "checks": {
        "pythonSmoke": os.environ["PY_SMOKE_RESULT"],
    },
    "image": {
        "file": "devbox-rootfs.ext4.zst",
        "sha256": os.environ["SHA_IMAGE"],
        "size": int(os.environ["SIZE_IMAGE"]),
    },
    "kernel": {
        "file": "vmlinuz",
        "sha256": os.environ["SHA_KERNEL"],
    },
    "initrd": {
        "file": "initrd.img",
        "sha256": os.environ["SHA_INITRD"],
    },
}
with open("out/manifest.json", "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

(cd "$OUTDIR" && sha256sum devbox-rootfs.ext4.zst vmlinuz initrd.img > SHA256SUMS)

log "Xong"
ls -lh "$OUTDIR"
