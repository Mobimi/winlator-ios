# 02 — Kiến trúc

## 1. Nguyên tắc thiết kế

1. **iOS chỉ chạy đúng một thứ: QEMU.** Mọi thứ Windows/Linux nằm trong guest. Không có lớp syscall tự viết, không có loader ELF tự viết.
2. **Guest là "hộp đen" có thể thay phiên bản.** Rootfs build sẵn, versioned, tải/cập nhật độc lập với app.
3. **App không bao giờ để lộ desktop.** Guest khởi động thẳng vào `cellar-session` (gamescope), chỉ chạy đúng một game.
4. **Mỗi game = một container = một prefix + một profile.** Không dùng chung prefix (tránh hỏng registry, tránh xung đột DLL).
5. **Không phá upstream.** Fork UTM giữ nguyên cấu trúc để rebase được; phần của ta nằm ở lớp `Cellar*` + patch tối thiểu.

---

## 2. Sơ đồ tổng

```
┌──────────────────────────── iOS app process ──────────────────────────────┐
│ Cellar.app (SwiftUI)                                                       │
│  ├─ Library / ContainerEditor / Overlay / Settings                         │
│  ├─ GamepadBridge        (GameController.framework → packet)               │
│  ├─ SessionController    (state machine: boot → launch → play → suspend)   │
│  └─ EngineHost (ObjC++)                                                    │
│       ├─ QEMULauncher   → spawn QEMU process (helper)                      │
│       ├─ QEMURenderServer → Metal surface, SPICE/virgl client              │
│       └─ VirtioSerialClient → /dev/vport… ↔ cellar-agent                   │
└───────────────┬──────────────────────────┬────────────────────────────────┘
                │ QEMU monitor/SPICE       │ shared memory (framebuffer/GPU)
┌───────────────▼──────────────────────────▼────────────────────────────────┐
│ QEMU (UTM fork) — process riêng, có JIT (CS_DEBUGGED)                      │
│  vCPU ARM64 × N (TCG)                                                      │
│  VirtIO-GPU (virglrenderer + Venus) ──► MoltenVK ──► Metal                 │
│  VirtIO-net (user-mode)  VirtIO-blk (qcow2)  VirtIO-serial  SPICE audio    │
└───────────────┬───────────────────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────── Linux ARM64 guest (Debian) ───────────┐
│ systemd → cellar-session.service                                           │
│  ├─ gamescope (Wayland/X11, fullscreen, không cursor desktop)              │
│  ├─ Xwayland → Wine ARM64 (win64)                                          │
│  │    └─ box64 wraps x86_64 PE  →  game.exe                                │
│  │         └─ d3d11.dll = DXVK  →  Vulkan → Venus                         │
│  ├─ PulseAudio (null sink + SPICE)                                         │
│  └─ cellar-agent (virtio-serial): launch/kill/snapshot/log/input           │
└───────────────────────────────────────────────────────────────────────────┘
```

Vì sao có **2 process** (app + QEMU)? Đây là cách UTM làm: QEMU cần `CS_DEBUGGED` và cần crash isolation. App UI chết không kéo VM chết; QEMU chết thì app báo lỗi và restart. Trên iOS, spawn process con **chỉ hoạt động khi sideload** (đúng thị trường của ta) — và UTM đã chứng minh nó chạy.

---

## 3. Thành phần

### 3.1 Frontend (SwiftUI) — phần ta viết nhiều nhất

| Màn hình | Nội dung |
|---|---|
| Library | Grid game (cover art tự lấy từ EXE icon hoặc thư mục), nút Play, dung lượng, lần chơi cuối |
| Import | Chọn `.exe`/`.zip`/thư mục qua document picker → copy vào container |
| Container editor | Giống Winlator: DXVK version, box64 preset, độ phân giải, fps cap, backend (DXVK/WineD3D), âm thanh, ngôn ngữ, `WINEDLLOVERRIDES`, env vars |
| Play | Surface Metal + overlay (nút pause, snapshot, keyboard, gamepad mapping, FPS/RAM HUD) |
| Diagnostics | Log Wine/box64/DXVK stream realtime, nút "export log", compat report |

UI cần **chạy được trước khi engine xong** → dùng mock engine, import JSON profile.

### 3.2 EngineHost

- `CellarEngine.h/.mm`: API C/ObjC++ thuần, không lộ QEMU ra Swift.
- Hợp đồng tối thiểu:

```objc
@interface CellarEngine : NSObject
- (BOOL)prepareContainer:(CellarContainerSpec *)spec error:(NSError **)err;
- (BOOL)bootWithError:(NSError **)err;                  // VM lên, agent handshake
- (BOOL)launchGameAtPath:(NSString *)guestPath
                   args:(NSArray<NSString *> *)args
                  error:(NSError **)err;
- (void)sendGamepadState:(CellarGamepadState)state;
- (BOOL)saveSnapshotNamed:(NSString *)name error:(NSError **)err;
- (BOOL)restoreSnapshotNamed:(NSString *)name error:(NSError **)err;
- (void)shutdown;
@property (readonly) CellarEngineStats stats;           // fps, cpu, ram, gpu backend
@end
```

### 3.3 Fork UTM — lấy gì, bỏ gì

**Giữ nguyên (không sửa):**
- `QEMUHelper`, `QEMULauncher`, `QEMURenderServer` (cơ chế process + render + JIT).
- QEMU target `aarch64-softmmu`, VirtIO-GPU, virglrenderer, Venus, SPICE, VirtIO-serial.
- Cơ chế xin JIT / `dynamic-codesigning` / TrollStore/HVF path.
- Script build QEMU cho iOS (`scripts/`, `patches/`).

**Sửa tối thiểu:**
- Thêm `cellar-agent` channel (virtio-serial) — thực chất chỉ là plumbing, agent nằm trong guest.
- Thêm API snapshot không cần UI UTM.
- Bật/tắt nhanh GPU backend, đổi resolution runtime (UTM đã có dynamic resolution).
- Thêm hook đọc thống kê (fps, thời gian frame).

**Bỏ (không build vào app):**
- Toàn bộ UI UTM (SwiftUI views), VM wizard, macOS target, scripting/UTM Server, USB sharing.
- Các target QEMU không cần (`x86_64-softmmu` nếu đi hướng C thuần ARM64) → giảm size đáng kể.

> Lưu ý license: QEMU GPLv2 → fork phải public. Đặt repo `cellar-engine` public, app UI có thể đóng.

### 3.4 Hiển thị

Ba lựa chọn, dùng **kết hợp**:

| Kênh | Dùng cho | Độ trễ |
|---|---|---|
| **VirtIO-GPU scanout + Metal** (UTM render server) | Toàn bộ hình ảnh game | ~2–3 frame |
| SPICE display | Fallback/debug, chụp màn hình | ~3–5 frame |
| Metal layer trực tiếp (zero-copy IOSurface) | Tối ưu sau M3 | ~1–2 frame |

Mục tiêu M1: hiển thị được desktop Linux 60fps ở 1280×720. M3: game 3D chạy qua Venus và composite qua Metal, đo được frame time.

### 3.5 Âm thanh

Guest PulseAudio → SPICE audio channel → `AVAudioEngine` (iOS). Độ trễ chấp nhận 30–60ms. Nếu SPICE audio không ổn: thay bằng ring buffer qua virtio-serial (PCM thô), đơn giản hơn nhưng tốn CPU.

### 3.6 Input — phần "ăn tiền" của app game

```
GCController (Xbox/PS/DualSense/Backbone)
  → GamepadBridge (Swift, 120Hz poll hoặc valueChanged)
  → packet 32 byte qua virtio-serial
  → cellar-agent → uinput device (VID/PID giả Xbox 360)
  → Wine xinput1_3 → game
```

Packet:

```c
struct cellar_pad_pkt {
  uint8_t  type;        // 1 = state
  uint8_t  seq;
  uint16_t buttons;     // A B X Y LB RB Back Start LS RS Dpad...
  int16_t  lx, ly, rx, ry;   // -32768..32767
  uint8_t  lt, rt;      // 0..255
  uint8_t  reserved[20];
};                      // 32 byte, gửi mỗi 8ms
```

- Guest tạo uinput với `ABS_X/ABS_Y/ABS_RX/ABS_RY`, `ABS_Z/ABS_RZ`, `BTN_*`, và **ID Xbox 360** → Wine nhận là XInput, game thấy tay cầm chuẩn. Đây là cách Winlator/Steam Deck làm.
- Touch overlay (khi không có tay cầm): nút ảo + joystick ảo → cùng packet, thêm `type=2` với toạ độ normalized.
- Bàn phím: `type=3`, scancode set 1 → guest `uinput` keyboard. Cần cho game cũ và để nhập tên nhân vật.

### 3.7 Guest rootfs

| Thành phần | Nguồn | Ghi chú |
|---|---|---|
| Base | Debian 12/13 arm64 minimal | ~250MB |
| Kernel | Debian arm64 `linux-image-arm64` hoặc kernel tự build (nhỏ hơn, có VirtIO/Venus) | bật `CONFIG_DRM_VIRTIO_GPU`, `CONFIG_VIRTIO_*`, `CONFIG_FUSE_FS` |
| Mesa | bản có Venus (`mesa-vulkan-drivers`, `VIRTGPU_DEBUG=venus`) | phải verify Venus hoạt động |
| Wine | Wine 10.x arm64 (hoặc Hangover patchset) | win64 ARM64, không cần wow64 |
| box64 | build từ source, bật `-DARM64 -DBOX64_WINE` | tuning riêng cho game |
| DXVK | 2.x, bản x86_64 PE | copy vào prefix/`system32` |
| VKD3D-Proton | tuỳ chọn | D3D12 |
| gamescope | Debian package | fullscreen, giới hạn fps, FSR |
| PulseAudio | Debian | sink SPICE |
| cellar-agent | ta viết (C, ~1k dòng) | virtio-serial, spawn Wine, đọc log |

Kích thước ước tính: **1.2–1.8GB** (chưa game), nén còn ~600–900MB. Có thể cắt: bỏ docs, bỏ compiler, bỏ các locale.

Phân phối rootfs: file `.img.zst` tải lần đầu (hoặc nhúng trong IPA nếu chấp nhận IPA to). Có checksum + version + migration script.

### 3.8 `cellar-agent` protocol

JSON Lines qua `/dev/vport0p1` (hoặc 2 chiều: control + log):

```json
{"cmd":"hello","proto":1}
{"ok":true,"agent":"0.1.0","distro":"debian13","gpu":"venus"}
{"cmd":"launch","exe":"/games/foo/foo.exe","env":{"DXVK_HUD":"fps"},"profile":"dxvk-2.4"}
{"ok":true,"pid":1234}
{"cmd":"stat"} → {"ok":true,"fps":58,"cpu":0.7,"ram_mb":2100}
{"cmd":"snapshot","name":"quick"} / {"cmd":"restore","name":"quick"}
{"cmd":"kill"} / {"cmd":"shutdown"}
{"event":"game-exit","code":0}
{"event":"log","stream":"wine","line":"..."}
```

Agent là **process duy nhất** ta viết trong guest. Nó không can thiệp vào Wine, chỉ spawn/kill và đọc stdout.

---

## 4. Luồng khởi động một game

```
t=0.0   Người dùng bấm Play
t=0.1   App tạo/ mở container (qcow2 overlay), chọn profile
t=0.2   Khởi động QEMU (nếu chưa chạy) — JIT check, nếu thiếu → hướng dẫn StikDebug
t=1–5s  Kernel boot (TCG, ~2–4s trên M-series)
t=5–8s  systemd → cellar-session → gamescope → agent ready
t=8s    App ↔ agent handshake
t=8–12s agent: wineboot (nếu prefix mới) / wine game.exe
t=12–20s Game hiện frame đầu
─── chơi ───
Pause   → QEMU stop vCPU (pause tức thì)
Resume  → QEMU cont
Exit    → agent kill → wine chờ → QEMU shutdown → giữ qcow2
```

**Tối ưu quan trọng:** giữ VM sống giữa các game (nếu RAM cho phép) → chuyển game chỉ mất 2–5s. Đây là lợi thế lớn so với "mỗi game một lần boot" của Winlator.

### Snapshot — nói thật về giới hạn

- **RAM snapshot (savevm)** với VirtIO-GPU/Venus **có thể không restore đúng** (state GPU nằm ở host). Kế hoạch:
  - M4: snapshot = RAM + disk (thử), nếu GPU lỗi → đánh dấu "không hỗ trợ GPU".
  - Fallback chắc chắn chạy: **suspend process** (app còn sống) + **disk snapshot** (khôi phục bằng boot lại 10–20s).
- Đừng hứa "save state như giả lập Nintendo" cho tới khi test xong. Hứa: "resume nhanh" trước, "save state" sau.

---

## 5. Mô hình dữ liệu

```swift
struct Container: Codable, Identifiable {
    let id: UUID
    var name: String
    var gameTitle: String
    var coverPath: String?
    var diskImage: String            // qcow2 overlay
    var prefixPath: String           // trong guest
    var profile: Profile
    var lastPlayed: Date?
    var playSeconds: Int
    var compatNote: String?
}

struct Profile: Codable {
    var resolution: CGSize = .init(width: 1280, height: 720)
    var fpsCap: Int = 60
    var graphics: Graphics = .dxvk
    var dxvkVersion: String = "2.4"
    var box64Preset: Box64Preset = .compat     // .fast /.compat /.safe
    var wineDllOverrides: [String: String] = [:]
    var env: [String: String] = [:]
    var audioLatencyMs: Int = 40
    var gamepadLayout: GamepadLayout = .xbox
}

enum Graphics: String, Codable { case dxvk, wined3d, vkd3d }
```

`Box64Preset` map sang env: `BOX64_DYNAREC_BIGBLOCK`, `BOX64_DYNAREC_STRONGMEM`, `BOX64_DYNAREC_SAFEFLAGS`, `BOX64_DYNAREC_FASTNAN`… (đây là các knob Winlator expose; ta expose cùng bộ nhưng đặt tên dễ hiểu hơn).

---

## 6. Cấu trúc repo

```
winlator-ios/
├── README.md
├── docs/
│   ├── 01-kha-thi-ky-thuat.md
│   ├── 02-kien-truc.md
│   └── 03-roadmap.md
├── app/                        # Xcode project (XcodeGen)
│   ├── project.yml
│   └── Cellar/
│       ├── App/                # @main, AppState
│       ├── Models/             # Container, Profile, CompatDB
│       ├── Services/           # ContainerStore, ImportService, EngineService
│       ├── Engine/             # CellarEngine.h/.mm, EngineHost, MockEngine
│       ├── Render/             # MetalView, SPICEClient, FrameStats
│       ├── Input/              # GamepadBridge, TouchOverlay, KeyMap
│       └── Views/              # Library, ContainerEditor, Play, Settings, Diagnostics
├── engine/                     # fork UTM (submodule) + patch của ta
│   ├── patches/cellar/*.patch
│   └── scripts/build-qemu-ios.sh
├── guest/                      # rootfs build (chạy trên Linux/Docker)
│   ├── Dockerfile
│   ├── build-rootfs.sh
│   ├── packages.txt
│   ├── overlay/
│   │   ├── cellar-agent/       # C source
│   │   ├── cellar-session     # init script: gamescope + wine
│   │   └── etc/               # systemd units, pulse config, wine tweaks
│   └── manifest.json           # version + checksum
├── tools/
│   ├── ipa-sign.sh             # ký sideload, kiểm tra entitlements
│   ├── bench/                  # đo fps/frame time trong guest
│   └── compat/                 # script chạy bộ game test, xuất report
└── .github/workflows/
    ├── build-app.yml           # macOS runner
    └── build-rootfs.yml        # ubuntu runner
```

---

## 7. Build pipeline

| Bước | Ở đâu | Sản phẩm |
|---|---|---|
| Build QEMU + virglrenderer + MoltenVK cho iOS arm64 | macOS (script có sẵn của UTM) | `.a` / framework |
| Build app | macOS + XcodeGen | `Cellar.app` |
| Build rootfs | Linux/Docker | `rootfs.img.zst` + manifest |
| Đóng gói | macOS | `.ipa` (unsigned) + `.ipa` đã ký dev |
| Kiểm tra | thiết bị thật | báo cáo JIT, fps, lỗi DXVK |

Bắt buộc có **máy Mac** và **1 iPad thật** (M1 trở lên nếu muốn thử HVF). Simulator **không** chạy được QEMU/JIT hữu ích.

---

## 8. Quyết định còn mở

| # | Câu hỏi | Ảnh hưởng |
|---|---|---|
| 1 | iOS tối thiểu 17.0 hay 18.0? | StikDebug/TrollStore support, API Metal |
| 2 | Chỉ iPad, hay cả iPhone? | RAM, nhiệt, UI overlay |
| 3 | Có làm nhánh **B** (Windows ARM64 + Prism) không? | +2 tháng, mở đường cho HVF/M1 iPad |
| 4 | Có làm backend **A** (stream PC) không? | +2 tháng, có sản phẩm dùng được ngay |
| 5 | Tên app/ thương hiệu | trước khi phát hành |
| 6 | Mô hình bán: một lần / subscription / Patreon | kênh phân phối sideload |

Khuyến nghị: chốt (1) iOS 17+, (2) iPad-first, (3) không làm B ngay, (4) làm A sau M4 như tính năng "Remote Play" để có doanh thu sớm.
