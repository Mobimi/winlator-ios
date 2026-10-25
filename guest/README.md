# guest/

Rootfs Linux ARM64 chứa Wine + box64 + DXVK, build bằng Docker (không build trên iPhone).

Chưa có code ở đây. Kế hoạch (M1–M3):

```
guest/
├── Dockerfile
├── build-rootfs.sh          # debootstrap Debian arm64 → overlay → nén
├── packages.txt
├── overlay/
│   ├── cellar-agent/        # C: virtio-serial ↔ app
│   ├── cellar-session       # gamescope + wine, chạy 1 game
│   └── etc/                 # systemd, pulseaudio, wine tweaks
└── manifest.json            # version + sha256
```

Thành phần bắt buộc:

| Gói | Vai trò |
|---|---|
| `mesa-vulkan-drivers` (Venus) | Vulkan trong guest |
| `wine` ARM64 + `box64` | chạy .exe x86_64 |
| `dxvk` (x86_64 PE) | D3D9/10/11 → Vulkan |
| `gamescope` | fullscreen, fps cap |
| `pulseaudio` | audio → SPICE |
| `cellar-agent` | nhận lệnh từ app |

Kích thước mục tiêu: ≤ 900 MB sau nén. Có script kiểm tra: boot trong QEMU trên PC trước khi đưa lên iPhone.
