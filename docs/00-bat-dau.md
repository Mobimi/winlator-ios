# 00 — Bắt đầu: cài Devbox lên iPhone

Bạn **không cần Mac**, **không cần biết code**. Build chạy trên GitHub Actions; bạn chỉ làm theo các bước dưới.

Mục tiêu giai đoạn này (M0): **cài được app lên iPhone và thấy JIT xanh.** App lúc này mới có terminal mô phỏng — máy ảo Linux thật sẽ nối ở M1.

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

Không có JIT, app vẫn mở nhưng chỉ chạy được terminal mô phỏng.

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
- **JIT đã bật** ✅

Sau đó sang tab **Dự án** → mở `hello-python` → gõ thử:

```
python --version
npm install express
npm run dev
uvicorn app:app
help
```

Đây là shell mô phỏng (chưa có Linux thật). Mục đích: kiểm tra UI, bàn phím, luồng thao tác.

Sau `npm run dev` (hoặc `uvicorn app:app`), bạn sẽ thấy:

1. Banner xanh **Web · localhost:5173** ngay trên thanh nhập lệnh.
2. Khoảng 1 giây sau, khung web **tự mở** (hiện là trang mô phỏng — M2 sẽ là web thật).
3. Muốn tắt tự mở: tab **Thiết lập** → **Web preview** → gạt công tắc.

Đây chính là luồng sau này dùng cho dự án thật: chạy `npm run dev`/`uvicorn`/`streamlit` là giao diện web tự hiện, không phải copy cổng.

---

## Gửi mình gì

1. Ảnh tab **Thiết lập** (thấy JIT + model + mục Web preview).
2. Ảnh **StikDebug** sau khi bật JIT.
3. Ảnh terminal mô phỏng sau khi gõ `help`, và ảnh khung web tự mở sau `npm run dev`.
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
| SideStore `Failed to set app extension placeholders … does not match required prefix` | Bạn đang cài **một app khác có extension** (thường là UTM), không phải Devbox. SideStore thêm mã team vào bundle ID app chính nhưng không thêm vào app extension | Không cần app đó: cài Devbox. Nếu thật sự cần: dùng Sideloadly, hoặc nhờ mình vá bundle ID trong IPA |
| SideStore `Failed to register bundle identifier` | Bundle ID `app.devbox.dev` đã bị team khác đăng ký | Đổi `PRODUCT_BUNDLE_IDENTIFIER` trong `app/project.yml` (thêm hậu tố riêng), build lại. SideStore cũng tự thêm mã team nếu cần |

---

## Lưu ý

- **Không** dùng chứng chỉ enterprise bán trên mạng. Apple thu hồi hàng loạt, app chết, tài khoản có thể bị khoá.
- Apple ID miễn phí: app hết hạn **7 ngày**, tối đa **3 app**. Developer Program (99$/năm) được 1 năm.
- Đây là app cho thiết bị của bạn. Không phát hành App Store ở bản dùng JIT.
