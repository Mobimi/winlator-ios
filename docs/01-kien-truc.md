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
│  ├─ TerminalView        terminal + bàn phím + phím tắt           │
│  ├─ WebPreviewView      WKWebView + banner localhost:<port>      │
│  ├─ SetupView           JIT, image, engine, web preview, log     │
│  └─ QEMUEngine          dlopen qemu-aarch64-softmmu.framework    │
│       ├─ qemu_init / qemu_main_loop / qemu_cleanup trên Thread   │
│       ├─ GuestConsole   TCP 127.0.0.1:4444 (serial console)      │
│       ├─ QMPClient      TCP 127.0.0.1:4445 (quit)                │
│       └─ PortWatcher    Documents/Devbox/share/.ports            │
└──────────────────────────────────────────────────────────────────┘
                                 │
┌────────────────────── QEMU (aarch64-softmmu) ────────────────────┐
│ -M virt -cpu max -smp 4 -m 1792 -accel tcg,thread=multi          │
│ virtio-blk  : rootfs.ext4 (raw, ghi trực tiếp)                   │
│ virtio-9p   : /mnt/share ↔ Documents/Devbox/share                │
│ virtio-net  : user-mode NAT + hostfwd 3000/5173/8080             │
│ pl011       : -serial chardev socket localhost:4444              │
│ -display none -nodefaults -no-user-config                        │
└──────────────────────────────────────────────────────────────────┘
                                 │
┌──────────────────────── Debian 13 ARM64 ─────────────────────────┐
│ systemd → serial-getty autologin (dev) → bash                    │
│ python3 3.13 + venv + pip                                        │
│ node 22 + npm 10 + npx                                           │
│ git, curl, wget, nano, build-essential, ripgrep                  │
│ /home/dev/projects/<slug>   (ext4)                               │
│ /mnt/share                  (9p, để import/export)               │
│ portwatch.sh: /proc/net/tcp → /mnt/share/.ports mỗi 1 giây       │
└──────────────────────────────────────────────────────────────────┘
```

### Vì sao không dùng SPICE / X11 / GPU

Terminal chỉ cần một luồng byte. Dùng `virtio-console` là đủ — nhẹ hơn SPICE rất nhiều, không cần virgl/Venus/MoltenVK. Đây là lý do chính khiến dự án nhỏ hơn Winlator ~5 lần.

---

## 3. QEMU: cấu hình thực tế

App `dlopen` framework `Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu`, lấy ba symbol `qemu_init`, `qemu_main_loop`, `qemu_cleanup` rồi chạy trên một `Thread` riêng. iOS không cho spawn process, nên đây là cách duy nhất để nhúng QEMU mà không cần app extension (app extension làm SideStore vướng prefix).

```bash
-M virt,highmem=on -cpu max -smp 4 -m 1792 \
-accel tcg,thread=multi,tb-size=256 -rtc base=utc,clock=host \
-kernel <image>/vmlinuz -initrd <image>/initrd.img \
-append "console=ttyAMA0 root=/dev/vda rw loglevel=4 net.ifnames=0" \
-drive if=virtio,format=raw,cache=writeback,file=<image>/rootfs.ext4 \
-virtfs local,path=<Documents>/Devbox/share,mount_tag=share,security_model=none,multidevs=remap \
-netdev user,id=n0,hostfwd=tcp:127.0.0.1:8080-:8080,hostfwd=tcp:127.0.0.1:3000-:3000,hostfwd=tcp:127.0.0.1:5173-:5173 \
-device virtio-net-pci,netdev=n0,romfile= \
-object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
-chardev socket,id=con,host=127.0.0.1,port=4444,server=on,wait=off -serial chardev:con \
-qmp tcp:127.0.0.1:4445,server=on,wait=off \
-display none -nodefaults -no-user-config -name devbox
```

Ghi chú kỹ thuật:

| Vấn đề | Cách làm |
|---|---|
| Không spawn được process | Nhúng QEMU dưới dạng `.framework`, gọi trực tiếp `qemu_init`/`qemu_main_loop`/`qemu_cleanup`. `atexit` guard gọi `pthread_exit` nếu QEMU gọi `exit()`, tránh chết cả app. |
| Console | QEMU `-serial chardev` mở TCP `127.0.0.1:4444`; app nối bằng `NWConnection` và giữ kết nối suốt đời engine (ngắt sẽ làm getty nhận hangup). |
| Card mạng | Engine build bằng `--disable-install-blobs` nên không có `efi-virtio.rom`; QEMU mặc định gắn ROM PXE cho `virtio-net-pci` và chết với `failed to find romfile "efi-virtio.rom"`. Truyền `romfile=` rỗng để bỏ ROM — kernel đã được nạp bằng `-kernel` nên không cần PXE. |
| Tắt máy an toàn | App gửi `quit` qua QMP `127.0.0.1:4445`. `qemu_main_loop` trả về → `qemu_cleanup` → state `.stopped`. |
| Boot lại | QEMU không reentrant: mỗi tiến trình chỉ boot một lần. Dừng rồi muốn chạy tiếp thì thoát hẳn app và mở lại. |
| JIT | QEMU TCG cần bộ nhớ thực thi. QEMU bản gốc trên Darwin map JIT buffer bằng `MAP_JIT` + `PROT_NONE`; iOS chỉ cho cờ đó khi app có entitlement `dynamic-codesigning` riêng, nên `mmap` trả `EINVAL` (`allocate … bytes for jit buffer: Invalid argument`). Engine Devbox vá `tcg/region.c` bỏ `MAP_JIT` và map thẳng `PROT_READ\|PROT_WRITE\|PROT_EXEC` — đúng kiểu mà `mmap` RWX trên máy đã chứng minh là chạy được khi có debugger (`CS_DEBUGGED`). Trước khi boot, app thử `mmap` RWX 256 → 16 MB để chọn `tb-size` và biết ngay JIT có hiệu lực hay không; nếu bị chặn, app báo lỗi kèm errno thay vì treo. Trong lúc boot, app ghi từng bước (`dlopen`, `dlsym`, `qemu_init`, `main loop`) vào `Documents/logs/qemu.log` — mở bằng app Files, giữ cả `qemu-previous.log` và `diagnostics.txt`; watchdog 90 giây báo bước cuối. |
| Resize terminal | Không hỗ trợ ở M1; chữ tự xuống dòng theo bề rộng màn hình. |
| Đăng nhập | `serial-getty@ttyAMA0` với `--autologin dev`. Không mật khẩu. |
| 9p | Chỉ dùng cho `share/.ports` và trao đổi file; dự án nằm trên ext4 trong image. |
| Mạng trong guest | systemd-networkd cấu hình tĩnh `eth0 = 10.0.2.15/24`, gateway `10.0.2.2`, DNS `10.0.2.3` — đúng topology slirp, không cần DHCP. |
| Console không phải terminal grid | Parser theo dòng: `vim`/`htop`/`less` hiển thị lộn xộn. Chưa gửi SIGWINCH. |
| Port forward | Cố định 3000/5173/8080 lúc boot (bind lỗi sẽ làm QEMU thoát, nên giữ ít cổng). Dev server phải nghe đúng một trong ba cổng này. |
| Đóng gói | CI build QEMU cho iOS, đổi mỗi `.dylib` thành `.framework`, sửa `install_name` sang `@rpath/<name>.framework/<name>`, phát hành zip ở release `engine-v1`; workflow IPA tải zip và nhúng vào `Payload/Devbox.app/Frameworks`. |
| Kích thước | `qemu-aarch64-softmmu` ~27 MB + glib/gio/pixman/slirp/zstd ~5 MB. IPA ~7 MB. |

---

## 4. Đĩa và dữ liệu

```
Documents/Devbox/
├── images/
│   └── debian13-arm64/
│       ├── rootfs.ext4        # raw ext4 1.87 GB, ghi trực tiếp
│       ├── vmlinuz            # kernel 6.12.113
│       ├── initrd.img
│       └── manifest.json      # phiên bản + sha256
├── share/                     # 9p, mount tại /mnt/share
│   ├── .ports                 # portwatch.sh ghi cổng đang LISTEN
│   └── ...                    # file trao đổi với guest
└── Projects/                  # thư mục dự án phía app (không auto-mount)
```

Quyết định quan trọng:

- **Dự án nằm trên ext4 trong image**, không nằm trên 9p. 9p rất chậm với `node_modules` (hàng chục nghìn file nhỏ). 9p chỉ dùng làm cửa import/export và để guest báo cổng.
- **Image ghi trực tiếp**: chưa có overlay qcow2 ở M1. Sửa gì trong guest thì nằm luôn trong `rootfs.ext4`; cài lại image là reset.
- **Image tải từ GitHub Release** `img-v1`, kiểm tra SHA256 từng file rồi giải nén zstd bằng `libzstd` nhúng trong app.

---

## 5. Guest image

| Thành phần | Thực tế |
|---|---|
| Base | Debian 13 (trixie) ARM64 minimal, glibc. ext4 **1.87 GB**, zstd **396 MB**. |
| Kernel | `6.12.113+deb13-arm64` |
| Python | **3.13.5**, pip **26.2.2**, kèm venv, numpy/pandas/requests |
| Node | **22.23.4**, npm **10.9.9**, npx |
| Build | `build-essential`, `pkg-config` |
| Khác | `git`, `curl`, `wget`, `nano`, `htop`, `less`, `unzip`, `ripgrep`, `iproute2`, `procps`, `ping` |
| Mạng | systemd-networkd cấu hình tĩnh `eth0 = 10.0.2.15/24`, gateway `10.0.2.2`, DNS `10.0.2.3` (slirp) |
| Locale | `en_US.UTF-8` |
| Phát hành | Release `img-v1`: `devbox-rootfs.ext4.zst`, `vmlinuz`, `initrd.img`, `manifest.json`, `SHA256SUMS` |

App tải khoảng 480 MB (ba file), giải nén ra 1.87 GB. Cần khoảng 3 GB trống. Tải một lần, sau đó boot offline.

Đã kiểm chứng bằng `Test image boot` (QEMU TCG trên runner ARM64): prompt sau **62 giây**, `python3 -V` → 3.13.5, `node -v` → v22.23.4, `npm -v` → 10.9.9, `mountpoint /mnt/share` OK, `ip addr` → 10.0.2.15, `urlopen('https://pypi.org/simple/')` → 200, `http.server 5173` được forward ra host, `poweroff` sạch.

---

## 6. Hiệu năng dự kiến trên iPhone 12 Pro Max

Ước lượng (TCG ARM64→ARM64, 4 vCPU, 1792 MB RAM):

| Tác vụ | Thời gian |
|---|---|
| Boot đến prompt | 30–120 giây (TCG; đo 62 giây trên runner CI) |
| `python3 -c "print(1)"` | 0.3–1 s |
| `node -v` | 1–2.5 s |
| `npm install express` | 30–80 s |
| `npm run dev` (Vite) | 6–15 s |
| `pip install numpy` (wheel arm64) | 40–90 s |
| `gcc hello.c` | 2–6 s |
| Build Vite nhỏ | 1–3 phút |
| Build Next.js | 5–15 phút, dễ OOM |

Nghẽn thật: **RAM** và **nhiệt**, không phải CPU.

---

## 7. Web preview tự động

Mục tiêu: chạy `npm run dev` / `uvicorn` / `streamlit` → app **tự mở giao diện web**, không phải copy cổng sang Safari.

Luồng hoạt động:

1. **Guest** (`portwatch.sh`, systemd service): mỗi 1 giây đọc `/proc/net/tcp` + `/proc/net/tcp6`, lọc cổng `LISTEN` từ 1024 trở lên (bỏ 631/5353), ghi ra `/mnt/share/.ports` — mỗi dòng một số cổng.
2. **App** (`PortWatcher`): đọc `Documents/Devbox/share/.ports` mỗi 1.5 giây. Cổng mới → thử `GET http://127.0.0.1:PORT/` với timeout 2 giây.
3. Nếu có phản hồi HTTP, app mở `WebPreviewView` (WKWebView) một lần cho cổng đó. Nút **Web** trên thanh công cụ terminal liệt kê mọi cổng đang mở để mở lại.
4. QEMU đã forward sẵn 3000/5173/8080 từ lúc boot, nên không cần QMP `hostfwd_add`.

| Chi tiết | Quyết định |
|---|---|
| Phát hiện cổng | Guest tự báo qua `.ports`; app không đoán theo tên lệnh, nên Vite, Next, FastAPI, Flask, Gradio đều dùng được miễn là nghe cổng 3000/5173/8080. |
| HTTP probe | `URLSession` + timeout 2 giây; server không phải HTTP (database, raw TCP) thì bỏ qua, không mở web. |
| ATS | `Info.plist` mở `NSAppTransportSecurity` cho HTTP localhost (app sideload nội bộ, không lên App Store). |
| Cổng khác | Đổi cổng dev server về 3000/5173/8080. Muốn thêm cổng phải build lại engine với `hostfwd` mới (bind lỗi lúc boot sẽ làm QEMU thoát). |
| Safari | Nút trên thanh công cụ mở đúng địa chỉ bằng Safari thật (khi cần cookie, extension, DevTools). |
| Giới hạn | Một preview tại một thời điểm. Khi app vào nền và đang giữ nền, server guest vẫn sống; quay lại là mở tiếp. |

`127.0.0.1` trong app iOS là loopback của **chính thiết bị**, và QEMU user-net bind hostfwd vào đó — WKWebView truy cập được mà không mở cổng ra LAN.

### 7.1 Giữ app chạy khi ra nền (đã có trong app)

Vấn đề: iOS suspend app vài giây sau khi rời màn hình → socket của dev server chết theo.

Cách làm trong `BackgroundKeeper`:

1. `Info.plist` khai báo `UIBackgroundModes: [audio]` (khoá plist, **không** phải entitlement, nên không phá profile free).
2. `AVAudioSession` category `.playback`, option `.mixWithOthers` (không chặn nhạc của app khác).
3. `AVAudioEngine` phát buffer gần như im lặng (−100 dBFS) lặp vô hạn. Hệ thống coi app là app nhạc đang phát → không suspend tiến trình.
4. Khi vào nền, nếu audio chưa lên thì xin thêm `beginBackgroundTask` (~30 giây) để kịp khởi động lại; audio bị ngắt (cuộc gọi, rút tai nghe) thì tự bật lại ở `interruptionNotification` và `routeChangeNotification`.

Công tắc: tab **Thiết lập → Chạy nền** (`@AppStorage("devbox.keepRunning")`, mặc định bật) hoặc lệnh `bg on|off` trong console. Trạng thái thật hiển thị ngay trong tab đó: audio session, route, thời gian đã giữ, số lần gián đoạn, lỗi nếu có.

Giới hạn thật:

| Tình huống | Kết quả |
|---|---|
| Bấm Home, chuyển sang app khác, khoá máy | App + server vẫn chạy |
| Vuốt app khỏi đa nhiệm (Force Quit) | **Luôn tắt**, không API nào chặn được |
| iOS thiếu RAM / nhiệt quá cao | Có thể bị kill, dù audio vẫn phát |
| Pin | Tốn hơn bình thường (audio session + QEMU cùng chạy), máy ấm hơn |

Đây là cách các app sideload vẫn làm; App Store sẽ từ chối app phát audio im lặng, nhưng Devbox chỉ cài qua Sideloadly/SideStore.

---

## 8. Giới hạn và cách xử lý

| Giới hạn | Xử lý |
|---|---|
| iOS suspend app sau ~30 s | Đã xử lý bằng `BackgroundKeeper`: `UIBackgroundModes=audio` + audio im lặng (−100 dBFS) + `beginBackgroundTask` dự phòng. Chỉ mất khi Force Quit hoặc thiếu RAM/nhiệt. |
| App bị kill khi thiếu RAM | Guest cấu hình 1792 MB; RAM còn lại cho iOS. Guest dùng quá nhiều (build Next.js) thì tiến trình trong guest bị OOM-kill trước, app vẫn sống. |
| Không có swap thật | Không bật swap ở M1. Guest 1792 MB là mức an toàn cho iPhone 12 Pro Max (6 GB). |
| Bàn phím tiếng Việt | Ô nhập là `TextField` SwiftUI, dùng bàn phím hệ thống nên Telex/VNI hoạt động như mọi app khác; gõ xong nhấn Gửi. |
| Copy/paste | Chọn text trong console (`.textSelection(.enabled)`) và dán vào ô nhập bằng clipboard hệ thống. Chưa có OSC 52. |
| Terminal full-screen (vim, htop, less) | Chưa hỗ trợ: console là parser dòng, không phải terminal grid. `vim`/`htop` sẽ hiển thị lộn xộn. Dùng lệnh không tương tác. |
| Resize / SIGWINCH | Không gửi; chữ tự xuống dòng theo bề rộng màn hình. |
| Mạng | QEMU user-mode NAT: guest ra Internet bình thường; máy ngoài **không** vào được guest. Đủ an toàn. |
| Docker | Không. Cần namespace + overlayfs + kernel features; có thể thử `podman` nhưng không hứa. |
| App GUI (X11) | Không ở bản 1.0. Có thể thêm sau bằng Xvfb + VNC → WKWebView, nhưng không ưu tiên. |
| code-server (VS Code) | Khả thi về lý thuyết (Node server + Safari). Chưa thử. |

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
