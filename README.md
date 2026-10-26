# Devbox (codename) — môi trường Linux trên iPhone

> Mục tiêu: mở app → chọn dự án → có một terminal Linux thật, trong đó `python`, `pip`, `node`, `npm`, `npx`, `git`, `gcc` chạy như trên máy tính.
> Không phải "giả lập cho vui": đây là **Debian ARM64 chạy trong máy ảo**, nên mọi thứ hoạt động giống Linux thật.

Dự án này là hướng đi tiếp theo sau khi bỏ ý tưởng Winlator (xem `docs/archive-winlator/`).

> **Trạng thái thật (2026-10-26):** app đã cài và chạy trên iPhone 12 Pro Max / iOS 18.4.1 với StikDebug (`CS_DEBUGGED` bật). Bản 0.2.0 vào main loop nhưng guest không thực thi lệnh nào; 0.2.1 văng vì app tự chạy thử mã máy trên vùng RWX không có quyền thực thi; **0.2.3 đưa TCG về `split-wx` đúng như UTM**: `mmap` RW + `mach_vm_remap` alias RX + `mprotect(RX)`, **không dùng `MAP_JIT`**, không cần entitlement `dynamic-codesigning`. App kiểm tra chính đường split-wx trước khi boot và ghi kết quả vào `qemu.log` (`split-wx: …`).
>
> **Đã boot thật trên máy:** 0.2.3 boot được Debian trên iPhone (StikDebug bật JIT), nhưng bảng kết quả tab Shell báo `(lệnh không in ra gì)` dù lệnh đã chạy. **0.2.4 (8) đã sửa và xác nhận trên máy:** lệnh trả output đầy đủ, tab Shell và Console thô hiển thị đúng. Cách sửa: console lấy trực tiếp socket 4444 khi đã nối (`serial.log` chỉ dùng cho phần boot trước khi nối, khi socket đứt, hoặc khi socket im lặng >5 giây), `ShellModel` dùng mốc dòng tuyệt đối thay vì `lines.count` nên không bị kẹt khi mảng bị cắt còn 2000 dòng, và chỉ gửi lệnh sau khi thấy prompt `dev@devbox` (`shellReady`).
>
> **Đã build xanh:** workflow **Build iOS IPA** run `40337457868` → `Devbox-unsigned.ipa` 7.37 MB (SHA256 `3f2e42e6…`, **0.3.0 (11)**, engine `f9421c3e…` có split-wx). Workflow **Build QEMU engine** run `40280678103` → `engine-v1`: `devbox-engine.zip` + `devbox-engine-tcg.zip`, 6.65 MB (SHA256 `f9421c3e…`), TCG + split-wx, không có interpreter. Workflow **Build Debian image** → release `img-v1`: rootfs ext4 ~1.9 GB (zstd 423 MB), kernel 6.12.113, Python 3.13.5, Node 22.23.4, thêm tmux/ssh/ripgrep.
>
> **Mới ở bản 0.2.3:** engine TCG chạy bằng `-accel tcg,split-wx=on` (RW + RX alias), không cần `MAP_JIT`; app thử split-wx 256 → 16 MB rồi mới quyết định boot. `P_TRACED` chỉ CÓ khi debugger còn attach — StikDebug detach sau khi bật JIT nên `P_TRACED = KHÔNG` **là bình thường**, `CS_DEBUGGED` mới là cờ JIT thật. `MAP_JIT` errno 22 cũng bình thường với app sideload và không còn chặn boot. Console đọc socket 4444 khi đã nối; `Devbox/logs/serial.log` vẫn là log đầy đủ của guest để chẩn đoán. Chẩn đoán sâu qua QMP lấy `PC`, `info cpus`, `info jit`, `rd_bytes`, mã lệnh tại `PC`, 16 word đầu RAM. Công tắc **Chế độ chắc chắn (1 CPU)** bật mặc định.
>
> **Image đã boot thật trong CI** (`Test image boot`, chạy tự động trước khi publish): vào prompt sau **62.9 giây** bằng TCG; `python3`/`node`/`npm`/`git`/`gcc`/`tmux`/`rg` OK, sshd nghe cổng 22, `devbox-killport` OK, có mạng ra PyPI, `portwatch` báo cổng 5173 và `http://127.0.0.1:5173` từ host trả HTML, `poweroff` sạch. Phần app đã test trên iPhone 12 Pro Max: **0.2.4 (8)** boot được và trả output lệnh đầy đủ.

---

## TL;DR

| | |
|---|---|
| Chạy gì | Python 3.13 + pip, Node 22 + npm/npx, git, gcc, curl, nano… |
| Chạy thế nào | QEMU (fork UTM) + Debian 13 ARM64, **không GPU, không Wine** |
| Giao diện | **Shell** (gõ lệnh + gợi ý thông minh) · Dự án · Thiết lập · **tự mở web preview** khi có dev server |
| Máy | iPhone 12 Pro Max (A14, 6 GB) |
| Build | GitHub Actions → `.ipa` → Sideloadly (không cần Mac) |
| JIT | **Bắt buộc** cho QEMU → phải sideload + StikDebug |
| Kích thước | IPA ~7 MB + image ~500 MB (tải một lần) |
| So với Winlator | Dễ hơn rất nhiều: bỏ Wine, bỏ box64, bỏ DXVK, bỏ GPU |

---

## Vì sao lại là máy ảo Linux, không phải nhúng Python/Node vào app?

Đã cân nhắc 3 cách:

| | Nhúng native (CPython xcframework, nodejs-mobile) | WASM (Pyodide…) | **Máy ảo Linux ARM64** |
|---|---|---|---|
| Python + pip | ✅ nhưng chỉ wheel thuần Python | ⚠️ chậm, thiếu package | ✅ đầy đủ, kể cả numpy/pandas |
| Node + npm + npx | ⚠️ build rất khó, thiếu `child_process` | ❌ npm không chạy thật | ✅ thật 100% |
| Native module (.node, .so) | ❌ không có | ❌ | ✅ prebuild arm64 hoặc tự compile |
| `npm install` có script | ❌ | ❌ | ✅ |
| Khởi động | tức thì | vài giây | 5–10 giây |
| Pin / nhiệt | tốt | trung bình | nặng |
| Cần JIT | không | không | **có** |
| Rủi ro kỹ thuật | cao (Node trên iOS) | cao | **thấp** |

→ Chọn **máy ảo**. Đánh đổi: khởi động chậm và tốn pin, nhưng **đúng** — `npm` và `pip` hoạt động thật, không có "gần đúng".

---

## Kiến trúc

```
┌───────────────────── iOS app (SwiftUI) ─────────────────────┐
│ Dự án · Shell · Thiết lập · Web preview                     │
│  ├─ ShellView    ◄──── TCP 4444 ──────┐                     │
│  │   gợi ý lệnh, lịch sử, snippet     │                     │
│  ├─ TerminalView ◄──── TCP 4444 ──────┤                     │
│  ├─ WKWebView  ◄──── HTTP 127.0.0.1 ──┤                     │
│  │   (tự mở khi thấy dev server)      │                     │
│  └─ QEMUEngine: dlopen + Thread        │                     │
│        ├─ serial PL011 (ttyAMA0) ──────┘                     │
│        ├─ virtio-blk: Debian 13 ARM64 (ext4 raw)            │
│        ├─ virtio-9p: /mnt/share ↔ app Documents/Devbox/share│
│        └─ virtio-net (user-mode) + hostfwd 15 cổng (web, ssh)│
└──────────────────────────────────────────────────────────────┘
                              │
┌──────────────────── Debian 13 ARM64 guest ──────────────────┐
│ python3 · pip · venv · node · npm · npx · git · gcc · bash   │
│ tmux · sshd (22) · ripgrep · htop · jq · vim-tiny            │
│ /home/dev/projects/<slug>                                    │
│ portwatch: /proc/net/tcp → /mnt/share/.ports (mỗi 1 giây)    │
└──────────────────────────────────────────────────────────────┘
```

Không có: GPU, âm thanh, USB, Wayland/X11, Wine, box64. Đó là lý do dự án nhỏ hơn nhiều.

Chi tiết: [`docs/01-kien-truc.md`](docs/01-kien-truc.md)

---

## Bạn sẽ làm gì với nó

```bash
# Python
python3 -m venv .venv && source .venv/bin/activate
pip install requests numpy
python app.py

# Node
npm install
npm run dev -- --host 0.0.0.0   # app tự mở http://localhost:5173 trong khung web
npx create-vite@latest

# Khác
git clone …
gcc main.c -o main
```

---

## Tab Shell — gõ lệnh như PC

Tab **Shell** là nơi làm việc chính: một ô nhập lệnh gửi thẳng vào Debian, kèm gợi ý thông minh chạy trên máy (không cần mạng):

| Thành phần | Việc nó làm |
|---|---|
| **Gợi ý 4 lớp** | lịch sử bạn đã gõ (tần suất + gần đây + theo thư mục), từ điển ~100 lệnh kèm mô tả, lệnh con theo ngữ cảnh (`git ` → status/add/commit/push…, `npm ` → run dev/build…), và đường dẫn thật (`/mnt/share/…` đọc trực tiếp từ máy, `~/projects/<dự án>`). |
| **Chip gợi ý** | hiện ngay trên bàn phím; bấm để điền, `Tab` để lấy gợi ý đầu, `Tab` lần nữa thì gửi Tab thật cho bash. |
| **Bảng kết quả** | mỗi lệnh là một khối riêng: `$ lệnh` + output + **✓/✗ mã thoát thật** + thời gian + số lỗi/cảnh báo. Giữ lâu rồi kéo để **bôi đen nhiều dòng** ở cả Kết quả và Console thô. Menu khối: Chép lệnh / Chép kết quả / Chép lệnh + kết quả / Điền lại / Chạy lại. Nút **Chỉ lỗi** ẩn lệnh sạch; nút ⤢ mở toàn màn hình. |
| **Lịch sử bền** | ↑ / ↓ như terminal thật; lưu vào `Documents/logs/shell.json`, tắt app vẫn còn. |
| **Snippet** | lưu sẵn `npm run dev`, `python3 -m http.server 8080`… bấm là chạy. |
| **Trạng thái gửi** | `đã gửi` → `đang chạy` → `xong`, kèm ✓/✗ lấy từ `PROMPT_COMMAND` của bash (không đoán qua chữ "error"). |
| **Sửa lỗi nhanh** | `command not found: rg` → chip `apt install -y ripgrep`; `npm error code EACCES` → đổi prefix `~/.local`; CRLF/`Permission denied`, hết đĩa, DNS… đều có chip sửa một chạm. |
| **Đưa file vào máy ảo** | menu ⋯ → **Đưa file vào máy ảo…**, chọn file/thư mục từ app Files → chép vào `share/_import` (Linux thấy ở `/mnt/share/_import`). |
| **Kiểm tra nhanh** | menu ⋯ → **Kiểm tra nhanh (đĩa/mạng/node)**: `df`, `free`, DNS, TLS tới registry npm, `python3/node/npm`, `npm prefix`. |
| **Cỡ chữ + xuất log** | menu **Aa** đổi cỡ chữ Kết quả/Console thô (11–16 pt, lưu lại); **Lưu kết quả vào Files (share)** ghi `Devbox/share/devbox-output.txt`. |
| **Cảnh báo** | `rm -rf /`, `mkfs`, `dd if=`… phải xác nhận mới chạy. |
| **Khi Debian không trả lời** | băng trạng thái nói rõ đang ở bước nào: QEMU khởi động → máy ảo boot → nối console 4444 → chờ prompt `dev@devbox` → nhận byte đầu tiên. Lệnh chỉ được gửi khi đã thấy prompt. Gửi lệnh mà ~10 giây không có output và console im lặng thì app đánh dấu **Debian không trả lời** (không tự đóng/mở lại cổng); bấm **Ctrl-C** để ngắt lệnh treo hoặc **Nối lại**. |
| **Ẩn bàn phím** | nút **Ẩn phím** trên hàng phím nhanh, và nút **Ẩn bàn phím** ngay trên bàn phím — không phải chạm ra ngoài màn hình. |
| **Cổng** | danh sách cổng đang mở, mở web, copy URL, tắt cổng (`devbox-killport`). |
| **Cài gói bổ sung** | menu ⋯ → cài `tmux`, `openssh-server`, `ripgrep`, `pkill`… ngay trong máy ảo. |

Kích thước chữ tự khớp màn hình: app gửi `stty cols/rows` sau khi thấy prompt (một lần mỗi phiên) và khi khung nhìn đổi kích thước, nên bash không gãy dòng loạn.

Muốn terminal "xịn" hơn (vim, htop, chia đôi màn hình): bật SSH (menu ⋯ → **Cài gói bổ sung**) rồi dùng **Blink Shell** hoặc **Termius**:

```bash
ssh dev@127.0.0.1 -p 2222     # mật khẩu: dev
```

---

## Web preview tự động

Bạn không phải copy địa chỉ `localhost:5173` sang Safari.

1. Guest có `portwatch.sh` đọc `/proc/net/tcp` mỗi giây, thấy cổng ≥1024 đang LISTEN thì ghi vào `/mnt/share/.ports`.
2. App đọc `Documents/Devbox/share/.ports` mỗi 1.5 giây, **chỉ giữ các cổng đã được QEMU forward**, rồi thử HTTP `127.0.0.1:<cổng>`. QEMU forward sẵn 15 cổng từ lúc boot (3000, 3001, 4000, 4173, 4200, 5000, 5173, 5174, 5500, 8000, 8080, 8081, 8888, 9000, 2222→22 cho SSH) nên không cần mở cổng động.
3. Cổng trả lời HTTP → app tự mở `WKWebView`. Nút **Web** trên terminal, hoặc tab **Shell → icon mạng**, liệt kê mọi cổng đang mở để mở lại, copy URL, tắt cổng.

Áp dụng cho mọi thứ mở cổng HTTP trong danh sách trên: Vite, Next.js dev, `python3 -m http.server`, Flask, `uvicorn --port 3000`, `streamlit --server.port 8080`, Jupyter 8888… Cổng khác phải đổi về một trong các cổng đã forward.

---

## Giới hạn thật (đọc trước khi kỳ vọng)

| Giới hạn | Hệ quả |
|---|---|
| App bị iOS treo ~30 giây sau khi rời màn hình | Đã có **giữ nền** (audio im lặng): chuyển sang app khác thì web server vẫn chạy; vuốt app khỏi đa nhiệm thì tắt; tốn pin |
| Guest có 1792 MB RAM | Build lớn (Next.js, webpack nhiều entry) dễ OOM |
| QEMU TCG trên A14 | CPU ≈ laptop 2010–2015; chạy được, boot 30–90 giây, build chậm |
| Console không phải terminal grid | `vim`/`htop`/`less` hiển thị lộn xộn trong tab Shell. Bật SSH rồi dùng Blink/Termius để có terminal đầy đủ |
| Không GPU | Không chạy app GUI, không game, không Docker Desktop |
| Cần JIT | Phải sideload + StikDebug mỗi lần mở app |
| QEMU boot một lần mỗi tiến trình | Dừng Linux xong muốn chạy lại phải thoát hẳn app rồi mở lại |
| Nhiệt | Build liên tục sẽ throttle sau 15–20 phút |

Không có kế hoạch nào biến iPhone thành máy dev chính. Nó là **máy dev bỏ túi cho việc nhẹ**: sửa script, chạy thử API, học Python/Node, demo web.

---

## Trạng thái

```
[x] Phân tích & chốt kiến trúc
[x] App shell: dự án (lưu thật), console chẩn đoán thật, kiểm tra JIT bằng CS_DEBUGGED
[x] Pipeline build IPA tự động (GitHub Actions) — IPA ~7 MB có engine QEMU nhúng
[x] Pipeline build image Debian 13 ARM64 — 423 MB nén, Python/Node/npm chạy thật
[x] Engine QEMU 10.0.12 (UTM fork) build cho iOS arm64, đóng gói framework, phát hành `engine-v1`
[x] Engine TCG dùng `split-wx` (RW + `mach_vm_remap` RX alias), không cần `MAP_JIT`/entitlement JIT
[x] App tải image từ release `img-v1`, kiểm SHA256, giải nén zstd tại chỗ
[x] Image boot thật trong CI: prompt sau 62 giây, python/node/npm/git/gcc OK, mạng ra PyPI OK
[x] App boot Debian thật trên iPhone 12 Pro Max (0.2.3, StikDebug bật JIT)
[x] 0.2.4 (8): sửa nhận output lệnh (socket 4444 + mốc dòng tuyệt đối + chờ prompt) — đã xác nhận trên máy
[x] 0.2.4 (9): gửi được khi lệnh đang hỏi y/n; gộp publish console (1 tín hiệu/chunk, cache dòng) — CI build OK, chờ xác nhận trên máy
[x] 0.2.4 (10): gợi ý sửa khi `No such file`/CRLF/`Permission denied` (tìm file trong share/Projects, tự chép vào `/mnt/share/_import`), fix npm global EACCES, docs đường đi của file — CI build OK (IPA 7.33 MB), chờ xác nhận trên máy
[x] 0.3.0 (11): bôi đen nhiều dòng ở Kết quả + Console thô, ✓/✗ mã thoát thật, đếm lỗi + **Chỉ lỗi**, **Đưa file vào máy ảo**, **Kiểm tra nhanh**, PATH `~/.local` tự động mỗi lần boot, thêm mã lỗi npm (ERESOLVE/EINTEGRITY/E404/ETARGET) — CI build OK (IPA 7.37 MB), chờ xác nhận trên máy
[x] `portwatch` + `hostfwd` chạy thật trong CI: `127.0.0.1:5173` trả HTML
[x] Terminal guest qua TCP 4444 + QMP 4445 + port watch + web preview tự mở
[x] Tab **Shell**: ô nhập lệnh, lịch sử bền, snippet, trạng thái gửi, gợi ý 4 lớp, cảnh báo lệnh nguy hiểm
[x] Quản lý cổng trong app: mở web, copy URL, tắt cổng; forward 15 cổng kể cả SSH 2222
[x] Image có `tmux`, `openssh-server`, `ripgrep`, `jq`, `tree`, `vim-tiny`; app cài bổ sung được vào image cũ
[x] Chạy nền: `UIBackgroundModes=audio` + audio im lặng (công tắc trong Thiết lập, lệnh `bg`)
[x] Cài app lên iPhone 12 Pro Max và test boot          ← 0.2.3 boot được, 0.2.4 (8) output đầy đủ
[x] M2 — xác nhận output python/node/npm + preview trên máy thật (0.2.4 (8))
[ ] M3 — UX: template, quản lý gói, import/export (2–3 tuần)
[ ] M4 — tối ưu pin/nhiệt, code-server (tuỳ chọn)
```

---

## Đọc gì trước

| File | Nội dung |
|---|---|
| [`docs/00-bat-dau.md`](docs/00-bat-dau.md) | Cài app lên iPhone: GitHub Actions → Sideloadly → StikDebug |
| [`docs/01-kien-truc.md`](docs/01-kien-truc.md) | Kiến trúc, QEMU config, guest image, port forward, giới hạn |
| [`docs/02-lo-trinh.md`](docs/02-lo-trinh.md) | Mốc M0–M4, tiêu chí nghiệm thu, ước lượng |
| [`docs/03-cli.md`](docs/03-cli.md) | CLI chạy được gì / chậm gì / không chạy được, giới hạn RAM–đĩa, bài test nghiệm thu |
| [`docs/archive-winlator/`](docs/archive-winlator/) | Tài liệu cũ của hướng Winlator (để tham khảo, không còn triển khai) |
