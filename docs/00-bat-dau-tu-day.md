# 00 — Bắt đầu từ đây (dành cho người không viết code)

Bạn **không cần Mac** và **không cần biết code**. Toàn bộ việc build sẽ chạy trên GitHub Actions (máy Mac miễn phí của GitHub), bạn chỉ cần làm theo các bước dưới.

Mục tiêu của giai đoạn này: **cài được app Cellar lên iPhone 12 Pro Max và xem nó báo JIT xanh hay đỏ.** Đó là bước 0 của mọi thứ. Chưa có game nào chạy ở bước này — app đang dùng engine giả.

---

## Trước khi bắt đầu: nói thật về iPhone 12 Pro Max

| Thông số | Giá trị | Ý nghĩa |
|---|---|---|
| Chip | A14 Bionic | Đủ để **chạy** máy ảo Linux ARM64, nhưng chậm |
| RAM | 6 GB | iOS chỉ cho app dùng ~3–3.5 GB → guest RAM thực tế **2–3 GB** |
| Màn hình | 60 Hz | Giới hạn fps ở 30 hoặc 60 |
| Nhiệt | iPhone | Throttle sau ~10–20 phút chơi liên tục |

**Kết luận thực tế:**

- ✅ Chơi được: game 2D, visual novel, RPG Maker, game DOS/Win9x, indie nhẹ, game DX9 cũ ở 720p/30fps (tuỳ game).
- ⚠️ Chơi tạm: game 3D 2010–2014 ở low, 20–30 fps.
- ❌ Không chơi được: AAA 2018+, game có anti-cheat, game DX12 nặng.
- 📱 Nếu mục tiêu là **chơi game thật sự**, thiết bị đúng là **iPad M1 trở lên**. iPhone 12 Pro Max dùng để phát triển và thử nghiệm.
- 🎮 Nếu bạn muốn chơi game hiện đại trên chính iPhone này **ngay bây giờ**, hướng duy nhất khả thi là **stream từ PC** (Moonlight/Sunshine) — mình có thể làm backend đó sau.

---

## Cần chuẩn bị (khoảng 30–45 phút)

| Thứ | Link / cách lấy | Ghi chú |
|---|---|---|
| GitHub account | github.com | Miễn phí |
| GitHub Desktop | desktop.github.com | Để đưa code lên, không cần gõ lệnh |
| iTunes bản Apple | apple.com/itunes | **Không** dùng bản Microsoft Store |
| Sideloadly | sideloadly.io | Cài trên Windows, dùng để ký app bằng Apple ID |
| StikDebug | App Store (tìm "StikDebug") | Bật JIT trên chính iPhone |
| JitterbugPair | github.com/osy/Jitterbug/releases | Tạo pairing file cho StikDebug |
| Cáp Lightning/USB-C | | Kết nối iPhone với PC |

> Sideloadly sẽ hỏi **Apple ID + mật khẩu + mã 2FA**. Chỉ nhập trên máy của bạn. Nếu bật 2FA (nên bật), có thể cần tạo **app-specific password** tại appleid.apple.com.

---

## Bước 1 — Đưa code lên GitHub

Thư mục `D:\place for gemini\winlator ios` đã được mình tạo sẵn thành git repo.

1. Mở **GitHub Desktop** → đăng nhập.
2. `File` → `Add local repository…` → chọn `D:\place for gemini\winlator ios`.
3. Bấm **Publish repository**.
   - Bỏ tick "Keep this code private" nếu muốn build miễn phí không giới hạn phút. (Code engine QEMU sau này bắt buộc public vì GPL, nên public luôn cũng được.)
   - Tên gợi ý: `cellar`.

Nếu GitHub Desktop báo "not a git repository", mở PowerShell tại thư mục đó và chạy:

```powershell
git init
git add .
git commit -m "scaffold"
```

rồi làm lại bước 2.

---

## Bước 2 — Build trên GitHub Actions

1. Vào repo trên github.com.
2. Tab **Actions**.
3. Chọn workflow **Build iOS IPA** ở cột trái.
4. Bấm **Run workflow** → **Run workflow** (nhánh `main`).
5. Đợi ~3–6 phút. Trạng thái chuyển ✅.
6. Bấm vào lần chạy đó → kéo xuống mục **Artifacts** → tải **Cellar-unsigned-ipa**.

Giải nén file zip vừa tải → bên trong có `Cellar-unsigned.ipa`.

> Nếu build ❌: bấm vào bước bị đỏ, copy toàn bộ log gửi mình. Đừng tự sửa.

---

## Bước 3 — Cài app lên iPhone bằng Sideloadly (trên Windows)

1. Cài **iTunes** (bản Apple) và mở một lần để Windows nhận driver.
2. Cài **Sideloadly**, mở lên.
3. Cắm iPhone vào PC, bấm **Trust** trên iPhone nếu được hỏi.
4. Trong Sideloadly:
   - **IPA**: kéo file `Cellar-unsigned.ipa` vào.
   - **Apple ID**: nhập Apple ID của bạn.
   - Bấm **Start**.
5. Nhập mật khẩu / mã 2FA khi được hỏi.
6. Đợi đến khi báo **Done**.

**Nếu iPhone báo "Untrusted Developer":**
`Settings` → `General` → `VPN & Device Management` → chọn Apple ID của bạn → **Trust**.

---

## Bước 4 — Bật Developer Mode

iOS 16+ bắt buộc:

1. `Settings` → `Privacy & Security` → kéo xuống → **Developer Mode** → bật.
2. iPhone khởi động lại → xác nhận **Turn On**.

> Nếu không thấy mục Developer Mode: cắm iPhone vào PC, mở Xcode/AltServer một lần, hoặc cài app qua Sideloadly trước rồi mở lại Settings.

---

## Bước 5 — Bật JIT bằng StikDebug

Không có bước này, app sẽ mở được nhưng **không chạy được máy ảo**.

### 5.1 Tạo pairing file trên PC

1. Tải **JitterbugPair** cho Windows, giải nén.
2. Cắm iPhone (đã Trust).
3. Chạy `jitterbugpair.exe`.
4. Nó tạo file `*.mobiledevicepairing` trong cùng thư mục.

### 5.2 Đưa file sang iPhone

Gửi file đó cho chính bạn qua **iCloud Drive / email / Zalo** rồi lưu vào app **Files** trên iPhone.

### 5.3 Cài StikDebug

1. Mở **StikDebug** (đã cài từ App Store).
2. Chọn **Pairing File** → trỏ tới file `.mobiledevicepairing`.
3. Cài **VPN profile** khi app yêu cầu (`Settings` → `General` → `VPN & Device Management` → Install).
4. Trong danh sách app, tìm **Cellar** → bấm **Enable JIT**.
   - Nếu Cellar chưa hiện, mở Cellar trước rồi quay lại StikDebug.
5. Quay lại Cellar.

> StikDebug phải bật lại mỗi lần mở Cellar (máy không jailbreak). Đây là hạn chế của iOS, không phải lỗi app.

---

## Bước 6 — Kiểm tra

Mở **Cellar** → tab **Thiết lập**.

Bạn cần thấy:

- **Model**: `iPhone13,4` (iPhone 12 Pro Max)
- **iOS**: phiên bản của bạn
- **RAM**: ~5800 MB
- **JIT đã bật** (dấu ✅ xanh)

Nếu JIT vẫn đỏ → gửi mình ảnh chụp tab Thiết lập + ảnh StikDebug.

Sau đó vào tab **Thư viện**, bấm thử một game để xem luồng boot giả lập. Đây là bộ khung UI; engine thật sẽ được nối ở bước tiếp theo.

---

## Gửi mình gì sau khi làm xong

1. Ảnh tab **Thiết lập** (thấy JIT + model).
2. Ảnh **StikDebug** sau khi bật JIT.
3. Kết quả: build Actions xanh hay đỏ (nếu đỏ, copy log).
4. Bạn muốn chơi **game cụ thể nào** (tên game + năm) — mình sẽ nói trước là có khả năng chạy hay không.

---

## Lỗi thường gặp

| Lỗi | Nguyên nhân | Cách xử lý |
|---|---|---|
| `Unable to install ... integrity could not be verified` | Chưa trust cert | Settings → General → VPN & Device Management → Trust |
| App mở rồi văng ngay | Chưa bật Developer Mode, hoặc JIT chưa bật | Làm bước 4 và 5 |
| Sideloadly: `Provision.cpp: ...` | Apple ID chưa đồng ý điều khoản / 2FA | Đăng nhập appleid.apple.com, đồng ý điều khoản, thử lại |
| Sideloadly: `AMDeviceSecureStartService` | iTunes/driver lỗi | Cài lại iTunes bản Apple, khởi động lại PC |
| Actions báo `xcodegen: command not found` | Bước brew lỗi | Chạy lại workflow |
| App hết hạn sau 7 ngày | Apple ID miễn phí | Cắm PC, chạy lại Sideloadly (hoặc dùng AltStore/SideStore) |
| Chỉ cài được 3 app | Giới hạn Apple ID miễn phí | Xoá bớt app sideload khác |

---

## Giới hạn pháp lý & an toàn

- **Không** dùng chứng chỉ enterprise bán trên mạng. Apple thu hồi hàng loạt, app chết và tài khoản có thể bị khoá.
- **Không** tải Windows ISO, game, ROM từ nguồn lậu trong repo này.
- App chỉ chạy file bạn tự có quyền sử dụng.
