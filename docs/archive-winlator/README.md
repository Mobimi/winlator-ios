# Archive — hướng Winlator (đã dừng)

Các tài liệu trong thư mục này thuộc hướng đi ban đầu: **chạy game Windows trên iOS** bằng QEMU + Linux + Wine + box64 + DXVK.

Hướng đó **không bị bỏ vì sai kỹ thuật**, mà vì:

1. Trên iPhone 12 Pro Max (A14, 6 GB), game mục tiêu (MiSide/Unity 3D) **không đạt ngưỡng tối thiểu** về RAM và CPU sau 2 lớp dịch.
2. Dự án lớn gấp ~4–5 lần hướng hiện tại (9–12 tháng so với ~3 tháng).
3. Giá trị sử dụng thấp hơn nhiều so với công sức.

Đổi sang **Devbox** — cùng engine QEMU, nhưng bỏ Wine/GPU/box64, chỉ chạy Linux + terminal cho Python/Node.

## Nội dung

| File | Nội dung |
|---|---|
| `00-bat-dau-tu-day.md` | Hướng dẫn cài bản Cellar (tên cũ) — phần Sideloadly/StikDebug vẫn dùng được cho Devbox |
| `01-kha-thi-ky-thuat.md` | Rào cản JIT/tiến trình/GPU của iOS; ngân sách hiệu năng |
| `02-kien-truc.md` | Kiến trúc Wine + box64 + DXVK + Venus + SPICE |
| `03-roadmap.md` | Roadmap M0–M5 của hướng cũ |
| `05-mita-miside-tren-iphone.md` | Vì sao MiSide không chạy trên iPhone 12 Pro Max; cách stream từ laptop |
| `engine-README.md`, `guest-README.md` | Ghi chú fork UTM và rootfs Wine |

## Có thể tái sử dụng cho Devbox

- Cơ chế build `.ipa` trên GitHub Actions (đã chuyển sang dùng).
- Cách bật JIT bằng StikDebug.
- Kiến thức fork UTM: `QEMULauncher`, `QEMUHelper`, cơ chế JIT.
- Kiểm tra JIT trong app (`DeviceProbe`).
