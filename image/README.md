# Image Debian cho Devbox

Script `build-image.sh` tạo root filesystem Debian 13 (trixie) ARM64 để QEMU boot ở M1.

## Chạy ở đâu

- **GitHub Actions**: workflow **Build Debian image** → Run workflow. Artifact `devbox-debian-image`.
- **Linux có root** (không cần Mac): `sudo bash image/build-image.sh`.

Không chạy được trên Windows trực tiếp — cần Linux/WSL2 hoặc Actions.

## Kết quả trong `out/`

| File | Nội dung |
|---|---|
| `devbox-rootfs.ext4.zst` | Root filesystem ext4 (giải nén ra `.ext4` để gắn vào QEMU) |
| `vmlinuz` | Kernel ARM64 (`-kernel`) |
| `initrd.img` | initramfs (`-initrd`) |
| `manifest.json` | sha256, phiên bản Python/Node/npm, kernel |
| `SHA256SUMS` | Kiểm tra tải về |

## Kết quả build thật (2026-10-25, runner `ubuntu-24.04-arm`)

| File | Kích thước |
|---|---|
| `devbox-rootfs.ext4.zst` | 363 MB (giải nén: 1.73 GB) |
| `vmlinuz` | 36 MB — kernel `6.12.113+deb13-arm64` |
| `initrd.img` | 36 MB |
| Artifact `devbox-debian-image` | 410 MB |

Phiên bản trong image: Python `3.13.5`, pip `25.1.1`, Node `v22.23.4` (sha256 khớp), npm đi kèm Node.

## Có gì trong image

- Debian 13 minimal, glibc, systemd
- `python3` + `venv` + `pip` + `python3-dev` (Debian 13 → Python 3.13)
- `node` + `npm` + `npx` (Node 22.23.4, tarball chính thức, ghim sha256)
- `git`, `curl`, `wget`, `nano`, `htop`, `build-essential`, `pkg-config`
- User `dev`, mật khẩu `dev`, sudo không mật khẩu (máy một người dùng, không mở ra LAN)
- Autologin trên `ttyAMA0` (console QEMU)
- `/home/dev/projects` (dữ liệu dự án)
- `/mnt/share` mount 9p (import/export)
- `portwatch.service`: đọc `/proc/net/tcp`, ghi cổng LISTEN ra `/mnt/share/.ports` để app mở web preview

## Kiểm tra nhanh sau khi build

```bash
zstd -d out/devbox-rootfs.ext4.zst -o devbox-rootfs.ext4
# xem manifest
cat out/manifest.json
```

Boot thử trên Linux bằng QEMU (không cần iPhone):

```bash
qemu-system-aarch64 \
  -M virt -cpu max -smp 4 -m 2560 \
  -kernel out/vmlinuz -initrd out/initrd.img \
  -append "console=ttyAMA0 root=/dev/vda rw" \
  -drive if=virtio,format=raw,file=devbox-rootfs.ext4 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -nographic
```

Nếu boot được tới `dev@devbox:~/projects$` thì image đúng — phần còn lại là nhúng QEMU vào app (M1).
