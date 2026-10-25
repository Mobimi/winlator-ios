# 02 — Lộ trình Devbox

Ước lượng cho **1 người full-time** (có hỗ trợ của AI), đã có iPhone + Windows + GitHub Actions. Không cần Mac.

---

## M0 — Pipeline & cài đặt (1 tuần) ← đang ở đây

| Việc | Xong khi |
|---|---|
| App build trên GitHub Actions | Actions xanh, có `Devbox-unsigned.ipa` |
| Cài lên iPhone bằng Sideloadly | App mở được, không văng |
| Bật JIT bằng StikDebug | Tab Thiết lập báo **JIT đã bật**; trước StikDebug phải báo đỏ |
| Console chẩn đoán chạy | Tạo dự án, gõ `help`/`jit`/`mem`, thấy dữ liệu thật |

**Artifact:** ảnh chụp tab Thiết lập (JIT đỏ trước, xanh sau) + ảnh console sau `help`.

Nếu M0 thất bại vì StikDebug/JIT: chuyển ngay sang phương án **Native Lite** (Python nhúng, không JIT) — xem cuối `docs/01-kien-truc.md`.

---

## M1 — Máy ảo boot + terminal thật (3–4 tuần)

| Việc | Xong khi |
|---|---|
| Fork UTM, chỉ giữ `aarch64-softmmu`, bỏ UI/GPU/audio | Build ra framework nhúng được |
| `DevboxEngine` (ObjC++) khởi động QEMU trong process riêng | Hàm `boot()` trả về, có log |
| Console bridge ↔ SwiftTerm | Gõ lệnh trong app, thấy prompt Linux |
| Bàn phím + resize | `stty size` đúng khi xoay máy / mở bàn phím |
| Tắt máy an toàn | `poweroff` → QEMU exit, không mất dữ liệu |
| Rootfs tối giản | Boot đến login < 15 s |

**Tiêu chí nghiệm thu M1:**

```text
- Bấm Play → 12 giây sau thấy:  dev@devbox:~$
- Gõ: python3 --version  → Python 3.13.x
- Gõ: ls /               → thấy thư mục Linux thật
- Chạy 20 phút, RAM ổn định, không crash
- Xoay ngang → terminal resize đúng
```

**Rủi ro chính:** StikDebug/JIT trên iOS hiện tại; QEMU helper lifecycle trên iOS; tty resize.

---

## M2 — Môi trường dev đầy đủ (3–4 tuần)

| Việc | Xong khi |
|---|---|
| Image có python3 + pip + venv + node + npm + npx + git + gcc | `node -v`, `pip --version` chạy |
| Chia sẻ file qua 9p | Kéo file từ Files.app vào `Projects/`, thấy trong guest |
| Import/export dự án | Nút Xuất → file xuất hiện trong Files.app |
| Guest agent phát hiện cổng | `/mnt/share/.ports` cập nhật trong ≤ 2 s khi server start/stop |
| Port forward qua QMP | Cổng mới được `hostfwd_add` tự động, `curl 127.0.0.1:5173` từ app trả HTML |
| Web preview | `npm run dev` → **tự mở WKWebView** thấy trang Vite, không cần copy địa chỉ |
| Lưu dữ liệu qua reboot | Tắt/mở app, file vẫn còn |
| Reset máy ảo | Xoá overlay, giữ `Projects/` |
| Swap 512 MB | Không bị kill khi build vừa phải |

**Tiêu chí nghiệm thu M2:**

```text
- pip install requests numpy      → OK
- npm install express             → OK
- npx create-vite@latest demo    → OK (chậm nhưng xong)
- cd demo && npm install && npm run dev
  → khoảng 1–2 giây sau khi Vite báo "Local: 5173",
    app tự mở khung web, thấy trang Vite (không thao tác gì thêm)
- Thêm một dự án Python chạy `uvicorn app:app --port 8000`
  → app tự mở localhost:8000, banner đổi cổng đúng
- Tắt tự mở trong Thiết lập → `npm run dev` chỉ hiện banner, không tự mở
- Tắt app, mở lại → project + node_modules còn nguyên
```

**Rủi ro chính:** RAM (2.5 GB), 9p chậm, nhiệt khi build.

---

## M3 — UX cho người không chuyên (2–3 tuần)

| Việc | Xong khi |
|---|---|
| Template dự án (Python / Node / trống) | Tạo dự án mới có sẵn file mẫu |
| Panel gói (pip/npm) | Bấm cài `requests`, `express` không cần gõ lệnh |
| Trình xem log & sức khoẻ VM | Thấy CPU/RAM/disk, copy log 1 chạm |
| Onboarding | Người mới biết phải làm gì trong 3 màn hình |
| Thông báo lỗi thân thiện | "Hết RAM", "Mất JIT", "Image lỗi" thay vì crash |
| Nhập/xuất dự án | Zip 1 dự án ra Files.app và ngược lại |

**Tiêu chí nghiệm thu M3:** một người chưa từng dùng Linux tạo được dự án Node, chạy `npm run dev`, thấy web preview tự mở trong **dưới 5 phút**.

---

## M4 — Tối ưu & mở rộng (tuỳ chọn, liên tục)

- Tuning TCG: số vCPU, cache size, ghim vào P-core, `-accel tcg,thread=multi`.
- Xử lý nền: `beginBackgroundTask`, cảnh báo trước khi suspend, tự pause an toàn.
- Giảm nhiệt: giới hạn tốc độ build, tạm dừng khi pin thấp.
- `code-server` trong guest → mở VS Code trên Safari (thử nghiệm).
- Chế độ "Native Lite" (Python nhúng, không JIT) cho người không muốn sideload.

---

## Tổng thời gian

| Mốc | Tuần | Lũy kế |
|---|---|---|
| M0 | 1 | 1 |
| M1 | 3–4 | 5 |
| M2 | 3–4 | 9 |
| M3 | 2–3 | 12 |
| M4 | — | liên tục |

→ **Bản dùng được (hết M2): ~9 tuần. Bản mượt cho người không chuyên (hết M3): ~12 tuần.**

So với hướng Winlator (9–12 tháng), đây là dự án nhỏ hơn khoảng **4–5 lần**.

---

## Việc bạn cần làm tuần này

- [ ] Đưa repo lên GitHub (GitHub Desktop → Add local repository → Publish).
- [ ] Chạy workflow **Build iOS IPA**, tải artifact.
- [ ] Cài bằng Sideloadly, bật Developer Mode, bật JIT bằng StikDebug.
- [ ] Mở app, chụp tab **Thiết lập** (JIT + `proc_csflags`).
- [ ] Trong console, gõ `jit` và `help` → đối chiếu: JIT phải đỏ khi chưa chạy StikDebug.
- [ ] Gửi mình: ảnh 2 tab + **tên package/dự án** bạn muốn chạy đầu tiên (ví dụ `requests`, `express`, `create-vite`).

Sau khi M0 xong, mình bắt tay vào M1: fork UTM và nối QEMU.

---

## Rủi ro & đối sách

| Rủi ro | Xác suất | Ảnh hưởng | Đối sách |
|---|---|---|---|
| StikDebug/JIT bị chặn trên iOS mới | Trung bình | Không chạy VM | Native Lite (Python nhúng, không JIT) |
| TCG chậm hơn dự kiến | Trung bình | UX kém | Giảm vCPU, tắt service thừa, dùng Alpine cho boot nhanh |
| OOM khi `npm install` lớn | Cao | Gián đoạn | Swap, giới hạn 2.5 GB, `--ignore-scripts`, cảnh báo |
| 9p quá chậm | Cao | Import chậm | Chỉ dùng 9p để copy, không chạy trực tiếp trên đó |
| Image 600 MB tải lỗi | Trung bình | Không cài được | Chia chunk + resume + sha256 |
| Nhiệt/pin | Cao | Không chơi lâu | Cảnh báo, giới hạn, tạm dừng khi nóng |
| Bạn đổi ý lần nữa | 🙂 | — | UI tách khỏi engine, đổi backend không phải viết lại app |

---

## Định nghĩa "xong" bản 1.0

- Cài IPA → bật JIT → tạo dự án → chạy Python và Node trong < 5 phút.
- `pip install` (wheel arm64) và `npm install` hoạt động.
- Dev server mở được trong app (và trong Safari khi cần).
- Tắt/mở app không mất dữ liệu; reset máy ảo không mất `Projects/`.
- Có log, có nút export, có thông báo lỗi rõ ràng.
- Tài liệu: cài đặt, template, xử lý lỗi thường gặp.
