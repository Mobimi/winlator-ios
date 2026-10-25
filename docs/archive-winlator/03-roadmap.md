# 03 — Roadmap

Ước lượng cho **1 người full-time, đã biết Swift + C**, có Mac và iPad. Team 2–3 người rút ngắn ~40%.

---

## Nguyên tắc: chứng minh bằng UTM gốc trước, viết code sau

Trước khi viết dòng nào, hãy chứng minh **toàn bộ chuỗi GPU** chạy được bằng app UTM có sẵn:

1. Cài **UTM** (bản sideload từ AltStore + StikDebug JIT) trên iPad.
2. Tạo VM **Debian ARM64** (UTM có guide sẵn).
3. Trong guest: cài Mesa + bật Venus, cài `wine` arm64 + `box64` + DXVK.
4. Chạy một game DX9/DX11 nhẹ, ví dụ **TrackMania Nations Forever** (miễn phí) hoặc **Cave Story**.

Nếu bước 4 ra hình và chơi được → **dự án khả thi**, mọi việc còn lại là đóng gói sản phẩm.
Nếu bước 4 không ra hình sau khi thử cả DXVK và WineD3D → đổi hướng (mục "Kill criteria" bên dưới).

Đây là **spike quan trọng nhất của cả dự án** và nó không cần code.

---

## M0 — Môi trường & baseline (1–2 tuần)

| Việc | Xong khi |
|---|---|
| Mac + Xcode 16+, Apple ID dev, iPad thật (M1+) | `xcodebuild` chạy được |
| Fork UTM, build `.ipa` từ source | App UTM tự build chạy trên iPad |
| Bật JIT bằng StikDebug | QEMU log báo JIT enabled, VM boot < 10s |
| Build rootfs Debian ARM64 theo `guest/` | Boot được, SSH vào được |
| **Spike GPU (như trên)** | Ghi lại: game nào, fps bao nhiêu, lỗi gì |

**Artifact:** `docs/spike-report.md` — bảng "game × backend × fps × lỗi". Đây là tài liệu định giá dự án.

---

## M1 — Engine host: VM + hiển thị + tay cầm (4–6 tuần)

| Việc | Xong khi |
|---|---|
| `CellarEngine` API, tách QEMU khỏi UI | App SwiftUI gọi `boot()` và VM lên |
| Metal surface nhận frame từ render server | 1280×720 @60fps, không tearing |
| VirtIO-serial + `cellar-agent` handshake | App nhận `{"ok":true,...}` |
| GamepadBridge → uinput | `evtest` trong guest thấy nút/trục; `jstest` đúng |
| Pause/Resume/Shutdown | Pause < 100ms, resume < 200ms |
| Stability | Chạy 30 phút không crash, RAM ổn định |

**Demo M1:** bấm Play → hiện desktop Linux (tạm) → tay cầm điều khiển được con trỏ → Pause/Resume.

---

## M2 — Wine chạy được .exe đầu tiên (6–8 tuần)

| Việc | Xong khi |
|---|---|
| Wine ARM64 + box64 trong rootfs | `wine notepad` hiện cửa sổ |
| `cellar-session` + gamescope | Không còn desktop, chỉ cửa sổ game |
| Import EXE từ iOS vào guest | Copy xong, chạy được |
| Wine prefix per-container | 2 container không ảnh hưởng nhau |
| Log pipeline | App hiện log Wine realtime |
| **Game 2D đầu tiên** (Cave Story) | 60fps, input không trễ cảm nhận được |

**Demo M2:** cài game 2D từ iPad, bấm Play, chơi bằng tay cầm. Đây là mốc có thể quay video marketing.

---

## M3 — GPU: DXVK + Venus (6–8 tuần) ← **mốc sống còn**

| Việc | Xong khi |
|---|---|
| `vulkaninfo` trong guest thấy Venus | API version ≥ 1.3 |
| DXVK load được trong prefix | `DXVK_HUD=fps` hiện overlay |
| D3D9 game | TMNF hoặc tương đương: ≥ 30fps @720p |
| D3D11 game | 1 title chạy được, không sai hình nghiêm trọng |
| Fallback WineD3D | Tự chuyển khi DXVK fail, app báo rõ |
| Đo frame time | Có số: CPU frame, GPU frame, present |

**Kill criteria (quan trọng):** nếu sau **8 tuần** mà **không có game D3D11 nào ra hình đúng**, dừng hướng C và chuyển sang:
- **B** (Windows ARM64 + Prism), hoặc
- **A** (stream PC) để có sản phẩm, giữ C làm R&D.

Đừng đốt thêm 6 tháng vào một chuỗi GPU không hoạt động.

---

## M4 — UX kiểu Winlator (4–6 tuần)

| Việc | Xong khi |
|---|---|
| Library + cover art + import | Thêm/xoá/sửa game không cần terminal |
| Container editor (DXVK version, box64 preset, resolution, fps cap) | Đổi preset → chạy lại → có tác dụng |
| Overlay trong game | Pause, snapshot, keyboard, mapping, FPS/RAM |
| Touch controls | Chơi được game không cần tay cầm |
| Onboarding JIT | Người mới biết phải làm gì, có nút "kiểm tra JIT" |
| Snapshot | Resume nhanh; ghi rõ giới hạn nếu GPU không restore |
| Compat DB (local JSON) | Mỗi game có ghi chú "chạy tốt / cần preset X" |

**Demo M4:** một người chưa biết gì cài IPA, làm theo onboarding, tự thêm game và chơi trong < 15 phút.

---

## M5 — Tương thích & hiệu năng (8 tuần, lặp vô hạn)

| Việc | Xong khi |
|---|---|
| Bộ test 20 game (2D, DX9, DX11, indy, AAA cũ) | Có bảng kết quả công khai |
| Auto-tune preset | App tự chọn preset theo game, giảm crash |
| Frame pacing + giới hạn fps + hạ resolution động | Không giật, nhiệt ổn định 45 phút |
| Rootfs gọn + cập nhật Delta | ≤ 900MB, update < 100MB |
| Crash report + log export | Người dùng gửi được report 1 chạm |
| Tài liệu người dùng | Có hướng dẫn cài IPA, bật JIT, thêm game |

---

## Tổng thời gian

| Mốc | Tuần | Lũy kế |
|---|---|---|
| M0 | 1–2 | 2 |
| M1 | 4–6 | 8 |
| M2 | 6–8 | 16 |
| M3 | 6–8 | 24 |
| M4 | 4–6 | 30 |
| M5 | 8 | 38 |

→ **MVP chơi được (hết M3): ~5–6 tháng. Sản phẩm dùng được (hết M4): ~7 tháng. Ổn định: ~9 tháng.**

Nếu chỉ có thời gian buổi tối/cuối tuần: nhân 2.5–3.

---

## Chuẩn bị ngay (tuần này)

**Phần cứng / tài khoản**
- [ ] Mac (Apple Silicon) + Xcode mới nhất
- [ ] iPad M1 trở lên, iOS 17+ (ghi rõ model + version)
- [ ] Apple ID + Apple Developer Program (99$/năm) — cần cho IPA ký 1 năm
- [ ] Cài StikDebug trên iPad, thử bật JIT cho một app sideload bất kỳ

**Tài liệu phải đọc**
- [ ] `utmapp/UTM` — `Documentation/iOSDevelopment.md`, `scripts/`, `patches/`
- [ ] UTM docs: Display (VirGL/Venus), Linux guest support
- [ ] `ptitSeb/box64` — box64 + Wine (đọc cả `docs/WINEWOW64.md` nếu có)
- [ ] `Hangover` (Wine ARM64 + box64) — tham chiếu cách ghép Wine/box64
- [ ] `doitsujin/dxvk` — yêu cầu Vulkan
- [ ] Winlator source (`brunodev85/winlator`) — **chỉ để tham chiếu preset và cách mount prefix**, không port code

**Bộ game test (tự lo license, ưu tiên free)**
- 2D: Cave Story (freeware), Undertale demo
- DX9: TrackMania Nations Forever (free), Portal 2 (nếu có)
- DX11: Skyrim LE / Dark Souls PTDE / indie nhẹ
- DX12: 1 title nhẹ, chỉ để biết nó fail

**Quyết định cần chốt**
- [ ] iOS tối thiểu (đề xuất 17.0)
- [ ] iPad-only hay iPhone
- [ ] Có làm backend Remote Play (hướng A) song song không
- [ ] Tên app

---

## Rủi ro & đối sách

| Rủi ro | Xác suất | Ảnh hưởng | Đối sách |
|---|---|---|---|
| Venus + MoltenVK thiếu feature → DXVK fail | Trung bình | **Chết hướng C** | Spike ở M0; fallback WineD3D; kill criteria ở M3 |
| Wine ARM64 chưa ổn định | Trung bình | Chậm tiến độ | Dùng Hangover patchset; đóng góp upstream |
| box64 sai với game có anti-cheat/DRM | Cao | Mất một số game | Ghi vào compat DB, không cố |
| Apple siết sideload/JIT | Thấp–TB | Mất kênh phân phối | Giữ code mở, hỗ trợ TrollStore, build alternative marketplaces (EU) |
| Rootfs quá lớn / tải chậm | TB | UX kém | Cắt gói, chia layer, cache |
| Nhiệt/pin | Cao | Trải nghiệm | fps cap 30, hạ res, cảnh báo người dùng |
| Một mình làm quá lâu | Cao | Bỏ dở | Làm M2 rồi phát hành "beta game 2D" để có phản hồi |

---

## Định nghĩa "xong" của bản 1.0

- Cài IPA → onboarding JIT → thêm 1 game từ Files → chơi 45 phút không crash.
- Có ít nhất **10 game trong compat DB** chạy ≥ 30fps trên iPad M1.
- Import/export container, backup save.
- Log + crash report xuất được.
- Tài liệu: cài đặt, thêm game, preset, xử lý lỗi thường gặp.
- Source QEMU fork công bố (GPLv2).
