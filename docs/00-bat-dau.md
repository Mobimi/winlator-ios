# 00 — Bắt đầu: cài Devbox lên iPhone

Bạn **không cần Mac**, **không cần biết code**. Build chạy trên GitHub Actions; bạn chỉ làm theo các bước dưới.

Mục tiêu bây giờ: **cài app lên iPhone, tải image Debian, boot được Linux và chạy `python3`/`node`/`npm` thật**. App đã có engine QEMU nhúng sẵn, không cần làm gì thêm trên máy tính ngoài việc cài IPA.

> **Bạn không cần cài app UTM.** QEMU (lấy từ mã nguồn UTM) đã được build sẵn trên GitHub Actions và nhúng trong IPA. Cài UTM chỉ tổ vướng lỗi ký app (xem bảng lỗi cuối trang).

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

## Bước 1 — Lấy IPA (không cần build)

**Cách nhanh nhất (không cần đăng nhập GitHub):**

Tải trực tiếp: `https://github.com/Mobimi/winlator-ios/releases/download/ipa-v1/Devbox-unsigned.ipa`

File khoảng 7 MB, phiên bản **0.2.4 (8)** (bản build ngày 26/10/2026, SHA256 bắt đầu `0cfc8050`). Release `ipa-v1` được cập nhật tự động mỗi lần code thay đổi. Muốn chắc mình cài đúng bản: mở tab **Thiết lập**, dòng đầu của chẩn đoán phải ghi `== Devbox 0.2.4 (8) ==`.

**Cách khác (qua Artifacts):**

1. Mở `https://github.com/Mobimi/winlator-ios/actions`.
2. Chọn workflow **Build iOS IPA** ở cột trái.
3. Chọn lần chạy **mới nhất có dấu ✅ xanh**.
4. Kéo xuống **Artifacts** → tải **Devbox-unsigned-ipa** (cần đăng nhập GitHub).
5. Giải nén → `Devbox-unsigned.ipa`.

Nếu workflow ❌: bấm vào bước đỏ, copy log gửi mình. Đừng tự sửa.

---

## Bước 2 — Cài bằng Sideloadly

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

## Bước 3 — Bật Developer Mode

1. `Settings` → `Privacy & Security` → kéo xuống → **Developer Mode** → bật.
2. Khởi động lại iPhone → **Turn On**.

Không thấy mục này: cắm máy vào PC, mở Sideloadly một lần rồi mở lại Settings.

---

## Bước 4 — Bật JIT bằng StikDebug

Không có JIT, QEMU TCG sẽ abort ngay khi boot (app báo lỗi kèm log). App vẫn mở được, chỉ Linux không chạy.

### 4.1 Tạo pairing file (trên PC)

1. Tải **JitterbugPair** cho Windows, giải nén.
2. Cắm iPhone (đã Trust).
3. Chạy `jitterbugpair.exe` → tạo file `*.mobiledevicepairing`.

### 4.2 Đưa file sang iPhone

Gửi qua iCloud Drive / email / Zalo → lưu vào app **Files**.

### 4.3 StikDebug

1. Mở **StikDebug** → chọn **Pairing File** → trỏ tới file vừa lưu.
2. Cài **VPN profile** khi được yêu cầu (`Settings` → `General` → `VPN & Device Management`).
3. Trong danh sách app, tìm **Devbox** → **Enable JIT**.
   - Nếu chưa thấy, mở Devbox trước rồi quay lại.
4. Quay lại Devbox.

> Phải bật lại JIT mỗi lần mở app (máy không jailbreak). Đây là giới hạn iOS.

---

## Bước 5 — Kiểm tra JIT

Mở **Devbox** → tab **Thiết lập**. Cần thấy:

- Model `iPhone13,4` (iPhone 12 Pro Max)
- RAM ~5800 MB
- **`CS_DEBUGGED` = TẮT** (đúng như vậy nếu bạn chưa chạy StikDebug)
- Dòng `proc_csflags` — cờ thật của iOS

Sau đó chạy StikDebug → **Enable JIT** cho Devbox, mở lại app: `CS_DEBUGGED` phải là **BẬT**.

**Đừng nhìn `P_TRACED`.** StikDebug attach vào tiến trình, bật JIT rồi **detach**; `P_TRACED` chỉ CÓ khi debugger còn attach, nên sau khi StikDebug xong nó thường ghi `KHÔNG (bình thường: StikDebug đã detach, JIT vẫn bật nhờ CS_DEBUGGED)`. Cờ quyết định là `CS_DEBUGGED`, và app kiểm tra đúng cờ này.

`proc_csflags` trên máy thật thường là `0x32003005`, có bit `0x10000000` = `CS_DEBUGGED`.

> Engine dùng **TCG + split-wx**: QEMU cấp một vùng RW để ghi mã, rồi `mach_vm_remap` tạo alias RX của đúng các trang đó và `mprotect(RX)`. Cách này chạy với `CS_DEBUGGED` và **không cần** entitlement `dynamic-codesigning`. Vì vậy log có thể ghi `MAP_JIT … errno 22` — bình thường, không phải JIT tắt.

> App đọc `CS_DEBUGGED` nên **không thể báo xanh khi chưa có debugger attach lần nào**.

### Giữ nền (để web server không chết khi rời app)

Tab **Thiết lập** → mục **Chạy nền**, cần thấy:

- Công tắc **Giữ app chạy khi ra nền** đang bật (mặc định bật)
- Trạng thái `Đang giữ nền`
- `UIBackgroundModes` = `audio ✓`
- Audio session `playback · mixWithOthers`

Thử thật: bấm Home vài phút rồi quay lại — Devbox vẫn `Đang giữ nền`, không bị khởi động lại. Vuốt app khỏi đa nhiệm thì app tắt (iOS luôn vậy).

> App phát audio gần như im lặng (−100 dBFS) để iOS không treo tiến trình. Không nghe thấy gì, nhưng tốn pin và làm máy ấm — tắt công tắc khi không cần. Cách này không cần entitlement nên không ảnh hưởng profile free 7 ngày.

---

## Bước 6 — Tải image Debian (~500 MB)

1. Tab **Thiết lập** → mục **Môi trường Linux** → bấm **Tải và cài image (~500 MB)**.
2. Cần khoảng **3 GB trống**. Giữ app mở; app tự chống khoá màn hình trong lúc tải.
3. App tải lần lượt `vmlinuz` (36 MB) → `initrd.img` (35 MB) → `rootfs.ext4.zst` (423 MB), kiểm SHA256 từng file rồi giải nén zstd ngay trên máy. Trạng thái chạy qua: `Đang tải…` → `Đang kiểm tra SHA256…` → `Đang giải nén…` → `Image sẵn sàng`.
4. Thời gian tuỳ mạng, thường 5–15 phút. Lỗi mạng thì bấm lại (file tải lại từ đầu, không resume).

> Image này đã được boot thử tự động trong GitHub Actions (`Test image boot`, chạy trước khi publish): vào prompt sau 62.9 giây, `python3`/`node`/`npm`/`git`/`gcc`/`tmux`/`rg` chạy đúng, sshd nghe cổng 22, có mạng, và `http://127.0.0.1:5173` từ ngoài vào được. Nếu máy bạn không lên được prompt thì lỗi ở phía app/JIT, không phải image.

Sau khi xong, mục đó hiện `Debian trixie · ARM64`, `Kernel 6.12.113`, `Python 3.13.5`, `Node 22.23.4 · npm 10.9.9`.

---

## Bước 7 — Boot Linux lần đầu

1. Tab **Shell** (hoặc mở một dự án ở tab **Dự án**).
2. Tab Shell tự gọi QEMU. Dải trên cùng hiện `ĐANG KHỞI ĐỘNG · <bước cuối>` (vd. `dlopen engine`, `gọi qemu_init`).
3. Khi console hiện `dev@devbox:~$` là xong. Gõ lệnh vào ô dưới cùng, bấm mũi tên gửi. Kết quả hiện thành từng khối trong bảng **Kết quả** ở trên (không phải chờ chữ chạy loạn như terminal thô).
4. Gợi ý hiện ngay trên bàn phím: bấm để điền, `Tab` để lấy gợi ý đầu. Gõ `git ` sẽ thấy `status`, `commit`, `push`…; gõ `cd /mnt/share/` sẽ thấy file thật trong thư mục share.
5. Hàng phím **↑ ↓ / Tab / Esc / Ctrl-C / cd ~ / pwd** ở trên ô nhập.

Test nhanh, gõ từng dòng:

```
python3 -V
node -v
npm -v
uname -a
df -h
```

Dùng thật:

```
cd ~/projects
mkdir demo && cd demo
npm init -y && npm install express
python3 -m venv .venv && source .venv/bin/activate && pip install requests
```

> Nếu gõ lệnh mà sau ~10 giây vẫn không thấy kết quả, băng đỏ **Debian không trả lời** hiện ra: bấm **Ctrl-C** để ngắt lệnh treo hoặc **Nối lại** (nối lại console 4444). App không tự đóng/mở lại cổng serial. Lệnh chỉ được gửi sau khi console thấy prompt `dev@devbox`; nếu băng vàng ghi **chờ prompt** thì getty còn đang khởi động, chờ thêm vài giây. Tab **Console thô** hiện số byte đã nhận — nếu là `0 B` thì app chưa nối được vào máy ảo, không phải lỗi lệnh.

> Image mới có sẵn `python` = `python3`. Image cũ chỉ có `python3`; muốn dùng `python` thì chạy `sudo apt install -y python-is-python3` (hoặc bấm chip gợi ý khi gặp `command not found: python`).

> Nếu quá 90 giây vẫn ở trạng thái khởi động, dải trên cùng chuyển đỏ kèm **bước cuối** và trạng thái JIT. Bấm **Sao chép log QEMU** rồi dán vào chat — đừng đoán.

> Muốn biết lỗi nằm ở thư viện hay ở JIT mà không cần boot: tab **Thiết lập** → mục **Engine** → **Kiểm tra engine (không boot)**. Kết quả cho biết `dlopen` OK hay lỗi, `split-wx` (vùng RW + alias RX cho TCG) có tạo được hay bị chặn kèm errno, và `MAP_JIT` dự phòng có chạy không.

> Nếu bấm **Dừng Linux**: QEMU không boot lại được trong cùng tiến trình. Vuốt Devbox khỏi đa nhiệm rồi mở lại, bật lại JIT.

---

## Bước 7.5 — Đưa file từ iPhone vào Linux

Chỉ **một** thư mục trên iPhone nối được vào máy ảo:

```
Files → Trên iPhone → Devbox → share      =      /mnt/share      (trong Linux)
```

File để ở chỗ khác — ngay gốc `Devbox/`, trong `Devbox/Projects/`, trong iCloud — Linux **không thấy**. Đây là lý do hay gặp nhất của `can't open file ... No such file or directory`.

```bash
cd /mnt/share
ls -la                 # thấy devbox.py chưa? Linux phân biệt Devbox.py với devbox.py
python3 devbox.py      # chạy ngay trong share
```

Muốn chạy trong thư mục dự án thì chép vào trước (Shell mở sẵn ở `~/projects`):

```bash
cp /mnt/share/devbox.py ~/projects/
cd ~/projects && python3 devbox.py
```

Ba lỗi thường gặp khi file được tạo trên Windows/PC:

| Lỗi | Nguyên nhân | Sửa |
|---|---|---|
| `can't open file '/home/dev/projects/devbox.py'` | file không nằm trong `~/projects` (đang ở `/mnt/share` hoặc `Documents/Projects`) | `cd /mnt/share` rồi chạy, hoặc `cp` vào |
| `bash: ./devbox.py: /usr/bin/env: bad interpreter` | file có CRLF (`\r`) của Windows | `sed -i 's/\r$//' devbox.py` |
| `bash: ./devbox.py: Permission denied` | thiếu quyền chạy | `chmod +x devbox.py` |

Từ **0.3.0 (11)**, không cần mở app Files để căn đúng thư mục: trong tab Shell, menu **⋯ → Đưa file vào máy ảo…**, chọn file/thư mục từ Files; app chép vào `Devbox/share/_import` và điền sẵn `cd /mnt/share/_import && ls -la`. Chép xong thì `cp` sang chỗ cần dùng:

```bash
cp /mnt/share/_import/devbox.py ~/projects/
```

Khi gặp lỗi, app hiện thanh **gợi ý sửa** ngay trên bàn phím: tìm file cùng tên trong `share`/`Projects` (không phân biệt hoa thường), tự chép sang `/mnt/share/_import/...` nếu cần, rồi điền sẵn lệnh đúng — bấm một lần là chạy. Thanh này nhận ra `No such file`, CRLF, `Permission denied`, `npm error code` (`EACCES`/`ERESOLVE`/`EINTEGRITY`/`E404`/`ETARGET`), `No space left on device`, lỗi DNS của `apt`; bấm `×` để bỏ qua gợi ý sai.

Cùng bản này, tab Shell có thêm:

- **Bôi đen để chép**: giữ lâu rồi kéo qua nhiều dòng ở cả **Kết quả** và **Console thô** (trước đây mỗi dòng là một `Text` riêng nên chỉ chọn được một dòng). Menu của từng khối có **Chép lệnh / Chép kết quả / Chép lệnh + kết quả / Điền lại lệnh / Chạy lại**; hàng phím nhanh có **Dán** và **Chép**.
- **✓ / ✗ kèm mã thoát**: app bật `PROMPT_COMMAND` để lấy mã thoát thật của lệnh, thay vì đoán qua chữ "error".
- **Đếm lỗi + lọc**: mỗi khối hiện `n lỗi · n cảnh báo`; nút **Chỉ lỗi** ở thanh trên ẩn các lệnh sạch.
- **Kiểm tra nhanh**: menu **⋯ → Kiểm tra nhanh (đĩa/mạng/node)** chạy một lượt `df`, `free`, DNS, TLS tới registry npm, `python3/node/npm -v`, `npm prefix` — dùng khi npm/pip lỗi hàng loạt.
- **Cỡ chữ + xuất log**: menu **Aa** trên thanh Kết quả đổi cỡ chữ (11/12/14/16 pt, lưu lại); menu **⋯ → Lưu kết quả vào Files (share)** ghi `Devbox/share/devbox-output.txt` để mở bằng app Files.

> `Documents/Projects/<tên>` mà app tạo là thư mục phía iPhone, **không** phải `~/projects/<tên>` trong máy ảo. Hai thư mục khác nhau; muốn đưa file vào máy ảo thì đi qua `Devbox/share`.

### Máy ảo còn bao nhiêu chỗ?

```bash
df -h /
```

Image Debian được đóng gói ở kích thước nhỏ nhất (**1.9 GB**, còn ~440 MB cho user `dev`), nên cài hai agent CLI là hết chỗ. Dọn trước khi cài:

```bash
npm cache clean --force; rm -rf ~/.cache/pip; sudo apt-get clean; df -h /
```

Hết chỗ thật thì gỡ gói không dùng: `sudo apt-get purge <tên-gói>`.

---

## Bước 8 — Web preview tự mở

Trong Linux, chạy dev server nghe cổng **3000**, **5173** hoặc **8080**:

```
cd ~/projects/demo
python3 -m http.server 8080
```

Vài giây sau app tự mở khung web `localhost:8080`. Với Vite:

```
npm create vite@latest web -- --template vanilla
cd web && npm install && npm run dev -- --host 0.0.0.0 --port 5173
```

Nút **Web** trên thanh công cụ terminal liệt kê mọi cổng đang mở để mở lại. Tab **Shell → icon mạng** cũng có danh sách đó, kèm nút **Copy URL** và **Tắt cổng**.

App forward sẵn 15 cổng: 3000, 3001, 4000, 4173, 4200, 5000, 5173, 5174, 5500, 8000, 8080, 8081, 8888, 9000 và 2222 (SSH). Cổng khác phải đổi về một trong các cổng này. App chỉ hiện các cổng nằm trong danh sách forward, nên cổng lạ trong `.ports` không làm rối danh sách.

### Muốn terminal "xịn" hơn (vim, htop, chia đôi màn hình)

Bật SSH trong máy ảo: tab **Shell** → menu **⋯** → **Cài gói bổ sung (tmux/ssh/rg)**.

Rồi mở **Blink Shell** hoặc **Termius**, gõ:

```
ssh dev@127.0.0.1 -p 2222
```

Mật khẩu: `dev`. Khi đó bạn có terminal grid thật, `vim`/`htop`/`tmux` chạy đúng, copy/paste và bàn phím ngoài đầy đủ.

---

## Gửi mình gì

Không cần chụp ảnh — mọi thứ nằm trong file:

1. Tab **Thiết lập** → **Sao chép chẩn đoán** → dán vào chat.
2. Nếu boot lỗi: mở app **Files** → **Trên iPhone của tôi** → **Devbox** → **logs** → gửi **ba file** `qemu.log`, `serial.log`, `diagnostics.txt`. `serial.log` là chữ guest in ra (kernel + console), có cả khi cổng 4444 không nối được — thiếu file này thì gần như không chẩn đoán được. Hoặc bấm **Chia sẻ file log** trong tab Thiết lập để gửi qua AirDrop/Telegram. Log của lần boot trước giữ ở `qemu-previous.log`.
3. Kết quả `python3 -V`, `node -v`, `npm -v` trong terminal.
4. Lỗi Sideloadly/StikDebug nếu có (copy nguyên văn).

---

## Lỗi thường gặp

| Lỗi | Nguyên nhân | Xử lý |
|---|---|---|
| `integrity could not be verified` | Chưa trust cert | Settings → General → VPN & Device Management → Trust |
| App mở rồi văng | Chưa bật Developer Mode / JIT | Làm bước 3 và 4 |
| Sideloadly `Provision.cpp` | Apple ID chưa đồng ý điều khoản | Đăng nhập appleid.apple.com, đồng ý, thử lại |
| Sideloadly `AMDeviceSecureStartService` | iTunes/driver lỗi | Cài lại iTunes bản Apple, khởi động lại PC |
| Actions `xcodegen: command not found` | Bước brew lỗi | Chạy lại workflow |
| App hết hạn sau 7 ngày | Apple ID miễn phí | Cắm PC, chạy lại Sideloadly |
| Chỉ cài được 3 app | Giới hạn Apple ID | Xoá bớt app sideload khác |
| JIT bật xong vẫn đỏ | StikDebug attach sai app / app đang chạy trước khi attach | Làm đúng thứ tự: vuốt Devbox khỏi đa nhiệm → mở StikDebug → **Enable JIT** (StikDebug tự mở Devbox) → trong Devbox bấm **Kiểm tra lại thiết bị**. App cũng tự đọc lại mỗi 4 giây. Nhìn `CS_DEBUGGED`, đừng nhìn `P_TRACED` |
| `CS_DEBUGGED = TẮT`, `P_TRACED = KHÔNG` | Debugger chưa từng attach được vào tiến trình (thiếu `get-task-allow`, pairing sai, Developer Mode tắt) | Cài lại bằng **Sideloadly** (bản sideload có `get-task-allow`), bật Developer Mode, tạo lại pairing file, thử lại |
| `CS_DEBUGGED = TẮT`, `P_TRACED = CÓ` | Debugger còn attach nhưng JIT chưa được bật cho tiến trình | Bấm **Enable JIT** lại trong StikDebug; nếu vẫn vậy, gửi mình output `diag` và `qemu.log` |
| `P_TRACED = KHÔNG` nhưng `CS_DEBUGGED = BẬT` | Bình thường: StikDebug detach sau khi bật JIT | Không làm gì. Đây là trạng thái đúng để boot |
| Log có `MAP_JIT … errno 22` | App sideload không có entitlement `dynamic-codesigning`; `MAP_JIT` bị iOS từ chối | Bình thường. Engine không dùng `MAP_JIT` mà dùng **split-wx** (`mach_vm_remap` + `mprotect RX`). Chỉ cần `CS_DEBUGGED = BẬT` |
| Log có `split-wx bị chặn` | JIT chưa có hiệu lực, hoặc iOS chặn `mprotect(RX)` | Bật lại JIT bằng StikDebug (Bước 4), thoát hẳn app rồi mở lại; gửi dòng `Codegen:` trong `diag` |
| `proc_csflags = không đọc được` | iOS 18+ chặn `sysctl.proc_csflags` với app thường | App tự chuyển sang `csops(CS_OPS_STATUS)`. Nếu cả hai lỗi, `diag` in errno của từng cách |
| Chạy nền báo `THIẾU` | Bản IPA cũ chưa có `UIBackgroundModes` | Tải IPA mới từ Actions, cài lại |
| Chạy nền tắt sau cuộc gọi | Audio bị hệ thống ngắt | App tự bật lại; nếu không, mở Devbox rồi bật công tắc lại |
| Bấm mở dự án, dải đỏ báo `Thiếu engine QEMU…` | IPA tải từ run cũ (trước khi nhúng engine) | Tải lại IPA ở run **Build iOS IPA** mới nhất, cài lại |
| Dải đỏ `QEMU gọi exit() khi khởi động…` | QEMU tự thoát trong lúc init (thiếu bộ nhớ exec, tham số, hoặc framework) | Tab **Thiết lập** → **Kiểm tra engine (không boot)**, rồi gửi file `logs/qemu.log` trong app Files. Log ghi từng bước `dlopen` → `qemu_init` → `main loop` |
| Dải đỏ `QEMU chưa vào main loop sau 90 giây…` | `qemu_init` treo hoặc thread QEMU chết sớm | Xem `logs/qemu.log`; dòng `[t+…] stage:` cuối cùng cho biết treo ở đâu |
| Dải đỏ `Không tạo được vùng code TCG…` | `split-wx` thất bại và `MAP_JIT` cũng bị chặn — JIT chưa thực sự có hiệu lực | Bật lại JIT bằng StikDebug (Bước 4). Nếu vẫn lỗi, chạy **Kiểm tra engine** và gửi dòng `split-wx` / `MAP_JIT` |
| Log QEMU có `tcg` / `mprotect` / `MAP_JIT` | JIT chưa bật hoặc StikDebug attach sai app | Vuốt Devbox khỏi đa nhiệm → StikDebug → **Enable JIT** → StikDebug tự mở Devbox. Kiểm tra `CS_DEBUGGED = BẬT` |
| `serial.log` trống hoàn toàn, `diag` báo `guest: … pc=0x40000000` không đổi | CPU khách không chạy được instruction đầu tiên (JIT/vCPU) | Bật **Chế độ chắc chắn (1 CPU)** ở tab Thiết lập, thoát hẳn app, mở lại, boot lại, rồi gửi `qemu.log` + `serial.log` |
| `serial.log` có chữ nhưng tab **Console thô** không hiện | Kết nối socket 4444 đứt trong khi QEMU vẫn ghi log | Bấm **Nối lại** ở dải trạng thái (app chuyển tạm sang đọc `serial.log`); nếu vẫn trống, gửi `serial.log` |
| Log QEMU có `failed to find romfile "efi-virtio.rom"` | IPA cũ: engine build không kèm blobs nhưng card mạng vẫn đòi ROM PXE | Cài IPA mới (từ `a724b2a7…` trở đi). Bản mới truyền `romfile=` rỗng nên bỏ ROM, không cần PXE |
| Log QEMU có `Library not loaded: @rpath/...` | Framework chưa được ký lại khi cài | Cài bằng **Sideloadly** (ký được framework con). SideStore đôi khi hỏng bước này — thử lại |
| Tải image báo `HTTP 404` | Asset release `img-v1` bị xoá/đổi tên | Báo mình; đừng tải file lạ từ nguồn khác |
| Tải image báo `SHA256 … không khớp` | Tải hỏng hoặc mạng chèn | Xoá image trong Thiết lập rồi tải lại |
| Tải image báo `Không đủ dung lượng` | Cần ~3 GB trống | Xoá bớt app/ảnh; iOS không cho app chiếm hết đĩa |
| `Image sẵn sàng` nhưng boot không lên prompt | Console chưa nối / boot chậm | Đợi 90 giây. Vẫn im: xem `logs/qemu.log` trong app Files, gửi `diag` |
| Gõ lệnh mà không thấy gì | Ô nhập đang mất focus / console chưa nối | Bấm vào ô nhập, gửi lại. Dải trên cùng phải ghi `console đã nối` |
| Web preview không tự mở | Dev server nghe cổng khác 3000/5173/8080, hoặc bind `localhost` trong guest | Chạy với `--host 0.0.0.0` và cổng 3000/5173/8080. Nút **Web** để mở tay |
| SideStore `Failed to set app extension placeholders … does not match required prefix` | Bạn đang cài **một app khác có extension** (thường là UTM), không phải Devbox. SideStore thêm mã team vào bundle ID app chính nhưng không thêm vào app extension | Không cần app đó: cài Devbox. Nếu thật sự cần: dùng Sideloadly, hoặc nhờ mình vá bundle ID trong IPA |
| SideStore `Failed to register bundle identifier` | Bundle ID `app.devbox.dev` đã bị team khác đăng ký | Đổi `PRODUCT_BUNDLE_IDENTIFIER` trong `app/project.yml` (thêm hậu tố riêng), build lại. SideStore cũng tự thêm mã team nếu cần |

---

## Lưu ý

- **Không** dùng chứng chỉ enterprise bán trên mạng. Apple thu hồi hàng loạt, app chết, tài khoản có thể bị khoá.
- Apple ID miễn phí: app hết hạn **7 ngày**, tối đa **3 app**. Developer Program (99$/năm) được 1 năm.
- Đây là app cho thiết bị của bạn. Không phát hành App Store ở bản dùng JIT.
