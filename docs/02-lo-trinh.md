# 02 — Lộ trình Devbox

Ước lượng cho **1 người full-time** (có hỗ trợ của AI), đã có iPhone + Windows + GitHub Actions. Không cần Mac.

**Trạng thái thật (25/10/2026):** M0 ✅ · M1 ✅ (đã build + đóng gói, chờ test trên máy) · M2 🟡 (image + port watch + preview đã có, chưa test thực tế) · M3 ⬜ · M4 ⬜.

---

## M0 — Pipeline & cài đặt (1 tuần) ✅

| Việc | Xong khi |
|---|---|
| App build trên GitHub Actions | Actions xanh, có `Devbox-unsigned.ipa` |
| Cài lên iPhone bằng Sideloadly | App mở được, không văng |
| Bật JIT bằng StikDebug | Tab Thiết lập báo **JIT đã bật**; trước StikDebug phải báo đỏ |
| Console chẩn đoán chạy | Tạo dự án, gõ `help`/`jit`/`mem`, thấy dữ liệu thật |

Đã xong: run `40202743140` cho IPA 7.28 MB (SHA256 `61d8ab74…`), có tab **Shell** + bảng kết quả từng lệnh, nút **Ẩn bàn phím**, chẩn đoán console qua QMP (`query-chardev`, `rd_bytes`) + nhịp tim guest qua `share/.ports`, tự mở lại serial khi lệnh im lặng. JIT đọc đúng `CS_DEBUGGED` trên iPhone13,4 / iOS 18.4.1. Log QEMU nằm trong app Files (`Devbox/logs`).

---

## M1 — Máy ảo boot + terminal thật (3–4 tuần) ✅

| Việc | Thực tế đã làm |
|---|---|
| Build QEMU cho iOS | Build từ UTM fork `v10.0.12-utm`, `--enable-shared-lib`, chỉ `aarch64-softmmu`, phụ thuộc libffi/glib/pixman/zstd/libslirp tự build |
| Nhúng QEMU vào app | Mỗi `.dylib` đóng thành `.framework` trong `Payload/Devbox.app/Frameworks`, `install_name` đổi sang `@rpath/<name>.framework/<name>` |
| Khởi động QEMU | `dlopen` + `qemu_init`/`qemu_main_loop`/`qemu_cleanup` trên `Thread` riêng, `atexit` guard |
| Console | QEMU `-serial chardev` → TCP `127.0.0.1:4444`; `GuestConsole` nối `NWConnection` |
| Tắt máy an toàn | QMP `quit` qua `127.0.0.1:4445` |
| Rootfs | Debian 13 ARM64, ext4 1.9 GB, zstd 423 MB, kernel 6.12.113 |

**Chờ test trên máy:** boot lần đầu, độ trễ console, hành vi khi vào nền.

---

## M2 — Môi trường dev đầy đủ (3–4 tuần) 🟡

| Việc | Xong khi | Trạng thái |
|---|---|---|
| Image có python3 + pip + venv + node + npm + npx + git + gcc | `node -v`, `pip --version` chạy | ✅ có trong image |
| Chia sẻ file qua 9p | File trong `Documents/Devbox/share` thấy ở `/mnt/share` | ✅ |
| Guest agent phát hiện cổng | `/mnt/share/.ports` cập nhật trong ≤ 2 s | ✅ `portwatch.service` |
| Port forward | `curl 127.0.0.1:5173` từ app trả HTML | ✅ cố định 3000/5173/8080 |
| Web preview | `npm run dev` → **tự mở WKWebView** | ✅ code xong, chờ test máy |
| Lưu dữ liệu qua reboot | Tắt/mở app, file vẫn còn | ✅ vì rootfs.ext4 ghi trực tiếp |
| Import/export dự án | Nút Xuất → file trong Files.app | ⬜ chưa làm |
| Reset máy ảo | Xoá image, giữ dữ liệu | ⬜ xoá image = reset toàn bộ |
| Swap | Có swapfile trong guest | ⬜ không bật (1792 MB RAM) |

**Tiêu chí nghiệm thu M2:**

```text
- pip install requests numpy      → OK
- npm install express             → OK
- npx create-vite@latest demo    → OK (chậm nhưng xong)
- cd demo && npm install && npm run dev
  → khoảng 2–5 giây sau khi Vite báo "Local: 5173",
    app tự mở khung web, thấy trang Vite (không thao tác gì thêm)
- Thêm một dự án Python chạy `python3 -m http.server 8080`
  → app tự mở localhost:8080
- Tắt app, mở lại → project + node_modules còn nguyên
```

**Rủi ro chính:** RAM (1792 MB), 9p chậm, nhiệt khi build.

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
- Xử lý nền: **đã có sớm** — `UIBackgroundModes=audio` + audio im lặng (−100 dBFS), xem `docs/01-kien-truc.md` §7.1. M4 chỉ còn tinh chỉnh: tự pause QEMU khi pin thấp, giảm tải audio session.
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

- [ ] Tải IPA ở run **Build iOS IPA** mới nhất (artifact `Devbox-unsigned-ipa`).
- [ ] Cài bằng Sideloadly (Apple ID thường), bật Developer Mode trên máy.
- [ ] Mở StikDebug → **Enable JIT** cho Devbox (app sẽ tự mở lại).
- [ ] Tab **Thiết lập** → **Tải và cài image (~500 MB)**. Giữ app mở, cần ~3 GB trống.
- [ ] Mở tab **Shell** → chờ boot (30–90 giây) → thấy `dev@devbox:~$`.
- [ ] Gõ thử `gi` (gợi ý `git`), `cd /mnt/share/` (gợi ý file thật), `python3 -V`, `node -v`, `npm -v` và gửi kết quả.
- [ ] Bấm Home 2 phút, quay lại, xem đồng hồ "Đã chạy" trong tab Thiết lập có tăng tiếp không.

Nếu có lỗi: tab **Thiết lập** → **Sao chép chẩn đoán**, và gửi file `qemu.log` + `diagnostics.txt` trong app Files (`Trên iPhone của tôi → Devbox → logs`) hoặc bấm **Chia sẻ file log**.

---

## Rủi ro & đối sách

| Rủi ro | Xác suất | Ảnh hưởng | Đối sách |
|---|---|---|---|
| StikDebug/JIT bị chặn trên iOS mới | Trung bình | Không chạy VM | Native Lite (Python nhúng, không JIT) |
| TCG chậm hơn dự kiến | Trung bình | UX kém | Giảm vCPU, tắt service thừa, dùng Alpine cho boot nhanh |
| OOM khi `npm install` lớn | Cao | Gián đoạn | Guest 1792 MB, tránh build Next.js, đóng app khác |
| 9p quá chậm | Cao | Import chậm | Chỉ dùng 9p để copy, không chạy trực tiếp trên đó |
| Image ~500 MB tải lỗi | Trung bình | Không cài được | `URLSession` tải lại + kiểm SHA256 từng file |
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
