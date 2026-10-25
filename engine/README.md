# engine/

Chỗ đặt fork **UTM/QEMU** và phần glue của Cellar.

Chưa có code ở đây. Kế hoạch (M1):

```
engine/
├── UTM/                     # git submodule: https://github.com/utmapp/UTM (Apache-2.0)
├── patches/cellar/
│   ├── 0001-virtio-serial-agent-channel.patch
│   ├── 0002-engine-api.patch
│   └── 0003-stats.patch
└── scripts/
    └── build-qemu-ios.sh    # dùng lại scripts/ của UTM
```

Nguyên tắc:

- Không sửa lung tung vào QEMU. Mọi thay đổi nằm trong `patches/` để rebase được với upstream.
- QEMU là **GPLv2** → khi phát hành IPA phải công bố source của fork này.
- Phần SwiftUI trong `app/` chỉ gọi `CellarEngine` (API C/ObjC++), không gọi QEMU trực tiếp.

Việc cần làm đầu tiên: build được UTM gốc trên GitHub Actions, cài lên iPhone, xác nhận JIT hoạt động.
