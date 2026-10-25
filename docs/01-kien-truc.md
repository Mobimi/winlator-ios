# 01 — Kiến trúc Devbox

## 1. Mục tiêu / phi mục tiêu

**Mục tiêu:** một app iOS mở ra là có shell Linux ARM64 thật, chạy được Python và Node/npm/npx, mỗi dự án một thư mục riêng, và khi dự án mở dev server thì app tự mở giao diện web trong `WKWebView`.

**Phi mục tiêu:** chạy app GUI, chơi game, Docker, Xcode, thay thế laptop.

---

## 2. Thành phần

```
┌──────────────────────────── iOS app ─────────────────────────────┐
│ SwiftUI                                                          │
│  ├─ ProjectsView        danh sách môi trường                     │
│  ├─ TerminalView        SwiftTerm + bàn phím + phím tắt          │
│  ├─ WebPreviewView      WKWebView + banner localhost:<port>      │
│  ├─ SetupView           JIT, image, web preview, log              │
│  └─ DevboxEngine (ObjC++)                                        │
│       ├─ QEMU host process (CS_DEBUGGED → JIT)                   │
│       ├─ console bridge (socketpair ↔ SwiftTerm)                 │
│       ├─ port watcher (/mnt/share/.ports → hostfwd_add)          │
│       └─ lifecycle (pause/resume, save on background)            │
└──────────────────────────────────────────────────────────────────┘
                                │
┌────────────────────── QEMU (aarch64-softmmu) ────────────────────┐
│ -M virt -cpu max -smp 4 -m 2560                                  │
│ virtio-blk  : rootfs.qcow2 (base read-only) + overlay.qcow2      │
│ virtio-9p   : /mnt/share  ↔  app Documents/Devbox                │
│ virtio-net  : user-mode NAT + hostfwd 3000/5173/8000/8080        │
│ virtio-console (ttyAMA0) → TCP localhost hoặc socketpair fd      │
│ -display none -nodefaults -no-reboot                             │
└──────────────────────────────────────────────────────────────────┘
                                │
┌──────────────────────── Debian 13 ARM64 ─────────────────────────┐
│ systemd → getty autologin (dev) → zsh                            │
│ python3 3.13 + venv + pip                                        │
│ node 22 + npm 10 + npx                                           │
│ git, curl, wget, nano, build-essential, ripgrep                  │
│ /home/dev/projects/<slug>   (ext4, nhanh)                        │
│ /mnt/share                  (9p, để import/export)               │
│ portwatch.sh: /proc/net/tcp → /mnt/share/.ports mỗi 1 giây       │
└──────────────────────────────────────────────────────────────────┘
```

### Vì sao không dùng SPICE / X11 / GPU

Terminal chỉ cần một luồng byte. Dùng `virtio-console` là đủ — nhẹ hơn SPICE rất nhiều, không cần virgl/Venus/MoltenVK. Đây là lý do chính khiến dự án nhỏ hơn Winlator ~5 lần.

---

## 3. QEMU: cấu hình mục tiêu

```bash
qemu-system-aarch64 \
  -M virt,highmem=on -cpu max -smp 4 -m 2560 \
  -rtc base=utc,clock=host \
  -kernel /…/vmlinuz -initrd /…/initrd.img \
  -append "console=ttyAMA0 root=/dev/vda2 rw quiet loglevel=3" \
  -drive if=virtio,format=qcow2,file=rootfs-overlay.qcow2 \
  -virtfs local,path=<sandbox>/Documents/Devbox,mount_tag=share,security_model=none \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5173-:5173,hostfwd=tcp:127.0.0.1:3000-:3000 \
  -device virtio-net-pci,netdev=n0 \
  -chardev socket,id=con,fd=3 -device virtio-serial-pci -device virtconsole,chardev=con \
  -display none -nodefaults -no-reboot
```

Ghi chú kỹ thuật:

| Vấn đề | Cách làm |
|---|---|
| Không có `/dev/ptmx` ổn định trên iOS | Dùng **socketpair** truyền fd từ app sang QEMU (`-chardev socket,fd=`), không dùng TCP. Fallback: TCP `127.0.0.1`. |
| Resize terminal | Gửi lệnh `stty rows R cols C` qua một file trong `/mnt/share/.tty`, guest có timer 200 ms đọc và áp dụng. Đơn giản, không cần agent. |
| Đăng nhập | `getty --autologin dev` trên `ttyAMA0`. Không mật khẩu (thiết bị một người dùng). |
| Tắt máy an toàn | App gửi `poweroff`; chờ QEMU exit; nếu quá 5 s thì `quit` qua QMP. |
| Treo / crash | QMP `stop` + đóng file; lần sau boot lại từ overlay. qcow2 chịu được crash nhưng nên `sync` định kỳ. |
| Nhiều dự án | Mỗi dự án là một thư mục; **không** cần nhiều VM. Chỉ 1 VM dùng chung, tiết kiệm RAM. |
| Port forward thêm | QMP `human-monitor-command: hostfwd_add tcp:127.0.0.1:PORT-:PORT` — không cần restart. |
| Cập nhật image | Base image mới + giữ overlay cũ; nếu schema đổi thì migrate `/home`. |

---

## 4. Đĩa và dữ liệu

```
Documents/Devbox/
├── images/
│   ├── debian13-arm64.qcow2       # base, chỉ đọc, ~1.4 GB
│   └── debian13-arm64.manifest    # version + sha256
├── vm/
│   └── overlay.qcow2              # copy-on-write, chứa thay đổi + /home
├── Projects/                      # mount qua 9p tại /mnt/share
│   ├── hello-python/
│   └── web-app/
└── logs/
    └── qemu.log
```

Quyết định quan trọng:

- **Dự án nằm trên ext4 trong overlay, không nằm trên 9p.** 9p rất chậm với `node_modules` (hàng chục nghìn file nhỏ). 9p chỉ dùng làm cửa import/export.
- **Base image read-only + overlay**: cập nhật image không mất dữ liệu; "Reset máy ảo" chỉ xoá overlay, giữ `Projects/`.
- **Export**: nút "Xuất dự án" copy từ guest ra `Projects/` qua 9p rồi hiện trong Files.app.

---

## 5. Guest image

| Thành phần | Ghi chú |
|---|---|
| Base | Debian 13 (trixie) ARM64, minimal, **glibc** (không chọn Alpine vì musl làm hỏng nhiều wheel/native module). Build thật: 1.73 GB ext4 → 363 MB zstd. |
| Kernel | `linux-image-arm64` của Debian (**6.12.113** khi build) |
| Python | `python3` + `python3-venv` + `python3-pip` + `python3-dev` (build thật: **3.13.5**) |
| Node | Node 22.23.4 từ tarball chính thức nodejs.org (ghim sha256); kèm `npm`, `npx` |
| Build | `build-essential`, `pkg-config` |
| Khác | `git`, `curl`, `wget`, `nano`, `htop`, `less`, `unzip`; thêm `cmake`, `libssl-dev`, `libffi-dev`, `libxml2-dev`, `libpq-dev`… để build extension Python từ source |
| Locale | `en_US.UTF-8` (tránh lỗi pip/npm với locale C) |

Kích thước mục tiêu: **≤ 1.6 GB** chưa nén, **≤ 600 MB** sau zstd. Tải lần đầu, có resume + sha256.

---

## 6. Hiệu năng dự kiến trên iPhone 12 Pro Max

Ước lượng (TCG ARM64→ARM64, 4 vCPU, 2.5 GB RAM):

| Tác vụ | Thời gian |
|---|---|
| Boot đến prompt | 6–12 s |
| `python3 -c "print(1)"` | 0.1–0.4 s |
| `node -v` | 0.6–1.2 s |
| `npm install express` | 15–40 s |
| `npm run dev` (Vite) | 3–8 s |
| `pip install numpy` (wheel arm64) | 20–50 s |
| `gcc hello.c` | 1–3 s |
| Build Vite nhỏ | 30–90 s |
| Build Next.js | 3–8 phút, dễ OOM |

Nghẽn thật: **RAM** và **nhiệt**, không phải CPU.

---

## 7. Web preview tự động

Mục tiêu: chạy `npm run dev` / `uvicorn` / `streamlit` → app **tự mở giao diện web**, không phải copy cổng sang Safari.

Luồng hoạt động:

1. **Guest agent** (`portwatch.sh`, chạy như systemd service): mỗi 1 giây đọc `/proc/net/tcp` + `/proc/net/tcp6`, lọc cổng đang `LISTEN` từ 1024 trở lên (bỏ 631/5353), ghi ra `/mnt/share/.ports` — mỗi dòng một số cổng.
2. **App** (`PortWatcher`): đọc file 2 giây/lần (9p đủ nhanh cho file vài dòng). Cổng mới → thử `GET http://127.0.0.1:PORT/` với timeout ~1.5 s.
3. Nếu có phản hồi HTTP (kể cả 3xx/4xx), app gọi QMP `human-monitor-command: hostfwd_add tcp:127.0.0.1:PORT-:PORT` rồi mở `WebPreviewView` (WKWebView).
4. Banner `Web · localhost:PORT` nằm ngay trên thanh nhập lệnh khi server còn sống: bấm **Mở** để mở lại, **✕** để ẩn.

| Chi tiết | Quyết định |
|---|---|
| Phát hiện cổng | Guest tự báo qua `.ports`; app **không** đoán theo tên lệnh, nên Vite, Next, FastAPI, Flask, Gradio… đều dùng được. |
| hostfwd | `hostfwd_add` chỉ thêm được, không xoá gọn → app giữ set cổng đã map, chỉ thêm cổng mới. |
| HTTP probe | `URLSession` + `waitsForConnectivity = false`. Server không phải HTTP (raw TCP, database) → bỏ qua, không mở web. |
| ATS | `Info.plist` mở `NSAppTransportSecurity` cho HTTP localhost (app sideload nội bộ, không lên App Store). |
| Tắt tự mở | `@AppStorage("devbox.autoOpenWeb")`, mặc định **bật**; công tắc trong tab Thiết lập sẽ thêm ở M2. |
| Safari | Nút trên thanh công cụ mở đúng địa chỉ bằng Safari thật (khi cần cookie, extension, DevTools). |
| Giới hạn | Một preview tại một thời điểm; nhiều server thì banner hiện server mới nhất. Khi app vào nền, server guest vẫn chạy nhưng preview đóng. |

`127.0.0.1` trong app iOS là loopback của **chính thiết bị**, và QEMU user-net bind hostfwd vào đó — WKWebView truy cập được mà không mở cổng ra LAN.

> `WebPreviewView` là WKWebView thật, nhưng **chưa dùng được trước M2**: chưa có QEMU/portwatcher nên không có cổng nào để mở. Không có trang giả hay banner giả.

---

## 8. Giới hạn và cách xử lý

| Giới hạn | Xử lý |
|---|---|
| iOS suspend app sau ~30 s | `beginBackgroundTask` (~30 s) + `idleTimerDisabled` khi có tác vụ chạy + cảnh báo UI. Chấp nhận: việc dài cần màn hình mở. |
| App bị kill khi thiếu RAM | Giới hạn 2.5 GB, giải phóng cache page của QEMU, cảnh báo khi guest > 85%. |
| Không có swap thật | Tạo swapfile 512 MB trong overlay (chậm nhưng tránh OOM). |
| Keyboard tiếng Việt | Terminal dùng `UITextInput` của SwiftTerm; cần test Telex/VNI. Fallback: dán (paste). |
| Copy/paste | OSC 52 (guest → app) và paste trực tiếp; thêm file `/mnt/share/.clipboard` nếu OSC không ổn. |
| Mạng | QEMU user-mode NAT: guest ra Internet bình thường; máy ngoài **không** vào được guest. Đủ an toàn. |
| Docker | Không. Cần namespace + overlayfs + kernel features; có thể thử `podman` nhưng không hứa. |
| App GUI (X11) | Không ở bản 1.0. Có thể thêm sau bằng Xvfb + VNC → WKWebView, nhưng không ưu tiên. |
| code-server (VS Code) | Khả thi về lý thuyết (Node server + Safari). Thử ở M4, không hứa. |

---

## 9. Bảo mật

- Guest không mật khẩu, nhưng **không mở cổng ra LAN** — chỉ `127.0.0.1` trong app.
- Image tải qua HTTPS + pin `sha256`; không chạy image lạ.
- Toàn bộ dữ liệu nằm trong sandbox app; xoá app = xoá sạch.
- Không chạy lệnh từ xa, không có daemon lắng nghe ngoài localhost.

---

## 10. Phương án dự phòng (nếu QEMU/JIT thất bại)

**"Native Lite"**: bỏ VM, nhúng **CPython xcframework** (BeeWare `Python-Apple-support`) trực tiếp vào app.

- ✅ Không cần JIT → cài bằng Sideloadly là chạy, thậm chí lên được App Store.
- ✅ Khởi động tức thì, pin tốt.
- ❌ `subprocess` không chạy, `pip` chỉ cài được wheel thuần Python, không có Node.
- Dùng khi: StikDebug/JIT bị Apple chặn, hoặc bạn muốn một app "Python bỏ túi" đơn giản.

Đây là lý do kiến trúc UI tách khỏi engine: cùng một giao diện, hai backend.
