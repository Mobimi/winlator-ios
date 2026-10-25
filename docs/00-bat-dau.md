# 00 — Bắt đầu: cài Devbox lên iPhone

Bạn **không cần Mac**, **không cần biết code**. Build chạy trên GitHub Actions; bạn chỉ làm theo các bước dưới.

Mục tiêu giai đoạn này (M0): **cài được app lên iPhone và đọc đúng trạng thái JIT** (đỏ trước khi StikDebug, xanh sau khi bật). App lúc này **chưa có engine Linux** — máy ảo Linux thật sẽ nối ở M1.

> **Bạn không cần cài app UTM.** Khi tài liệu nói "fork UTM", ý là mình lấy **mã nguồn QEMU** của UTM để nhúng vào Devbox ở M1 — không phải bảo bạn tải UTM từ mạng về cài. Cài UTM vừa không cần thiết, vừa dễ gặp lỗi ký app (xem bảng lỗi cuối trang).

---

## Chuẩn bị

| Thứ | Lấy ở đâu | Ghi chú |
|---|---|---|
| GitHub account | github.com | Miễn phí |
| GitHub Desktop | desktop.github.com | Đưa code lên, không cần gõ lệnh |
| iTunes (bản Apple) | apple.com/itunes | **Không** dùng bản Microsoft Store |
| Sideloadly | sideloadly.io | Ký app bằng Apple ID trên Windows |
| StikDebug | App Store | Bật JIT trên iPhone |
| JitterbugPair | github.com/osy/Jitterbug/releases | Tạo pairing file cho StikDebug |
| Cáp kết nối | | iPhone ↔ PC |

> Sideloadly sẽ hỏi Apple ID + mật khẩu + 2FA. Chỉ nhập trên máy của bạn. Nếu bật 2FA, có thể cần **app-specific password** tại appleid.apple.com.

---

## Bước 1 — Đưa code lên GitHub

Thư mục `D:\place for gemini\winlator ios` đã là git repo.

1. Mở **GitHub Desktop** → đăng nhập.
2. `File` → `Add local repository…` → chọn thư mục trên.
3. Bấm **Publish repository**.
   - Bỏ tick "Keep this code private" nếu muốn Actions miễn phí không giới hạn phút.
   - Tên gợi ý: `devbox`.

Nếu báo "not a git repository", mở PowerShell tại thư mục đó:

```powershell
git init
git add .
git commit -m "devbox scaffold"
```

rồi làm lại bước 2.

---

## Bước 2 — Build trên GitHub Actions

1. Vào repo → tab **Actions**.
2. Chọn **Build iOS IPA** → **Run workflow** → **Run workflow**.
3. Đợi 3–6 phút, đợi dấu ✅.
4. Mở lần chạy đó → mục **Artifacts** → tải **Devbox-unsigned-ipa**.
5. Giải nén → được `Devbox-unsigned.ipa`.

Nếu ❌: bấm vào bước đỏ, copy log gửi mình. Đừng tự sửa.

---

## Bước 3 — Cài bằng Sideloadly

1. Cài **iTunes**, mở một lần để Windows nhận driver.
2. Cài **Sideloadly**, mở lên.
3. Cắm iPhone, bấm **Trust** trên máy nếu được hỏi.
4. Trong Sideloadly:
   - **IPA**: kéo `Devbox-unsigned.ipa` vào.
   - **Apple ID**: nhập Apple ID.
   - Bấm **Start**, nhập mật khẩu / 2FA.
5. Đợi **Done**.

Nếu iPhone báo "Untrusted Developer":
`Settings` → `General` → `VPN & Device Management` → chọn Apple ID → **Trust**.

---

## Bước 4 — Bật Developer Mode

1. `Settings` → `Privacy & Security` → kéo xuống → **Developer Mode** → bật.
2. Khởi động lại iPhone → **Turn On**.

Không thấy mục này: cắm máy vào PC, mở Sideloadly một lần rồi mở lại Settings.

---

## Bước 5 — Bật JIT bằng StikDebug

Không có JIT, app vẫn mở nhưng QEMU (M1) sẽ không chạy được. Riêng console chẩn đoán thì vẫn chạy được.

### 5.1 Tạo pairing file (trên PC)

1. Tải **JitterbugPair** cho Windows, giải nén.
2. Cắm iPhone (đã Trust).
3. Chạy `jitterbugpair.exe` → tạo file `*.mobiledevicepairing`.

### 5.2 Đưa file sang iPhone

Gửi qua iCloud Drive / email / Zalo → lưu vào app **Files**.

### 5.3 StikDebug

1. Mở **StikDebug** → chọn **Pairing File** → trỏ tới file vừa lưu.
2. Cài **VPN profile** khi được yêu cầu (`Settings` → `General` → `VPN & Device Management`).
3. Trong danh sách app, tìm **Devbox** → **Enable JIT**.
   - Nếu chưa thấy, mở Devbox trước rồi quay lại.
4. Quay lại Devbox.

> Phải bật lại JIT mỗi lần mở app (máy không jailbreak). Đây là giới hạn iOS.

---

## Bước 6 — Kiểm tra

Mở **Devbox** → tab **Thiết lập**. Cần thấy:

- Model `iPhone13,4` (iPhone 12 Pro Max)
- RAM ~5800 MB
- **JIT chưa bật** ❌ (đúng như vậy nếu bạn chưa chạy StikDebug)
- Dòng `proc_csflags` — cờ thật của iOS

Sau đó chạy StikDebug → **Enable JIT** cho Devbox, mở lại app: JIT phải chuyển thành **đã bật** ✅ và `proc_csflags` có bit `CS_DEBUGGED`.

> Bản trước báo "JIT đã bật" sai vì kiểm tra bằng `mprotect`. Đã sửa: giờ app đọc đúng `CS_DEBUGGED`, nên **không thể báo xanh khi chưa có debugger attach**.

### Giữ nền (để web server không chết khi rời app)

Tab **Thiết lập** → mục **Chạy nền**, cần thấy:

- Công tắc **Giữ app chạy khi ra nền** đang bật (mặc định bật)
- Trạng thái `Đang giữ nền`
- `UIBackgroundModes` = `audio ✓`
- Audio session `playback · mixWithOthers`

Thử thật: bấm Home (hoặc mở app khác) vài phút rồi quay lại — Devbox vẫn ở trạng thái `Đang giữ nền`, không bị khởi động lại. Vuốt app khỏi đa nhiệm thì app tắt (iOS luôn vậy, không có cách chặn).

> App phát một đoạn audio gần như im lặng (−100 dBFS) để iOS không treo tiến trình. Không nghe thấy gì, nhưng tốn pin và làm máy ấm — tắt công tắc khi không cần. Cách này không cần entitlement và không ảnh hưởng profile free 7 ngày.

Sang tab **Dự án** → mở `hello-python` → gõ:

```
help
jit
bg
mem
uname
df
ls
engine
```

Đây là **console thật**: các lệnh trên đọc trạng thái thật của máy (JIT, giữ nền, RAM, kernel iOS, dung lượng, file trong sandbox). 

```
python --version
npm install express
```

sẽ báo **"lệnh Linux chưa chạy được — chưa nối engine QEMU (M1)"**. App **không in kết quả giả** nữa.

### Web preview

Chưa hoạt động ở bản này. Code WKWebView đã có, nhưng chỉ mở được khi QEMU chạy và dev server thật mở cổng (M2). Không còn banner giả. Khi M2 xong, nhờ phần **giữ nền** ở trên, bạn chuyển sang app khác mà `localhost:<cổng>` vẫn trả lời.

---

## Gửi mình gì

1. Ảnh tab **Thiết lập** (JIT, `proc_csflags`, mục **Chạy nền**).
2. Ảnh **StikDebug** sau khi bật JIT.
3. Ảnh console sau khi gõ `jit`, `bg` và `help`.
4. Kết quả Actions (xanh/đỏ; nếu đỏ thì copy log).
5. Bạn muốn chạy **Python hay Node** trước, và package nào (`requests`, `express`, `create-vite`…).

---

## Lỗi thường gặp

| Lỗi | Nguyên nhân | Xử lý |
|---|---|---|
| `integrity could not be verified` | Chưa trust cert | Settings → General → VPN & Device Management → Trust |
| App mở rồi văng | Chưa bật Developer Mode / JIT | Làm bước 4 và 5 |
| Sideloadly `Provision.cpp` | Apple ID chưa đồng ý điều khoản | Đăng nhập appleid.apple.com, đồng ý, thử lại |
| Sideloadly `AMDeviceSecureStartService` | iTunes/driver lỗi | Cài lại iTunes bản Apple, khởi động lại PC |
| Actions `xcodegen: command not found` | Bước brew lỗi | Chạy lại workflow |
| App hết hạn sau 7 ngày | Apple ID miễn phí | Cắm PC, chạy lại Sideloadly |
| Chỉ cài được 3 app | Giới hạn Apple ID | Xoá bớt app sideload khác |
| JIT bật xong vẫn đỏ | StikDebug attach sai app | Tắt hẳn Devbox (vuốt lên), mở lại, bật JIT lại |
| Chạy nền báo `THIẾU` | Bản IPA cũ chưa có `UIBackgroundModes` | Tải IPA mới từ Actions, cài lại |
| Chạy nền tắt sau cuộc gọi | Audio bị hệ thống ngắt | App tự bật lại; nếu không, mở Devbox rồi bật công tắc lại |
| SideStore `Failed to set app extension placeholders … does not match required prefix` | Bạn đang cài **một app khác có extension** (thường là UTM), không phải Devbox. SideStore thêm mã team vào bundle ID app chính nhưng không thêm vào app extension | Không cần app đó: cài Devbox. Nếu thật sự cần: dùng Sideloadly, hoặc nhờ mình vá bundle ID trong IPA |
| SideStore `Failed to register bundle identifier` | Bundle ID `app.devbox.dev` đã bị team khác đăng ký | Đổi `PRODUCT_BUNDLE_IDENTIFIER` trong `app/project.yml` (thêm hậu tố riêng), build lại. SideStore cũng tự thêm mã team nếu cần |

---

## Lưu ý

- **Không** dùng chứng chỉ enterprise bán trên mạng. Apple thu hồi hàng loạt, app chết, tài khoản có thể bị khoá.
- Apple ID miễn phí: app hết hạn **7 ngày**, tối đa **3 app**. Developer Program (99$/năm) được 1 năm.
- Đây là app cho thiết bị của bạn. Không phát hành App Store ở bản dùng JIT.
