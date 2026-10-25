# Devbox (codename) — môi trường Linux trên iPhone

> Mục tiêu: mở app → chọn dự án → có một terminal Linux thật, trong đó `python`, `pip`, `node`, `npm`, `npx`, `git`, `gcc` chạy như trên máy tính.
> Không phải "giả lập cho vui": đây là **Debian ARM64 chạy trong máy ảo**, nên mọi thứ hoạt động giống Linux thật.

Dự án này là hướng đi tiếp theo sau khi bỏ ý tưởng Winlator (xem `docs/archive-winlator/`).

> **Trạng thái thật (2026-10-25):** engine QEMU đã build cho iOS và nhúng trong IPA, image Debian 13 đã phát hành, app đã có luồng tải image → boot → terminal. **Chưa test trên máy thật** — bước tiếp theo là cài IPA và chạy thử.
>
> **Đã build xanh:** workflow **Build iOS IPA** → `Devbox-unsigned.ipa` 7.03 MB (SHA256 `cf9517f2…`, có `Frameworks/qemu-aarch64-softmmu` 27.24 MB + glib/gio/pixman/slirp/zstd/libffi). Workflow **Build QEMU engine** → release `engine-v1`. Workflow **Build Debian image** → release `img-v1`: rootfs ext4 1.87 GB (zstd 396 MB), kernel 6.12.113, Python 3.13.5, Node 22.23.4.
>
> **Image đã boot thật trong CI** (`Test image boot`): vào prompt sau **62 giây** bằng TCG, `python3`/`node`/`npm`/`git`/`gcc` chạy đúng, có mạng ra PyPI, `portwatch` báo cổng 5173 và `http://127.0.0.1:5173` từ host trả HTML, `poweroff` sạch. Chưa test phần app trên iPhone.

---

## TL;DR

| | |
|---|---|
| Chạy gì | Python 3.13 + pip, Node 22 + npm/npx, git, gcc, curl, nano… |
| Chạy thế nào | QEMU (fork UTM) + Debian 13 ARM64, **không GPU, không Wine** |
| Giao diện | Terminal (chính) + quản lý dự án + **tự mở web preview** khi có dev server |
| Máy | iPhone 12 Pro Max (A14, 6 GB) |
| Build | GitHub Actions → `.ipa` → Sideloadly (không cần Mac) |
| JIT | **Bắt buộc** cho QEMU → phải sideload + StikDebug |
| Kích thước | IPA ~7 MB + image ~480 MB (tải một lần) |
| So với Winlator | Dễ hơn rất nhiều: bỏ Wine, bỏ box64, bỏ DXVK, bỏ GPU |

---

## Vì sao lại là máy ảo Linux, không phải nhúng Python/Node vào app?

Đã cân nhắc 3 cách:

| | Nhúng native (CPython xcframework, nodejs-mobile) | WASM (Pyodide…) | **Máy ảo Linux ARM64** |
|---|---|---|---|
| Python + pip | ✅ nhưng chỉ wheel thuần Python | ⚠️ chậm, thiếu package | ✅ đầy đủ, kể cả numpy/pandas |
| Node + npm + npx | ⚠️ build rất khó, thiếu `child_process` | ❌ npm không chạy thật | ✅ thật 100% |
| Native module (.node, .so) | ❌ không có | ❌ | ✅ prebuild arm64 hoặc tự compile |
| `npm install` có script | ❌ | ❌ | ✅ |
| Khởi động | tức thì | vài giây | 5–10 giây |
| Pin / nhiệt | tốt | trung bình | nặng |
| Cần JIT | không | không | **có** |
| Rủi ro kỹ thuật | cao (Node trên iOS) | cao | **thấp** |

→ Chọn **máy ảo**. Đánh đổi: khởi động chậm và tốn pin, nhưng **đúng** — `npm` và `pip` hoạt động thật, không có "gần đúng".

---

## Kiến trúc

```
┌───────────────────── iOS app (SwiftUI) ─────────────────────┐
│ Dự án · Terminal · Thiết lập · Web preview                  │
│  ├─ TerminalView ◄──── TCP 4444 ──────┐                     │
│  ├─ WKWebView  ◄──── HTTP 127.0.0.1 ──┤                     │
│  │   (tự mở khi thấy dev server)      │                     │
│  └─ QEMUEngine: dlopen + Thread        │                     │
│        ├─ serial PL011 (ttyAMA0) ──────┘                     │
│        ├─ virtio-blk: Debian 13 ARM64 (ext4 raw)            │
│        ├─ virtio-9p: /mnt/share ↔ app Documents/Devbox/share│
│        └─ virtio-net (user-mode) + hostfwd 3000/5173/8080   │
└──────────────────────────────────────────────────────────────┘
                              │
┌──────────────────── Debian 13 ARM64 guest ──────────────────┐
│ python3 · pip · venv · node · npm · npx · git · gcc · bash   │
│ /home/dev/projects/<slug>                                    │
│ portwatch: /proc/net/tcp → /mnt/share/.ports (mỗi 1 giây)    │
└──────────────────────────────────────────────────────────────┘
```

Không có: GPU, âm thanh, USB, Wayland/X11, Wine, box64. Đó là lý do dự án nhỏ hơn nhiều.

Chi tiết: [`docs/01-kien-truc.md`](docs/01-kien-truc.md)

---

## Bạn sẽ làm gì với nó

```bash
# Python
python3 -m venv .venv && source .venv/bin/activate
pip install requests numpy
python app.py

# Node
npm install
npm run dev          # app tự mở http://localhost:5173 trong khung web
npx create-vite@latest

# Khác
git clone …
gcc main.c -o main
```

---

## Web preview tự động

Bạn không phải copy địa chỉ `localhost:5173` sang Safari.

1. Guest có `portwatch.sh` đọc `/proc/net/tcp` mỗi giây, thấy cổng ≥1024 đang LISTEN thì ghi vào `/mnt/share/.ports`.
2. App đọc `Documents/Devbox/share/.ports` mỗi 1.5 giây, thử HTTP `127.0.0.1:<cổng>`. QEMU đã forward sẵn 3000/5173/8080 từ lúc boot nên không cần mở cổng động.
3. Cổng trả lời HTTP → app tự mở `WKWebView`. Nút **Web** trên terminal liệt kê mọi cổng đang mở để mở lại.

Áp dụng cho mọi thứ mở cổng HTTP trong ba cổng trên: Vite, Next.js dev, `python3 -m http.server`, Flask, `uvicorn --port 3000`, `streamlit --server.port 8080`… Cổng khác phải đổi về 3000/5173/8080.

---

## Giới hạn thật (đọc trước khi kỳ vọng)

| Giới hạn | Hệ quả |
|---|---|
| App bị iOS treo ~30 giây sau khi rời màn hình | Đã có **giữ nền** (audio im lặng): chuyển sang app khác thì web server vẫn chạy; vuốt app khỏi đa nhiệm thì tắt; tốn pin |
| Guest có 1792 MB RAM | Build lớn (Next.js, webpack nhiều entry) dễ OOM |
| QEMU TCG trên A14 | CPU ≈ laptop 2010–2015; chạy được, boot 30–90 giây, build chậm |
| Console không phải terminal grid | `vim`/`htop`/`less` hiển thị lộn xộn; chưa hỗ trợ full-screen TUI |
| Không GPU | Không chạy app GUI, không game, không Docker Desktop |
| Cần JIT | Phải sideload + StikDebug mỗi lần mở app |
| QEMU boot một lần mỗi tiến trình | Dừng Linux xong muốn chạy lại phải thoát hẳn app rồi mở lại |
| Nhiệt | Build liên tục sẽ throttle sau 15–20 phút |

Không có kế hoạch nào biến iPhone thành máy dev chính. Nó là **máy dev bỏ túi cho việc nhẹ**: sửa script, chạy thử API, học Python/Node, demo web.

---

## Trạng thái

```
[x] Phân tích & chốt kiến trúc
[x] App shell: dự án (lưu thật), console chẩn đoán thật, kiểm tra JIT bằng CS_DEBUGGED
[x] Pipeline build IPA tự động (GitHub Actions) — IPA 6.99 MB có engine QEMU nhúng
[x] Pipeline build image Debian 13 ARM64 — 394 MB nén, Python/Node/npm chạy thật
[x] Engine QEMU 10.0.12 (UTM fork) build cho iOS arm64, đóng gói framework, phát hành `engine-v1`
[x] App tải image từ release `img-v1`, kiểm SHA256, giải nén zstd tại chỗ
[x] Image boot thật trong CI: prompt sau 62 giây, python/node/npm/git/gcc OK, mạng ra PyPI OK
[x] `portwatch` + `hostfwd` chạy thật trong CI: `127.0.0.1:5173` trả HTML
[x] Terminal guest qua TCP 4444 + QMP 4445 + port watch + web preview tự mở
[x] Chạy nền: `UIBackgroundModes=audio` + audio im lặng (công tắc trong Thiết lập, lệnh `bg`)
[ ] Cài app lên iPhone 12 Pro Max và test boot          ← bước của bạn
[ ] M2 — xác nhận python/node/npm + preview trên máy thật
[ ] M3 — UX: template, quản lý gói, import/export (2–3 tuần)
[ ] M4 — tối ưu pin/nhiệt, code-server (tuỳ chọn)
```

---

## Đọc gì trước

| File | Nội dung |
|---|---|
| [`docs/00-bat-dau.md`](docs/00-bat-dau.md) | Cài app lên iPhone: GitHub Actions → Sideloadly → StikDebug |
| [`docs/01-kien-truc.md`](docs/01-kien-truc.md) | Kiến trúc, QEMU config, guest image, port forward, giới hạn |
| [`docs/02-lo-trinh.md`](docs/02-lo-trinh.md) | Mốc M0–M4, tiêu chí nghiệm thu, ước lượng |
| [`docs/03-cli.md`](docs/03-cli.md) | CLI chạy được gì / chậm gì / không chạy được, giới hạn RAM–đĩa, bài test nghiệm thu |
| [`docs/archive-winlator/`](docs/archive-winlator/) | Tài liệu cũ của hướng Winlator (để tham khảo, không còn triển khai) |
