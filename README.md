# Devbox (codename) — môi trường Linux trên iPhone

> Mục tiêu: mở app → chọn dự án → có một terminal Linux thật, trong đó `python`, `pip`, `node`, `npm`, `npx`, `git`, `gcc` chạy như trên máy tính.
> Không phải "giả lập cho vui": đây là **Debian ARM64 chạy trong máy ảo**, nên mọi thứ hoạt động giống Linux thật.

Dự án này là hướng đi tiếp theo sau khi bỏ ý tưởng Winlator (xem `docs/archive-winlator/`).

> **Trạng thái thật (đọc trước khi cài):** bản app hiện tại **chưa có engine Linux**. Nó không giả lập `python`/`npm` nữa; terminal chỉ chạy lệnh chẩn đoán thật (`jit`, `diag`, `bg`, `mem`, `uname`, `df`, `ls`, `engine`). Muốn có Linux thật phải xong M1 (nhúng QEMU + image Debian).
>
> **Build đã chạy thật (2026-10-25):** workflow **Build iOS IPA** xanh → `Devbox-unsigned.ipa` (arm64, bundle `app.devbox.dev`, 198 445 bytes, `UIBackgroundModes = [audio]` đã kiểm tra trong CI). Workflow **Build Debian image** xanh → rootfs ext4 1.87 GB (zstd 395 MB), kernel 6.12.113, Python 3.13.5, pip 26.2.2, Node 22.23.4. Smoke test trong image: `requests 2.34.2, numpy 2.5.4, pandas 3.1.0` cài từ PyPI và import OK.

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
| Thời gian tới bản dùng được | **8–11 tuần** (1 người) |
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
│ Dự án · Terminal · Thiết lập                                │
│  ├─ SwiftTerm  ◄──── socketpair ──────┐                     │
│  ├─ WKWebView  ◄──── HTTP localhost ──┤                     │
│  │   (tự mở khi thấy dev server)      │                     │
│  └─ QEMU host (process riêng, JIT)     │                     │
│        ├─ serial PL011 (ttyAMA0) ──────┘                     │
│        ├─ virtio-blk: Debian 13 ARM64 (ext4 raw)            │
│        ├─ virtio-9p: /mnt/share ↔ app Documents             │
│        └─ virtio-net (user-mode) + hostfwd 5173/3000/8000   │
└──────────────────────────────────────────────────────────────┘
                              │
┌──────────────────── Debian 13 ARM64 guest ──────────────────┐
│ python3 · pip · venv · node · npm · npx · git · gcc · bash   │
│ /home/dev/projects/<slug>                                    │
│ agent: /proc/net/tcp → /mnt/share/.ports (phát hiện server)  │
└──────────────────────────────────────────────────────────────┘
```

Không có: GPU, âm thanh, USB, Wayland/X11, Wine, box64. Đó là lý do dự án nhỏ hơn nhiều.

Chi tiết: [`docs/01-kien-truc.md`](docs/01-kien-truc.md)

---

## Bạn sẽ làm gì với nó (khi xong M2)

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

1. Guest có một agent nhỏ đọc `/proc/net/tcp` mỗi giây, thấy cổng mới đang LISTEN thì ghi vào `/mnt/share/.ports`.
2. App đọc file đó, thử HTTP `127.0.0.1:<cổng>`; nếu trả lời được thì gọi QMP `hostfwd_add` để mở cổng ra loopback của iOS.
3. Terminal hiện banner `Web · localhost:5173` và tự mở `WKWebView` (có nút reload / mở Safari). Tuỳ chọn tắt tự mở sẽ có ở tab **Thiết lập** khi làm M2.

Áp dụng cho mọi thứ mở cổng HTTP: Vite, Next.js dev, `uvicorn`, Flask, `streamlit`, `gradio`, harness Python/Node… **Chưa hoạt động ở bản hiện tại**: WKWebView đã có code nhưng chưa có engine/port forwarding (M2). Không có banner giả.

---

## Giới hạn thật (đọc trước khi kỳ vọng)

| Giới hạn | Hệ quả |
|---|---|
| App bị iOS treo ~30 giây sau khi rời màn hình | Đã có **giữ nền** (audio im lặng): chuyển sang app khác thì web server vẫn chạy; vuốt app khỏi đa nhiệm thì tắt; tốn pin |
| Guest chỉ có ~2.5 GB RAM | Build lớn (Next.js, webpack nhiều entry) dễ OOM |
| QEMU TCG trên A14 | CPU ≈ laptop 2015; chạy được, build chậm |
| Không GPU | Không chạy app GUI, không game, không Docker Desktop |
| Cần JIT | Phải sideload + StikDebug mỗi lần mở app |
| Nhiệt | Build liên tục sẽ throttle sau 15–20 phút |

Không có kế hoạch nào biến iPhone thành máy dev chính. Nó là **máy dev bỏ túi cho việc nhẹ**: sửa script, chạy thử API, học Python/Node, demo web.

---

## Trạng thái

```
[x] Phân tích & chốt kiến trúc
[x] App shell: dự án (lưu thật), console chẩn đoán thật, kiểm tra JIT bằng CS_DEBUGGED
[x] Pipeline build IPA tự động (GitHub Actions) — **đã build xanh, có IPA thật**
[x] Pipeline build image Debian 13 ARM64 (GitHub Actions) — **đã build xanh, 395 MB nén, Python/pip/numpy/pandas chạy thật**
[x] Chạy nền: `UIBackgroundModes=audio` + audio im lặng (công tắc trong Thiết lập, lệnh `bg`)
[ ] Cài app lên iPhone 12 Pro Max        ← bước của bạn
[ ] M1 — nhúng QEMU, boot Debian, terminal thật (3–4 tuần)
[ ] M2 — python/node/npm, chia sẻ file, port forward + web thật (3–4 tuần)
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
