# 03 — CLI chạy được gì, không chạy được gì

Câu hỏi hay gặp: *"app này có chạy được CLI thật không, hay chỉ là demo?"*

## Trả lời ngắn

| Giai đoạn | CLI |
|---|---|
| **Hiện tại (26/10/2026)** | **Có**, sau khi cài image và boot. Guest là Debian 13 ARM64 thật: `bash`, `python3`, `node`, `npm`, `git`, `gcc` chạy thật trong máy ảo. Đã boot và xác nhận output lệnh trên iPhone 12 Pro Max (0.2.4 (8)). |
| **Console khi chưa cài image** | Chỉ chạy lệnh chẩn đoán thật (`jit`, `diag`, `bg`, `mem`, `uname`, `df`, `ls`, `engine`). Gõ `python`/`npm` sẽ báo chưa có image. Không có kết quả giả. |
| **Giới hạn** | Không phải terminal grid: `vim`, `htop`, `less` hiển thị lộn xộn trong tab Shell. Bật SSH (menu ⋯ → Cài gói bổ sung) rồi dùng Blink/Termius nếu cần TUI đầy đủ. |

## Tab Shell — cách gõ lệnh

Tab **Shell** là cửa nhập lệnh chính, dùng chung phiên console với tab Terminal:

- **Gợi ý 4 lớp**: lịch sử (tần suất + gần đây + theo thư mục), từ điển ~100 lệnh kèm mô tả, lệnh con theo ngữ cảnh (`git `, `npm `, `apt `, `python3 -m `, `systemctl `…), đường dẫn thật (`/mnt/share/…` đọc từ máy, `~/projects/<slug>`).
- **Bảng kết quả**: mỗi lệnh một khối `$ lệnh` + output + trạng thái; nút ⤢ xem toàn màn hình, copy/share. Tab **Console thô** xem nguyên luồng serial.
- **Chẩn đoán**: băng trạng thái nói rõ đang ở bước nào (QEMU khởi động → máy ảo boot → nối console → chờ prompt `dev@devbox` → nhận byte đầu tiên). Gửi lệnh mà ~10 giây không có output và console im lặng thì app đánh dấu **Debian không trả lời** (không tự đóng/mở lại cổng serial), kèm **Ctrl-C** / **Nối lại**.
- **Ẩn bàn phím**: nút **Ẩn phím** trên hàng phím nhanh và nút **Ẩn bàn phím** trên bàn phím.
- **↑ / ↓** gọi lại lệnh; lịch sử lưu trong `Documents/logs/shell.json` nên mở lại app vẫn còn.
- **Snippet**: lưu lệnh hay dùng, bấm là chạy.
- **Trạng thái**: `đã gửi` → `đang chạy` → `xong`.
- **Sửa lỗi**: `command not found: rg` → chip `apt install -y ripgrep`.
- **Cảnh báo**: `rm -rf /`, `mkfs`, `dd if=`, fork bomb → hộp thoại xác nhận.
- **Cổng**: xem/mở/copy URL/tắt cổng đang mở.
- **stty tự động**: app gửi `stty cols/rows` đúng bề rộng màn hình, gửi lại khi xoay máy.

Chỉ có **một** console serial, nên Shell và Terminal nhìn cùng một phiên bash. Shell để gõ, Terminal để xem output dài.

CLI là phần **dễ** của kiến trúc này: QEMU lo giả lập CPU, CLI chỉ cần stdin/stdout và syscall. Không cần GPU. Phần khó là boot máy ảo và nối terminal — không phải chạy lệnh.

## Vì sao chắc chắn chạy được (không phải phỏng đoán)

Image đã build thật ngày 2026-10-25 (`image/build-image.sh`, runner `ubuntu-24.04-arm`):

- Debian 13 (trixie) ARM64, glibc, systemd
- Kernel `6.12.113+deb13-arm64`
- Python `3.13.5`, pip `25.1.1`, `venv`, header dev
- Node `v22.23.4` + `npm` + `npx` (tarball chính thức, sha256 khớp)
- `git 2.47.3`, `gcc 14.2`, `make 4.4.1`, `pkg-config`
- `curl 8.14.1`, `wget 1.25.0`, `nano 8.4`, `less`, `htop 3.4.1`
- `sudo` (user `dev`, không mật khẩu), `apt`, `unzip`, `xz`, `gnupg`

Đây là userland Linux bình thường. Bất cứ thứ gì `apt`/`pip`/`npm` cài được cho **linux-arm64** đều chạy được trong đó.

## Python — "hỗ trợ hết chưa?"

**Về mặt Python: giống PC Linux, không phải bản rút gọn.**

- CPython **3.13.5** đầy đủ (stdlib, `ssl`, `sqlite3`, `zlib`, `ctypes`); `tkinter` **không cài sẵn** (`apt install python3-tk` được, nhưng không có màn hình để hiện cửa sổ)
- **pip 26.2.2** lấy trực tiếp từ **PyPI**, không qua kho riêng
- `venv`, `setuptools`, `wheel`, header dev + `gcc 14.2` → cài được cả gói chỉ có source
- Đã bỏ marker PEP 668 → `pip install` chạy toàn cục đúng như trên PC (không phải tạo venv mới cài được)
- `pip install git+https://…`, `python -m build`, `poetry`, `uv`, `pipx` đều cài và chạy được

**Đã kiểm chứng thật trong image (build 2026-10-25), không phải lý thuyết:**

```
pip: pip 26.2.2
python smoke OK: requests 2.34.2, numpy 2.5.4, pandas 3.1.0
```

Tức là pip đã tải **wheel manylinux aarch64** từ PyPI, cài và `import` thành công ngay trong rootfs Debian của Devbox. Kết quả này được ghi vào `manifest.json` mỗi lần build.

### Cái gì chạy y như PC

| Nguồn | Trạng thái |
|---|---|
| PyPI (wheel `manylinux aarch64`) | ✅ đa số gói phổ biến có wheel arm64 |
| PyPI (chỉ có source `.tar.gz`) | ✅ có gcc + header, chỉ chậm |
| GitHub / GitLab (`pip install git+…`) | ✅ có `git` |
| File `.whl` tải tay | ✅ nếu là `aarch64`/`universal2`-không, tức `py3-none-any` hoặc `manylinux*aarch64` |
| `apt install python3-…` | ✅ |
| Conda/Miniforge | ⚠️ không cài sẵn; cài tay được (`Miniforge3-Linux-aarch64.sh`) |

### Cái gì **không** chạy — và lý do

| Loại | Lý do |
|---|---|
| Gói chỉ có wheel **Windows** (`pywin32`, `winsound`, `msvcrt`) | OS là Linux |
| Gói chỉ phát hành wheel **x86_64**, không có aarch64 | PyPI không có bản arm64 → chỉ còn cách build từ source nếu mã nguồn cho phép |
| Gói cần **GPU/CUDA** | không có GPU trong máy ảo |
| Gói cần **màn hình** (`tkinter` hiện cửa sổ, `pyautogui`, `pygame` display) | chỉ có console, không có X11/Wayland |
| `selenium` / `playwright` + Chromium | Chromium arm64 chạy được về lý thuyết nhưng gần như chắc chắn OOM |
| `torch`/`tensorflow` bản lớn | wheel arm64 có, nhưng tải nặng + RAM 2.5 GB dễ OOM; CPU-only và rất chậm |

### Khác biệt lớn nhất không phải "hỗ trợ" mà là **tốc độ**

Cùng một `python app.py`:

- Code thuần Python: chậm ~5–15× so với PC
- numpy/pandas: phần tính toán là C đã biên dịch, nhưng vẫn chạy trên CPU giả lập → chậm vài lần
- `pip install` gói có wheel: 30–90 giây; gói phải compile: 5–20 phút

### Jupyter / notebook

Chạy được và **xem được ngay trong app** (không cần GUI):

```bash
pip install jupyterlab
jupyter lab --no-browser --ip=0.0.0.0 --port 8888
```

Ở M2, app tự thấy cổng 8888 và mở trong khung web — đó là cách "toàn diện" cho Python mà không cần desktop.

## Ma trận khả năng

### Chạy tốt

- Shell script, `bash`, biến môi trường, pipe, `grep/sed/awk`
- `git clone` / `commit` / `push` (cần mạng)
- `python3`, `venv`, `pip install` các gói **có wheel arm64** (requests, flask, fastapi, pydantic, pillow…)
- `node`, `npm install` dự án vừa, `npx`, chạy script Node
- `uvicorn` / `flask run` / `npm run dev` → web preview tự mở trong app (cổng 3000/5173/8080)
- `gcc` biên dịch C nhỏ, `make` dự án vừa
- `curl` gọi API, `sqlite3` (qua Python, hoặc `apt install sqlite3`)
- `ssh`, `rsync`, `tmux`, `vim`, `jq`, `htop`… (đã cài sẵn `tmux`, `openssh-server`, `ripgrep`, `jq`, `tree`, `vim-tiny`; còn lại `apt install` được)
- SSH vào chính máy ảo từ Blink/Termius: `ssh dev@127.0.0.1 -p 2222` (mật khẩu `dev`) → terminal grid đầy đủ, `vim`/`htop` chạy đúng
- Agent CLI gọi API (OpenCode, Aider, Claude Code… chạy trong `tmux`) — xem mục **Chạy agent/CLI AI** bên dưới

### Chạy được nhưng chậm

| Việc | Thực tế trên A14 (ước tính, chưa đo trên máy) |
|---|---|
| `npm install` dự án Vite/Express | 1–3 phút |
| `npm install` Next.js / Angular | 5–15 phút, dễ OOM nếu ít RAM |
| `pip install numpy/pandas` (có wheel) | 30–90 giây |
| `pip install` phải biên dịch từ source | 5–20 phút |
| `tsc` / `jest` / `pytest` suite lớn | chậm 5–15× so với laptop |
| `cargo build` / build C++ lớn | rất chậm, chỉ nên làm việc nhỏ |

Nguyên nhân: iOS **không cho virtualization phần cứng**, nên QEMU phải dịch từng instruction (TCG). Kể cả guest cùng kiến trúc arm64 với máy, vẫn là dịch phần mềm → chậm hơn native nhiều lần.

### Không chạy được (giới hạn thật, không phải lỗi app)

- App GUI: GTK, Qt, Electron, game, desktop Linux
- Trình duyệt / Playwright / Chromium headless (nặng, gần như chắc chắn OOM)
- Docker/Kubernetes cho công việc thật (về lý thuyết guest kernel chạy được, nhưng đĩa + RAM + tốc độ làm nó vô nghĩa)
- Xcode, build iOS/macOS
- CUDA/GPU, train ML
- Build LLVM/Chromium từ source

## Chạy agent/CLI AI (DeepSeek, OpenAI, Claude…)

Cần phân biệt hai thứ:

- **Agent CLI / harness gọi API trên cloud** (DeepSeek API, OpenAI-compatible): **chạy được**. Nó chỉ là một chương trình Python/Node gọi HTTPS, dùng `git`/`rg`/`python`/`node` trong máy ảo — đúng những thứ image đã có.
- **Chạy model DeepSeek ngay trong máy ảo**: **không**. Không có GPU/NPU cho guest, RAM guest 1792 MB, và TCG dịch từng instruction. Model 7B q4 đã cần ~4–5 GB RAM; model thật của DeepSeek còn lớn hơn rất nhiều.

Ví dụ cài một agent CLI (chọn công cụ bạn dùng; `pip`/`npm` là đủ):

```bash
# npm toàn cục trong image thuộc root → phải đổi prefix về nhà mình, nếu không
# sẽ gặp hàng loạt "npm error code EACCES ... /usr/local/lib/node_modules"
npm config set prefix ~/.local
grep -q '.local/bin' ~/.bashrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

npm install -g @deepseek-ai/dsh   # hoặc: pip install aider-chat
tmux new -s agent                 # rớt console vẫn không chết agent
export DEEPSEEK_API_KEY=...       # xem cảnh báo bên dưới
dsh web                           # hoặc: opencode / aider --model deepseek/deepseek-chat
```

> Bấm **Cài gói bổ sung** trong tab Shell cũng tự đặt prefix này (và cài `tmux`, `ssh`, `rg`), nên nếu đã bấm thì bỏ qua 3 dòng đầu.

Các CLI này là JavaScript/Python thuần (không cần GPU), nên chỉ cần Node 22/Python 3.13 + mạng + key. Riêng OpenCode/Claude Code sẽ bật thêm language server (`tsserver`, `pyright`) cho từng dự án — đó là phần tốn RAM nhất, nên mở dự án nhỏ trước.

Kiểm tra nhanh trước khi cài (cả hai phải OK):

```bash
curl -sI https://api.deepseek.com | head -1   # phải thấy HTTP/2 200/401..., không phải lỗi certificate
df -h / && free -m                            # xem còn bao nhiêu đĩa/RAM (image chỉ còn ~440 MB đĩa cho user dev)
```

Giới hạn cần biết trước khi chạy agent dài:

| Giới hạn | Cách xử lý |
|---|---|
| Mặc định **1 vCPU** (Chế độ chắc chắn) | Tắt công tắc để dùng 4 vCPU nếu máy chạy ổn; agent chạy test sẽ nhanh hơn nhiều |
| RAM 1792 MB | Tránh monorepo/Next.js; đặt `NODE_OPTIONS=--max-old-space-size=1024`, không chạy song song |
| Đĩa 1.9 GB, chỉ ~440 MB trống cho `dev` | `df -h /`; image được `resize2fs -M` về mức nhỏ nhất nên đừng tin `IMG_SIZE=5G` trong script build. Chỉ nên cài **một** CLI: `npm i -g` xong thì `npm cache clean --force`, `rm -rf ~/.cache/pip`, `sudo apt-get clean`. Hết chỗ thì gỡ bớt gói: `sudo apt-get purge ...` |
| Console chỉ giữ 2000 dòng | Cho agent ghi ra file: `... 2>&1 \| tee ~/agent.log`, xem bằng `tail -f ~/agent.log` hoặc trong `tmux` |
| iOS có thể suspend khi ra nền | Bật **giữ chạy nền** trong Thiết lập; agent dài nên chạy trong `tmux` để nối lại vẫn còn phiên |
| Không có Docker | Harness kiểu SWE-bench cần Docker thì không chạy; harness chỉ gọi API rồi chạy test trực tiếp thì được |
| Chỉ có binary x86_64 | Không chạy (không có Rosetta/box64); chọn bản arm64 hoặc cài qua `pip`/`npm` |

> **Cảnh báo API key:** `serial.log` ghi lại **mọi byte hiện trên console**, kể cả key nếu bạn gõ vào shell. Đừng gửi `serial.log`/`diagnostics.txt` cho người khác khi chưa xoá key. Cách sạch hơn: tạo file key bằng app **Files** trong thư mục chia sẻ (`/mnt/share`), rồi `install -m600 /mnt/share/agent.env ~/.agent.env && source ~/.agent.env`.

## Khi `npm` báo lỗi hoặc hỏi `(y)`

```bash
cd ~/projects/test        # phải đứng trong thư mục có package.json
npm test 2>&1 | head -20  # chỉ cần 20 dòng đầu, phần sau là stack trace
```

| Hiện tượng | Nguyên nhân thật | Làm gì |
|---|---|---|
| Ở `~` gõ `npm test` → nhiều dòng `npm error`, có `ENOENT`/`package.json` | `~` không phải dự án npm, npm không có gì để chạy | `cd` vào thư mục dự án rồi chạy lại |
| `npm error Missing script: "test"` | `package.json` chưa khai báo script `test` | Thêm `"scripts": { "test": "..." }` hoặc chạy script thật (`npm run dev`, `node test.js`…) |
| `Ok to proceed? (y)` khi `npx` | `npx` hỏi có tải gói về không | Gõ `y` rồi gửi — từ **0.2.4 (9)** app không chặn gửi khi lệnh đang chạy/hỏi |
| Hàng trăm dòng `npm error` cho một lỗi | npm in cả stack + log | Đọc 2–3 dòng đầu: `npm error code …`, `npm error path …`, dòng cuối `npm error A complete log…` |

`npm test` chỉ là alias của `npm run test`; nếu dự án không có script đó thì lỗi là đúng, không phải app hay image hỏng.

## Ngân sách tài nguyên (số thật)

| Thứ | Hiện tại | Ghi chú |
|---|---|---|
| Đĩa guest | 1.73 GB đã dùng / 5 GB | còn ~3.2 GB; có thể tăng image lên 16–32 GB |
| RAM guest | 1792 MB | iOS chỉ cho app ~3–3.5 GB; chưa bật zram/swap |
| CPU | 4 vCPU (TCG đa luồng) | A14 |
| Pin/nhiệt | — | build liên tục sẽ throttle sau 15–20 phút |
| Nền | giữ nền bằng audio im lặng | rời app vẫn chạy; Force Quit thì tắt; tốn pin |

## Bài test nghiệm thu

Copy nguyên khối này vào terminal của app; **pass** = mọi lệnh in kết quả thật:

```bash
uname -a                  # Linux devbox 6.12.113+deb13-arm64 ... aarch64 GNU/Linux
python3 --version         # Python 3.13.5
node -v                   # v22.23.4
npm -v
git --version
gcc --version

pip install requests
python3 -c "import requests; print('requests', requests.__version__)"

mkdir -p ~/projects/test && cd ~/projects/test
npm init -y
npm install express
node -e "require('express'); console.log('express ok')"

printf '#include <stdio.h>\nint main(){puts("hello from linux");}\n' > h.c
gcc h.c -o h && ./h
df -h /
```

## "Toàn diện" nghĩa là gì — và không là gì

Toàn diện **trong phạm vi CLI Linux**: gần như mọi thứ bạn gõ trên VPS Debian đều chạy, chỉ chậm hơn và bị giới hạn RAM/đĩa.

Không phải "máy tính Linux thay laptop": không GUI, không GPU, không build nặng.

Nếu cần "toàn diện" hơn nữa:

| Nhu cầu | Cách làm |
|---|---|
| Editor/IDE | M4: chạy `code-server` trong guest → VS Code mở trong WKWebView của app, không cần GUI |
| SSH vào server thật | `apt install openssh-client` |
| Nhiều dự án lớn cùng lúc | tăng image; RAM guest cố định 1792 MB |
| GUI app | ngoài phạm vi (cần virtio-gpu + display stack) |

## Bạn cần chốt

Danh sách CLI bạn thực sự dùng hằng ngày (ví dụ: `python + pip + pandas`, `node + npm + vite`, `git`, `gcc`, `ssh`, `sqlite3`, `ffmpeg`…). Mình sẽ đưa đúng danh sách đó vào acceptance test và cài sẵn trong image, thay vì đoán.
