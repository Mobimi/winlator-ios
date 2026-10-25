# Devbox (codename) — môi trường Linux trên iPhone

> Mở app → chọn dự án → có một terminal Linux thật, trong đó `python`, `pip`, `node`, `npm`, `npx`, `git`, `gcc` chạy như trên máy tính.
> Không phải "giả lập cho vui": đây là **Debian ARM64 chạy trong máy ảo**, nên mọi thứ hoạt động giống Linux thật.

Dự án này là hướng đi tiếp theo sau khi bỏ ý tưởng Winlator (xem `docs/archive-winlator/`).

---

## TL;DR

| | |
|---|---|
| Chạy gì | Python 3.13 + pip, Node 22 + npm/npx, git, gcc, curl, nano… |
| Chạy thế nào | QEMU (fork UTM) + Debian 13 ARM64, **không GPU, không Wine** |
| Giao diện | Terminal (chính) + quản lý dự án + mở dev server trong Safari |
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
│  ├─ SwiftTerm  ◄──── TCP localhost ────┐                    │
│  ├─ PortForward → Safari (localhost)   │                    │
│  └─ QEMU host (process riêng, JIT)     │                    │
│        ├─ virtio-console (ttyAMA0) ────┘                    │
│        ├─ virtio-blk: Debian 13 ARM64 (qcow2)               │
│        ├─ virtio-9p: /home/dev/projects ↔ app Documents     │
│        └─ virtio-net (user-mode) + hostfwd 5173/3000/8000   │
└──────────────────────────────────────────────────────────────┘
                              │
┌──────────────────── Debian 13 ARM64 guest ──────────────────┐
│ python3 · pip · venv · node · npm · npx · git · gcc · zsh    │
│ /home/dev/projects/<slug>                                    │
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
npm run dev          # mở http://localhost:5173 trong Safari
npx create-vite@latest

# Khác
git clone …
gcc main.c -o main
```

---

## Giới hạn thật (đọc trước khi kỳ vọng)

| Giới hạn | Hệ quả |
|---|---|
| iOS tạm dừng app sau ~30 giây ở nền | `npm install` dài phải giữ app mở, màn hình sáng |
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
[x] App shell: dự án, terminal mô phỏng, kiểm tra JIT, thông tin thiết bị
[x] Pipeline build IPA tự động (GitHub Actions)
[ ] Cài app lên iPhone 12 Pro Max        ← bước tiếp theo của bạn
[ ] M1 — QEMU boot Debian, terminal thật (3–4 tuần)
[ ] M2 — python/node/npm, chia sẻ file, port forward (3–4 tuần)
[ ] M3 — UX: template, quản lý gói, import/export (2–3 tuần)
[ ] M4 — tối ưu hiệu năng, chế độ nền, code-server (tuỳ chọn)
```

---

## Đọc gì trước

| File | Nội dung |
|---|---|
| [`docs/00-bat-dau.md`](docs/00-bat-dau.md) | Cài app lên iPhone: GitHub Actions → Sideloadly → StikDebug |
| [`docs/01-kien-truc.md`](docs/01-kien-truc.md) | Kiến trúc, QEMU config, guest image, port forward, giới hạn |
| [`docs/02-lo-trinh.md`](docs/02-lo-trinh.md) | Mốc M0–M4, tiêu chí nghiệm thu, ước lượng |
| [`docs/archive-winlator/`](docs/archive-winlator/) | Tài liệu cũ của hướng Winlator (để tham khảo, không còn triển khai) |
