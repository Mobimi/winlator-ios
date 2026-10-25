# 01 — Khả thi kỹ thuật: iOS chặn gì, và ta lách bằng gì

Tài liệu này trả lời trung thực: **cái gì làm được, cái gì không, và tại sao**. Mọi con số hiệu năng là ước lượng có suy luận, không phải benchmark — benchmark thật chỉ có sau M1.

---

## 0. Ba rào cản cứng

| # | Rào cản | Ảnh hưởng | Cách lách của dự án |
|---|---|---|---|
| 1 | **Không có JIT** (trừ khi sideload + debugger) | box64, DXVK, QEMU TCG đều cần sinh mã lúc chạy | Yêu cầu sideload + JIT enabler; build 2 biến thể app |
| 2 | **Không có tiến trình/fork** | Wine cần `wineserver`, `fork/exec`, `/proc` | Đưa toàn bộ stack vào **VM Linux** → có kernel thật, có tiến trình thật |
| 3 | **Không có driver GPU cho Windows/Linux guest** | Game cần D3D → phải dịch sang Metal | **DXVK → Vulkan (Venus) → virglrenderer → Metal**; fallback WineD3D → OpenGL (virgl) |

Cả ba đều được giải quyết bởi **một** quyết định: dùng QEMU (UTM fork) làm nền, thay vì cố chạy Linux trực tiếp trên iOS.

---

## 1. Rào cản 1 — JIT

### iOS bảo vệ bộ nhớ thế nào

Trên iOS, mọi trang nhớ đều **W^X** (write hoặc execute, không bao giờ cả hai) và mọi code phải được ký. Tiến trình bình thường **không** được `mmap(PROT_EXEC)` vùng nhớ vừa ghi → mọi JIT engine (V8 cũ, LuaJIT, QEMU TCG, box64) chết ngay khi khởi động.

Có đúng một ngoại lệ: tiến trình bị **debugger attach** sẽ có cờ `CS_DEBUGGED`, và khi đó `mach_vm_protect(..., VM_PROT_EXECUTE)` được phép. Đây chính là cơ chế UTM dùng.

### Các cách bật JIT trên máy không jailbreak (2026)

| Cách | Cần gì | Hạn chế |
|---|---|---|
| **StikDebug** (khuyến nghị) | Cài app StikDebug + profile VPN trên máy; app tự attach debugger vào app của bạn | Phải bật lại mỗi lần chạy app (semi-tethered) |
| SideStore / AltStore + JIT | PC/Mac chạy AltServer, hoặc SideStore tự làm | Cần refresh 7 ngày; cần mạng |
| **TrollStore** | iOS trong khoảng hỗ trợ của TrollStore | Chỉ một số firmware; đổi lại được cả `dynamic-codesigning` + Hypervisor (M1 iPad) |
| Jailbreak | AppSync Unified | Máy hiếm, không phải thị trường chính |

**Hệ quả sản phẩm:** app của bạn **không thể** phát hành qua App Store ở bản dùng được. Kênh phân phối là `.ipa` sideload. Điều này kéo theo:

- Không có doanh thu App Store; bán kiểu "mua IPA" / Patreon / AltStore PAL (EU).
- Người dùng phải có Apple ID + máy tính (hoặc SideStore) → tệp khách hàng là dân power-user.
- Chữ ký hết hạn 7 ngày (Apple ID free) hoặc 1 năm (Developer Program 99$/năm).
- **Không** dùng chứng chỉ enterprise bán tràn lan: Apple revoke hàng loạt, app chết giữa chừng, và vi phạm điều khoản.

### Nếu không có JIT thì sao?

| Chế độ | Engine | Tốc độ tương đối | Dùng được cho |
|---|---|---|---|
| Có JIT | QEMU TCG + box64 | 0.12–0.4× native | Game 3D cũ, indie |
| Không JIT | QEMU interpreter (kiểu UTM SE) | 0.01–0.05× native | DOS, Win95/98, visual novel 2D |
| Không JIT | box64 interpreter mode | ~0.05–0.15× | Ứng dụng nhỏ, game 2D rất nhẹ |

→ Vẫn nên build **"SE mode"** (không JIT) để: (a) lên được App Store/TestFlight như demo, (b) phục vụ game 2D/DOS, (c) làm marketing. Nhưng đừng kỳ vọng nó chạy được game 3D.

---

## 2. Rào cản 2 — tiến trình

Wine không phải một chương trình, nó là **một hệ điều hành giả**:

- `wineserver` là tiến trình riêng, giữ registry, handle, window manager.
- Mỗi app Windows là một tiến trình Unix (Wine dùng `fork`/`exec` qua `ntdll`).
- Cần `/proc/self/maps`, `/tmp`, shared memory, unix socket, signal, `mmap(MAP_FIXED)`.

iOS cấm `fork`, cấm `exec` binary ngoài bundle, `/proc` gần như rỗng. Các app như **a-Shell** lách bằng cách tự viết loader nạp ELF/Mach-O vào chính process của mình — nhưng đó là cả một dự án riêng, và Wine cần nhiều process thật.

**Kết luận:** chạy Wine trực tiếp trên iOS = viết lại kernel Linux ở userspace. Không làm trong giai đoạn này.

**Giải pháp:** VM. Trong VM Linux ARM64, `fork`/`exec`/`wineserver` hoạt động bình thường vì guest có kernel thật. iOS chỉ thấy QEMU gọi `mmap` — hợp lệ.

---

## 3. Rào cản 3 — GPU (phần khó nhất, và là phần quyết định "chơi được hay không")

### Chuỗi dịch

```
Game gọi D3D9/10/11/12
   └─ DXVK / VKD3D  (DLL x86_64, chạy qua box64)
        └─ Vulkan API
             └─ Mesa "Venus" driver (guest, ARM64)
                  └─ VirtIO-GPU (virglrenderer, host)
                       └─ Vulkan host = MoltenVK (hoặc ANGLE/Metal)
                            └─ Metal (A-series/M-series GPU)
```

Mỗi mũi tên là một chỗ có thể vỡ. Nhưng đây **đúng là** kiến trúc UTM đang hỗ trợ: docs UTM ghi rõ Linux guest có **VirGL (OpenGL)** và **VirtIO Venus (Vulkan 1.3)**, backend "Default"/"ANGLE (Metal)" trên iOS.

### Ba đường GPU, chọn theo game

| Đường | Chất lượng | Tương thích | Ghi chú |
|---|---|---|---|
| **DXVK → Vulkan → Venus** | Tốt (D3D9/10/11 gần đúng) | Trung bình–tốt | Đường chính. Cần DXVK 2.x + Vulkan 1.3 + descriptor indexing |
| WineD3D → OpenGL → virgl | Trung bình, chậm hơn | Rộng (D3D9 cũ) | Fallback tự động khi DXVK crash |
| VKD3D-Proton → Vulkan | D3D12 | Thấp | Chỉ thử với game DX12 nhẹ |

### Những gì chắc chắn sẽ vỡ (phải test và ghi vào compat DB)

- Game dùng **D3D12 nặng** (sparse resources, mesh shader) → Venus/MoltenVK thiếu.
- Game dùng **anti-cheat kernel-level** (EAC/BattlEye/Vanguard) → không bao giờ chạy, không cố.
- Game **DX11 + compute nặng** → chậm, có thể sai hình.
- Game **64-bit only, >4GB RAM** → chạm jetsam của iOS.
- **Video cutscene** (Media Foundation) → cần `mfplat` + codec; Wine chạy được một phần, thường phải cài `wmp10`/`quartz`.

### Vì sao vẫn đáng làm

Vì tập game "chơi được trên iPad" không phải AAA 2024. Nó là:

- Visual novel, RPG Maker, game 2D (Hollow Knight, Stardew, Undertale…) — nhẹ, chạy tốt.
- Game 3D 2008–2016 (Skyrim LE, GTA IV, Dark Souls 1, Portal 2, CS:GO cũ…) — mục tiêu chính.
- Indie DX9/DX11 nhẹ.

Đây đúng là tập game mà Winlator Android phục vụ tốt nhất.

---

## 4. Ngân sách hiệu năng (ước lượng có suy luận)

Giả định: iPad M2/M4, JIT bật, nhiệt độ ổn định (không throttle).

| Lớp | Hệ số | Ghi chú |
|---|---|---|
| ARM64 native | 1.00 | M4 ≈ desktop cao cấp 2021 |
| QEMU TCG ARM64→ARM64 | 0.30–0.60 | dịch cùng ISA nên khá; memory-heavy tệ hơn |
| box64 x86_64→ARM64 | 0.40–0.70 | rất tốt với game, tệ với code "lạ" |
| **Tổng C** | **≈ 0.12–0.40** | ví dụ: 0.4 × 0.6 = 0.24 |
| Windows ARM64 + Prism (B) | 0.50–0.80 | Prism tốt; nhưng GPU driver yếu |
| Direct trên iOS (D) | 0.40–0.70 | giả thuyết, chưa ai làm |

Diễn giải thực dụng:

- Game cần "Core i5 2013 + GTX 660" → iPad M2 chạy **~25–45 fps @720p low**. Chơi được.
- Game cần "i7 2018 + GTX 1060" → **<15 fps**. Không chơi được.
- Game 2D → luôn 60 fps (nghẽn ở GPU/khung hình, không ở CPU).

**Nghẽn thật sự thường là GPU, không phải CPU**, vì Venus→MoltenVK→Metal có overhead mỗi draw call. Vì vậy M3 (GPU) là mốc quyết định sản phẩm sống hay chết.

---

## 5. RAM, nhiệt, pin

- **Jetsam**: iOS kill app theo mức RAM. App sideload có entitlement được nhiều hơn app App Store, nhưng vẫn phụ thuộc máy. Ngân sách an toàn: **guest RAM 3–4 GB**, tổng process < 5–6 GB.
- **Nhiệt**: TCG đốt CPU liên tục → throttle sau 10–20 phút trên iPhone, tốt hơn trên iPad. Cần: giới hạn fps (30/60), hạ resolution, tắt thread thừa.
- **Pin**: chấp nhận "cắm sạc khi chơi". Đừng hứa pin.

---

## 6. Phân phối & pháp lý

| Vấn đề | Cách xử lý |
|---|---|
| QEMU là **GPLv2** | Công bố source của fork (kể cả phần sửa) khi phát hành. Dùng repo public. |
| UTM frontend **Apache-2.0** | Giữ NOTICE, ghi công. |
| Wine **LGPL-2.1** | Động, công bố bản sửa của Wine nếu có. |
| DXVK **zlib**, MoltenVK **Apache-2.0** | Ghi công. |
| Windows | **Không** phát hành kèm ISO/license. Người dùng tự lo nếu chọn hướng B. Hướng C không cần Windows. |
| Game | Không kèm, không link tải lậu. Chỉ import file người dùng có. |
| App Store | Bản JIT không thể. Bản SE có thể (tiền lệ: UTM SE đã được duyệt). |
| Apple Developer Program | Cần cho TestFlight/IPA ký 1 năm. |

---

## 7. Kết luận

1. **Khả thi về kỹ thuật**, với kiến trúc "VM Linux ARM64 + Wine + box64 + DXVK/Venus".
2. **Không khả thi** nếu mục tiêu là "App Store + game 3D". Hai mục tiêu này loại trừ nhau trên iOS.
3. **Rủi ro lớn nhất** không phải CPU, mà là **GPU path** (Venus + MoltenVK + DXVK) và **độ ổn định của Wine ARM64 + box64**. Phải làm M3 sớm để biết sống chết.
4. **Lợi thế cạnh tranh** so với Winlator: snapshot VM (save/resume tức thì), container per-game, UX thuần gamepad, không cần root/proot.
