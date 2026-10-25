# Cellar (codename) — chơi game Windows trên iOS

> Mục tiêu: một app kiểu **Winlator** trên iOS. Mở app → thư viện game → bấm Play → game `.exe` chạy fullscreen, tay cầm hoạt động, có overlay save/resume.
> **Không** phải app "mang Windows lên iPad để làm việc". Windows ở đây chỉ là thứ bị giấu bên dưới, phục vụ đúng một việc: chạy game.

---

## TL;DR (đọc 30 giây)

| Câu hỏi | Trả lời ngắn |
|---|---|
| Làm được không? | **Được**, nhưng chỉ ở dạng **sideload** (AltStore/SideStore/StikDebug/TrollStore). |
| Lên App Store được không? | Bản App Store **không chơi game 3D được** — thiếu JIT, QEMU phải chạy interpreter chậm 10–50×. |
| Kiến trúc khả thi nhất | Fork **UTM/QEMU** → VM **Linux ARM64** → **Wine ARM64 + box64** → **DXVK → Vulkan (Venus) → Metal**. |
| Hiệu năng kỳ vọng | Game 2D/indie/2010–2015 @720p trên iPad M-series: **chơi được**. AAA 2019+: **không**. |
| Thời gian tới MVP | **9–12 tháng** cho 1 người full-time; **5–6 tháng** cho team 2–3 người. |
| Điểm ăn tiền so với Winlator | **Snapshot VM** = save/resume tức thì, mỗi game một "container" riêng, UI thuần game. |

### Cấu hình hiện tại của bạn (đã điều chỉnh)

| | |
|---|---|
| Máy build | **Không có Mac** → build bằng GitHub Actions (macOS runner) |
| Máy chơi | **iPhone 12 Pro Max** (A14, 6GB, 60Hz) |
| Kênh cài | Sideloadly trên Windows + StikDebug để bật JIT |
| Kỳ vọng | 2D/visual novel/DX9 cũ ở 720p 30fps. **Không** AAA. Muốn chơi game nặng → cần iPad M1+ hoặc stream từ PC |

👉 **Bắt đầu tại [`docs/00-bat-dau-tu-day.md`](docs/00-bat-dau-tu-day.md)** — hướng dẫn từng bước, không cần biết code.

> ⚠️ **Nếu mục tiêu là game 3D hiện đại kiểu MiSide ("Mita")**: máy ảo local **không chạy nổi** trên iPhone 12 Pro Max. Đọc [`docs/05-mita-miside-tren-iphone.md`](docs/05-mita-miside-tren-iphone.md) — cách chơi 60 fps ngay bằng stream từ laptop.

---

## 1. Vì sao không "port Winlator sang iOS" theo cách thông thường?

Winlator trên Android là tập hợp:

```
Wine (ARM64)  +  box64 (dịch x86_64 → ARM64, JIT)
              +  DXVK / VKD3D (D3D → Vulkan)
              +  Turnip (Vulkan driver cho Adreno)
              +  proot (giả lập root Linux)  +  XServer XSDL / Termux:X11  +  PulseAudio
```

Android cho phép **chạy tiến trình Linux thật** (proot, fork/exec, `/proc`, `mmap` tự do) và cho phép **JIT** (Android không cấm). iOS cấm gần như tất cả những thứ đó:

1. **Không có JIT** cho app thường → box64/DXVK/QEMU không thể sinh mã máy lúc chạy.
2. **Không có tiến trình thật** → Wine cần `wineserver` + `fork/exec`; trên iOS bạn chỉ có 1 process duy nhất (trừ khi tự viết loader nội bộ kiểu a-Shell).
3. **Không có Linux syscall** → box64/Wine là binary Linux ELF, cần một lớp dịch syscall (iSH làm việc này cho x86 32-bit, nhưng chậm và không có bản ARM64 64-bit tử tế).

→ Vì vậy "port thẳng Winlator" = viết lại một nhân Linux ở userspace + tự viết loader + port Wine. Đó là dự án nhiều năm.

**Cách lách:** đừng cố chạy Linux *trên* iOS. Chạy **một máy ảo Linux ARM64** bằng QEMU (JIT) — đúng thứ UTM đã làm được — rồi nhét nguyên stack Winlator vào trong máy ảo đó. iOS chỉ thấy "một app đang chạy QEMU", không thấy Linux.

---

## 2. Bốn hướng đi, so sánh thẳng

| | A. Stream từ PC | B. Windows ARM64 VM | **C. Linux ARM64 + Wine + box64** | D. Native syscall layer |
|---|---|---|---|---|
| Cách chạy | Moonlight/Sunshine tới PC | QEMU + Windows 11 ARM64 + Prism | QEMU + Debian ARM64 + Wine + box64 | box64/Wine chạy trực tiếp, tự viết lớp syscall |
| CPU | Remote | TCG (hoặc HVF nếu M1 iPad + TrollStore) | TCG + box64 (2 lớp dịch) | box64 (1 lớp dịch) |
| GPU | Remote | VirtIO-GPU, D3D experimental | DXVK → Vulkan Venus → Metal | DXVK → MoltenVK |
| Tương thích game | ~100% | Trung bình (Prism + driver non) | Tốt (đúng stack Winlator) | Tốt |
| Tốc độ | 60 fps | Khá (nếu HVF) / chậm (nếu TCG) | Trung bình | Tốt nhất |
| Công sức | 2–3 tháng | 3–6 tháng | **9–12 tháng** | 24 tháng+ |
| App Store | ✅ Được | ❌ | ❌ | ❌ |
| Rủi ro | Cần PC | Driver GPU non, license Windows | Venus/DXVK lỗi từng game | Gần như không có tiền lệ |

**Khuyến nghị: C.** Lý do:

- Là con đường duy nhất giữ được **tương thích kiểu Winlator** (DXVK, box64 tuning, preset per-game) mà không phải viết nhân Linux.
- Tái sử dụng được **UTM** (Apache-2.0, frontend + QEMU fork đã build sẵn cho iOS, đã có SPICE, đã có VirtIO-GPU/Venus, đã có cơ chế JIT sideload).
- B và C **dùng chung engine VM** → có thể làm B trước như bước đệm kỹ thuật (chứng minh VM + GPU + input chạy), rồi nâng lên C.
- A là fallback thương mại: cùng một UI, thêm backend "Remote PC" để có sản phẩm dùng được ngay trong lúc C còn đang xây.

---

## 3. Kiến trúc chốt (tóm tắt)

```
iOS app (SwiftUI + Metal)
 ├── Library / Container / Per-game profile
 ├── QEMU (UTM fork) ── vCPU ARM64 (TCG JIT)
 │     ├── VirtIO-GPU ─► virglrenderer + Venus ─► MoltenVK/ANGLE ─► Metal
 │     ├── SPICE ─► hiển thị + âm thanh (CoreAudio)
 │     └── VirtIO-serial ─► cellar-agent (trong guest)
 └── GamepadBridge (GameController.framework) ─► agent ─► uinput ─► XInput

Guest: Debian ARM64 (rootfs tự build)
 ├── gamescope/X11 (fullscreen, không desktop)
 ├── Wine ARM64  +  box64  ─► game.exe
 ├── DXVK (x86_64 PE, qua box64) ─► Vulkan ─► Venus
 ├── PulseAudio ─► SPICE
 └── cellar-agent: nhận lệnh launch/kill/snapshot, đọc log, nhận input
```

Chi tiết đầy đủ: [`docs/02-kien-truc.md`](docs/02-kien-truc.md)

---

## 4. Tài liệu trong repo

| File | Nội dung |
|---|---|
| [`docs/00-bat-dau-tu-day.md`](docs/00-bat-dau-tu-day.md) | **Bắt đầu tại đây** — build bằng GitHub Actions, cài IPA bằng Sideloadly, bật JIT bằng StikDebug |
| [`docs/01-kha-thi-ky-thuat.md`](docs/01-kha-thi-ky-thuat.md) | Rào cản cứng của iOS, JIT, App Store, GPU, ngân sách hiệu năng, pháp lý |
| [`docs/02-kien-truc.md`](docs/02-kien-truc.md) | Kiến trúc chi tiết, luồng khởi động, input/display/audio, snapshot, cấu trúc repo |
| [`docs/03-roadmap.md`](docs/03-roadmap.md) | Mốc M0→M5, tiêu chí nghiệm thu, ước lượng thời gian, việc cần chuẩn bị |

---

## 5. Trạng thái repo

```
[x] Phân tích khả thi
[x] Chốt kiến trúc
[x] Roadmap + tiêu chí nghiệm thu
[x] App shell: thư viện game, cấu hình container, overlay, kiểm tra JIT, tay cầm
[x] Pipeline build IPA tự động bằng GitHub Actions (không cần Mac)
[ ] Cài được app lên iPhone 12 Pro Max  ← bạn đang ở đây
[ ] M0 — spike GPU bằng UTM gốc (chứng minh DXVK + Venus chạy)
[ ] M1 — VM Linux ARM64 boot + hiển thị + tay cầm
[ ] M2 — Wine chạy .exe đầu tiên
[ ] M3 — GPU (Venus + DXVK)
[ ] M4 — UX kiểu Winlator (library, profile, overlay, snapshot)
[ ] M5 — tương thích + hiệu năng
```

---

## 6. Những gì dự án này **không** làm

- Không đưa desktop Windows ra cho người dùng (không phải "Windows trên iPad").
- Không kèm Windows ISO, không kèm game, không kèm key bản quyền.
- Không hứa chạy AAA mới. Nếu game bạn muốn chơi ra sau 2018 và nặng 3D, hãy dùng hướng A (stream).
- Không dùng chứng chỉ enterprise lậu để phát hành. Chỉ sideload hợp lệ (Apple ID cá nhân / dev account / AltStore PAL ở EU).
