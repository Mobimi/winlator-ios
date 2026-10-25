# 05 — MiSide ("Mita") trên iPhone 12 Pro Max: đường nào thật sự chạy

## Kết luận trước

> **MiSide không chạy được trên iPhone 12 Pro Max bằng máy ảo.**
> Không phải "chậm", mà là **không đạt ngưỡng tối thiểu** cả về CPU lẫn RAM.
> Đường chạy được: **stream từ laptop Windows của bạn** (laptop này chạy MiSide tốt).

---

## 1. MiSide cần gì, iPhone 12 Pro Max có gì

MiSide là game **Unity, DirectX 11, 3D góc nhìn thứ nhất**, ra cuối 2024. Cấu hình tối thiểu trên PC (theo Steam):

| | MiSide cần | iPhone 12 Pro Max sau khi qua 2 lớp dịch |
|---|---|---|
| CPU | ~Core i5-2500K (2011) | ≈ **50%** mức đó |
| RAM | 4 GB | guest chỉ được **2–3 GB** (iOS jetsam) |
| GPU | GTX 660 / HD 7870 | A14 4-core + 3 lớp dịch (DXVK → Venus → MoltenVK) |
| Ổ đĩa | vài GB | OK |

### Vì sao CPU chỉ còn ~50%

```
Game (x86_64)  →  box64 dịch sang ARM64      (mất ~50–60%)
               →  QEMU TCG dịch tiếp ARM64    (mất thêm ~40–60%)
```

A14 mạnh, nhưng **hai lần dịch** đưa nó về ngang một CPU desktop 2010. MiSide cần CPU 2011 → không đủ.

Thêm một chi tiết chí mạng: Unity dùng **Mono JIT**. Mono sinh mã x86 lúc chạy, rồi box64 phải dịch tiếp mã vừa sinh ra. JIT trong JIT là trường hợp tệ nhất của box64.

### Vì sao RAM là bức tường cứng

iOS giết app khi vượt hạn mức. Với iPhone 6 GB, app sideload thường chỉ dùng được **~3–3.5 GB**, trong đó QEMU + Linux + Wine chiếm ~0.8–1.2 GB → **game còn ~2 GB**. MiSide cần 4 GB.

Kết quả thực tế nếu vẫn thử: vào được menu, load scene rất lâu, chơi 3–10 fps, hoặc bị iOS kill giữa lúc load. **Không phải lỗi code — là giới hạn phần cứng.**

### Còn iPad thì sao?

| Máy | MiSide (dự đoán có cơ sở) |
|---|---|
| iPhone 12 Pro Max | ❌ Không chạy |
| iPad M1 (8 GB) | ⚠️ Có thể 15–30 fps @720p, RAM vẫn căng |
| iPad M4 (16 GB) | ✅ Khả năng cao 30–45 fps @720p, chưa test |

Không có gì đảm bảo cho tới khi làm xong M3. Đừng mua iPad chỉ vì dự án này.

---

## 2. Tin tốt: laptop của bạn chạy MiSide thoải mái

Mình vừa kiểm tra máy Windows đang dùng:

| | |
|---|---|
| CPU | Intel Core i5-7300HQ (4 nhân, 2.5 GHz) |
| GPU | **GeForce GTX 1050 Ti (4 GB)** + Intel HD 630 |
| RAM | 16 GB |
| OS | Windows 10 Pro |

- MiSide trên GTX 1050 Ti: **1080p high, khoảng 45–60 fps**. Thoải mái.
- GTX 1050 Ti có **NVENC** → stream 1080p60 không tốn CPU.
- i5-7300HQ khoẻ hơn mức tối thiểu của game.

→ Stream từ laptop sang iPhone sẽ cho **60 fps, độ trễ ~15–30 ms trong nhà**. Đây là cách chơi MiSide trên iPhone 12 Pro Max **ngay hôm nay**, không cần build gì.

---

## 3. Ba đường, chọn theo mục tiêu

| | Cách | Thời gian | Kết quả với MiSide |
|---|---|---|---|
| **A** | **Sunshine (PC) + Moonlight (iPhone)** | **15 phút** | ✅ 60 fps, chơi ngay |
| B | Steam Remote Play / Steam Link | 5 phút | ✅ 60 fps, chỉ game Steam |
| C | Cellar (máy ảo local) | 9 tháng | ❌ Không chạy trên máy này |

**Khuyến nghị: A.** Sau đó, nếu vẫn muốn làm Cellar, hãy đổi mục tiêu sang **game 2D/retro** — thứ máy ảo làm được — chứ đừng lấy MiSide làm lý do.

---

## 4. Cài stream trong 15 phút

### Trên laptop (Windows)

1. Tải **Sunshine**: `github.com/LizardByte/Sunshine/releases` → file `Sunshine-Windows-AMD64-installer.msi`.
2. Cài, mở **Sunshine** (nó chạy nền, icon ở khay hệ thống).
3. Mở `https://localhost:47990` → tạo tài khoản (chỉ dùng nội bộ, đặt gì cũng được).
4. Lấy IP laptop: mở PowerShell, gõ `ipconfig`, tìm `IPv4 Address` (thường `192.168.x.x`).
5. Nếu Windows Firewall hỏi → **Allow** cho cả Private và Public.

### Trên iPhone

1. Cài **Moonlight** từ App Store (miễn phí).
2. Mở Moonlight → bấm **+** → nhập IP laptop vừa lấy.
3. Moonlight hiện **mã PIN 4 số**.
4. Trên laptop: Sunshine web UI → tab **PIN** → nhập đúng mã đó → **Send**.
5. Trong Moonlight chọn **Desktop** để test trước, sau đó thêm game.

### Thêm MiSide vào Moonlight

- Cách nhanh: trong Moonlight chọn **Desktop** → mở Steam → chơi MiSide (stream cả màn hình).
- Cách gọn: Sunshine web UI → **Applications** → **Add New**:
  - Name: `MiSide`
  - Command: `C:\Program Files (x86)\Steam\steamapps\common\MiSide\MiSide.exe`
  - Working directory: thư mục chứa file exe
  - Sau đó MiSide hiện thành một tile riêng trong Moonlight.

### Cấu hình cho mượt

| Mục | Giá trị |
|---|---|
| Resolution | 1920×1080 |
| FPS | 60 |
| Bitrate | 20–30 Mbps (mạng nhà) |
| Video codec | HEVC (nếu iPhone nhận) → H.264 nếu giật |
| Frame pacing | On |
| Vsync | On |
| HDR | Off |

### Mạng (quan trọng nhất)

- Laptop nên **cắm dây Ethernet**; nếu không, để laptop và iPhone dùng **cùng một băng tần 5 GHz**.
- Tắt **MuMuPlayer** khi stream (nó đang có virtual display và ăn tài nguyên).
- Tránh xa router 2.4 GHz và tránh tải file lớn cùng lúc.
- Độ trễ mục tiêu: < 30 ms. Nếu > 50 ms → do Wi-Fi, không phải app.

### Tay cầm

Kết nối tay cầm với **iPhone** qua Bluetooth (Settings → Bluetooth). Moonlight sẽ chuyển nó thành Xbox controller cho game trên PC.

---

## 5. Còn Cellar thì sao?

Cellar vẫn dùng được, nhưng đổi mục tiêu cho đúng:

| Dùng Cellar để chơi | Khả thi trên iPhone 12 Pro Max |
|---|---|
| Game DOS / Win9x | ✅ |
| Visual novel, RPG Maker, Ren'Py | ✅ |
| Game 2D (Cave Story, Stardew, Undertale…) | ✅ |
| Game 3D DX9 2008–2014 | ⚠️ 20–30 fps, tuỳ game |
| **MiSide và Unity 3D hiện đại** | ❌ Dùng stream |

Nếu mục tiêu thật của bạn là "chơi game PC trên iPhone", thì **stream là sản phẩm đúng**. Cellar chỉ nên là dự án học tập / sưu tầm game cũ.

---

## 6. Về "MiSide mobile APK"

Cẩn thận: trên mạng có nhiều **APK/IPA "MiSide mobile"** là hàng giả, chứa malware hoặc chỉ là video. Không cài.

Nếu AIHASTO ra bản mobile chính thức (mình không xác nhận được ở thời điểm viết), thì đó là đường tốt nhất — kiểm tra App Store/Steam chính chủ.

---

## 7. Tóm lại

1. **Đừng** dùng máy ảo để chạy MiSide trên iPhone 12 Pro Max. Sẽ thất bại, và mất 9 tháng.
2. Cài **Sunshine + Moonlight** hôm nay → chơi MiSide 60 fps.
3. Giữ Cellar cho **game 2D/retro**, hoặc chuyển sang iPad M-series nếu sau này muốn chơi 3D local.
4. Nếu muốn, mình có thể làm **Cellar thành app "một thư viện, hai backend"**: game cũ chạy local, game nặng stream từ PC.
