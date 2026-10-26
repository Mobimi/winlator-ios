import Foundation

/// Một cách sửa cho lỗi vừa xảy ra. Chỉ chạy khi người dùng bấm — app không
/// tự sửa gì, vì cùng một dòng lỗi có thể do nhiều nguyên nhân khác nhau.
struct Repair: Identifiable {
    enum Action {
        /// Gõ lệnh này vào shell (hiện thành một khối kết quả riêng).
        case run(String)
        /// Chép 20 dòng cuối để gửi cho người khác/cho mình xem sau.
        case copyTail
        case healthCheck
        case ports
    }

    let id = UUID()
    var title: String
    var detail: String
    var action: Action
    /// Lệnh chỉ đọc: xem phiên bản, kiểm tra mạng, liệt kê file… Không đổi gì
    /// trong máy ảo nên an toàn để bấm thử trước.
    var readOnly = false

    var command: String? {
        if case .run(let text) = action { return text }
        return nil
    }
}

/// Kết quả "bác sĩ lỗi": nói vì sao lỗi bằng tiếng Việt, đưa vài lệnh sửa
/// xếp theo khả năng đúng, và vài lệnh chẩn đoán chỉ đọc.
struct ErrorCase {
    var headline: String
    var cause: String
    var repairs: [Repair]
    var probes: [Repair]
    var errorLine: String
}

/// Nhận dạng lỗi theo mẫu đã biết rồi dịch thành lệnh sửa.
///
/// Đây không phải AI: mỗi mẫu là một dòng lỗi thật đã gặp (npm, pip, apt,
/// python, node, git), kèm cách sửa đã kiểm chứng. Mẫu không khớp thì app
/// không đoán bừa — chỉ đưa lệnh chẩn đoán và lời nhắn gửi 20 dòng cuối.
enum ErrorDoctor {
    static func diagnose(command: String, lines: [String], exitCode: Int?) -> ErrorCase? {
        let window = Array(lines.suffix(40))
        let joined = window.joined(separator: "\n")
        let scope = joined.lowercased()
        let line = errorLine(window)
        let spec = installSpec(command)
        let failed = (exitCode ?? 0) != 0

        if let code = npmCode(window) {
            return npmCase(code: code, command: command, spec: spec, window: window, line: line)
        }
        if scope.contains("bad interpreter") {
            let script = lastToken(command)
            return ErrorCase(
                headline: "Script có ký tự xuống dòng kiểu Windows (CRLF)",
                cause: """
                Dòng đầu `#!/usr/bin/env python3` bị dính `\\r` khi lưu từ Windows, nên Linux đọc shebang \
                thành `python3\\r` và không tìm ra trình thông dịch. Bỏ `\\r` là xong.
                """,
                repairs: [
                    Repair(title: "Bỏ CRLF rồi chạy lại", detail: "sed -i 's/\\r$//' trên đúng file đó", action: .run("sed -i 's/\\r$//' \(script) && \(command)")),
                    Repair(title: "Bỏ CRLF cả thư mục", detail: "khi nhiều file cùng bị", action: .run("find . -maxdepth 2 -type f \\( -name '*.sh' -o -name '*.py' \\) | xargs -r sed -i 's/\\r$//'"))
                ],
                probes: [
                    Repair(title: "Đếm ký tự CR", detail: "file có bao nhiêu dòng CRLF", action: .run("grep -c $'\\r' \(script) || true"), readOnly: true)
                ],
                errorLine: line)
        }
        if scope.contains("gyp err!") || scope.contains("node-pre-gyp") {
            return ErrorCase(
                headline: "Gói cần biên dịch C++ nhưng máy ảo thiếu công cụ",
                cause: """
                Một dependency dùng `node-gyp`, cần `make`, `g++` và header của Python. Image có gcc nhưng \
                không đủ bộ `build-essential`, nên bước biên dịch dừng giữa đường.
                """,
                repairs: [
                    Repair(title: "Cài build-essential", detail: "make + g++ + python3-dev (~150 MB)", action: .run("sudo apt-get install -y build-essential python3-dev && \(command)")),
                    Repair(title: "Bỏ qua script build", detail: "nếu gói không thật sự cần native module", action: .run("\(command) --ignore-scripts"))
                ],
                probes: [
                    Repair(title: "Còn bao nhiêu chỗ?", detail: "node-gyp cần thêm ~200 MB", action: .run("df -h / | tail -1"), readOnly: true),
                    Repair(title: "Đã có make/g++?", detail: "kiểm tra nhanh bộ biên dịch", action: .run("command -v make g++ python3"), readOnly: true)
                ],
                errorLine: line)
        }
        if scope.contains("externally-managed-environment") {
            return ErrorCase(
                headline: "Debian 13 chặn `pip install` vào Python hệ thống",
                cause: """
                Từ Debian 12, pip từ chối ghi vào `/usr/lib/python3` để không phá hệ thống (PEP 668). \
                Cách đúng là tạo venv cho từng dự án, hoặc cài bằng `apt` nếu có gói.
                """,
                repairs: [
                    Repair(title: "Tạo venv rồi cài", detail: "cách sạch nhất, giữ nguyên Python hệ thống", action: .run("python3 -m venv ~/.venv && . ~/.venv/bin/activate && pip install \(pipPackages(command))")),
                    Repair(title: "Cài cho user (`--user`)", detail: "nhanh, nhưng vẫn có thể bị chặn", action: .run("pip install --user --break-system-packages \(pipPackages(command))")),
                    Repair(title: "Cài bằng apt", detail: "nếu gói có trong kho Debian", action: .run("sudo apt-get install -y python3-\(pipPackages(command).split(separator: " ").first.map(String.init) ?? "pip")"))
                ],
                probes: [
                    Repair(title: "Đang ở đâu?", detail: "xem python/pip nào đang dùng", action: .run("which python3 pip; python3 -c 'import sys; print(sys.prefix)'"), readOnly: true)
                ],
                errorLine: line)
        }
        if scope.contains("no matching distribution found") || scope.contains("could not find a version that satisfies") {
            let package = pipPackages(command)
            return ErrorCase(
                headline: "PyPI không có gói/phiên bản “\(package)”",
                cause: """
                Thường là sai tên gói (PyPI phân biệt `opencv-python` với `cv2`), hoặc gói không có bản \
                cho ARM64/Python 3.13, hoặc mạng không tới được PyPI.
                """,
                repairs: [
                    Repair(title: "Xem phiên bản có thật", detail: "liệt kê bản phát hành trên PyPI", action: .run("pip index versions \(package) 2>&1 | head -5")),
                    Repair(title: "Thử tên khác", detail: "đổi tên gói rồi cài lại", action: .run("pip install \(pipAlias(package))")),
                    Repair(title: "Kiểm tra mạng/PyPI", detail: "DNS hoặc TLS hỏng cũng báo y như sai tên", action: .run("curl -sI --max-time 8 https://pypi.org/simple/ | head -1"))
                ],
                probes: [
                    Repair(title: "Python bao nhiêu?", detail: "một số gói chưa có wheel cho 3.13", action: .run("python3 -V; uname -m"), readOnly: true),
                    Repair(title: "Kiểm tra nhanh", detail: "đĩa, DNS, TLS tới registry", action: .healthCheck, readOnly: true)
                ],
                errorLine: line)
        }
        if scope.contains("failed building wheel") || scope.contains("could not build wheels") {
            let package = pipPackages(command)
            return ErrorCase(
                headline: "pip không biên dịch được “\(package)”",
                cause: """
                Gói không có wheel cho ARM64 nên pip phải tự biên dịch, và thiếu header/thư viện hệ thống. \
                Cách chắc ăn: cài gói phụ thuộc bằng apt trước, hoặc dùng bản wheel có sẵn.
                """,
                repairs: [
                    Repair(title: "Cài công cụ biên dịch", detail: "build-essential + python3-dev", action: .run("sudo apt-get install -y build-essential python3-dev && pip install \(package)")),
                    Repair(title: "Chỉ dùng wheel", detail: "bỏ qua gói phải biên dịch", action: .run("pip install --only-binary=:all: \(package)"))
                ],
                probes: [
                    Repair(title: "Xem lỗi biên dịch", detail: "giữ 25 dòng cuối của log", action: .copyTail)
                ],
                errorLine: line)
        }
        if let module = capture(#"no module named '([^']+)'"#, in: joined) {
            let package = pipAlias(module)
            return ErrorCase(
                headline: "Thiếu thư viện Python “\(module)”",
                cause: """
                Script `import \(module)` nhưng gói chưa có trong máy ảo. Tên gói trên PyPI thường khác \
                tên module (`cv2` → `opencv-python`, `PIL` → `pillow`), nên app đã đổi sẵn.
                """,
                repairs: [
                    Repair(title: "Cài \(package)", detail: "cài vào môi trường đang chạy", action: .run("pip install \(package)")),
                    Repair(title: "Cài bằng apt", detail: "bản trong kho Debian, không cần mạng PyPI", action: .run("sudo apt-get install -y python3-\(package.lowercased())"))
                ],
                probes: [
                    Repair(title: "Đang dùng Python nào?", detail: "venv hay Python hệ thống", action: .run("which python3 pip; python3 -V"), readOnly: true)
                ],
                errorLine: line)
        }
        if scope.contains("address already in use") || scope.contains("eaddrinuse") {
            let port = capture(#":(\d{2,5})"#, in: scope) ?? capture(#"port (\d{2,5})"#, in: scope) ?? "8000"
            return ErrorCase(
                headline: "Cổng \(port) đang bị tiến trình khác giữ",
                cause: """
                Server cũ chưa tắt (hoặc chạy nền từ lần trước) nên cổng vẫn ở trạng thái LISTEN. \
                Tắt đúng tiến trình rồi chạy lại, đừng đổi sang cổng khác nếu app chưa forward cổng đó.
                """,
                repairs: [
                    Repair(title: "Tắt tiến trình giữ cổng", detail: "kill theo socket, không cần nhớ PID", action: .run("fuser -k \(port)/tcp 2>/dev/null; sudo ss -ltnp | grep ':\(port)' || echo 'cổng đã trống'")),
                    Repair(title: "Chạy lại", detail: "gửi lại đúng lệnh vừa lỗi", action: .run(command))
                ],
                probes: [
                    Repair(title: "Ai đang giữ cổng?", detail: "liệt kê tiến trình theo cổng", action: .run("sudo ss -ltnp | grep ':\(port)'"), readOnly: true),
                    Repair(title: "Cổng đang mở", detail: "xem danh sách app đã forward", action: .ports, readOnly: true)
                ],
                errorLine: line)
        }
        if scope.contains("unable to locate package") || scope.contains("has no installation candidate") {
            return ErrorCase(
                headline: "apt không biết gói này",
                cause: """
                Danh sách gói trong image được tạo lúc build, có thể đã cũ hoặc thiếu `contrib`/`non-free`. \
                `apt-get update` lấy lại danh sách; nếu vẫn không có thì tên gói sai.
                """,
                repairs: [
                    Repair(title: "Cập nhật danh sách gói", detail: "apt-get update rồi cài lại", action: .run("sudo apt-get update && \(command)")),
                    Repair(title: "Tìm tên đúng", detail: "apt search theo từ khoá", action: .run("apt-cache search \(aptName(command)) | head -10"))
                ],
                probes: [
                    Repair(title: "Kho đang bật", detail: "xem sources.list", action: .run("grep -rh '^deb ' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | head -5"), readOnly: true)
                ],
                errorLine: line)
        }
        if scope.contains("dpkg was interrupted") || scope.contains("could not get lock") {
            return ErrorCase(
                headline: "apt/dpkg đang dở dang",
                cause: """
                Lần cài trước bị ngắt (hoặc app tự gửi lệnh khi apt đang chạy) nên khoá `/var/lib/dpkg/lock` \
                còn đó. Phải cấu hình lại các gói dở rồi mới cài tiếp.
                """,
                repairs: [
                    Repair(title: "Hoàn tất cấu hình", detail: "dpkg --configure -a rồi chạy lại", action: .run("sudo dpkg --configure -a && \(command)")),
                    Repair(title: "Xem ai giữ khoá", detail: "thường là apt-get của lần trước", action: .run("ps aux | grep -E 'apt|dpkg' | grep -v grep"))
                ],
                probes: [
                    Repair(title: "Còn tiến trình apt?", detail: "kiểm tra trước khi xoá lock", action: .run("pgrep -a apt; pgrep -a dpkg"), readOnly: true)
                ],
                errorLine: line)
        }
        if scope.contains("temporary failure resolving") || scope.contains("could not resolve host")
            || scope.contains("network is unreachable") || scope.contains("name or service not known") {
            return ErrorCase(
                headline: "Máy ảo không phân giải được tên miền",
                cause: """
                DNS của QEMU (10.0.2.3) không trả lời, nên apt/pip/npm/git lỗi hàng loạt dù mạng iOS vẫn tốt. \
                Ghi lại nameserver rồi thử lại là đủ trong phần lớn trường hợp.
                """,
                repairs: [
                    Repair(title: "Sửa DNS rồi chạy lại", detail: "trỏ resolv.conf về DNS của QEMU", action: .run("echo 'nameserver 10.0.2.3' | sudo tee /etc/resolv.conf >/dev/null && \(command)")),
                    Repair(title: "Thử DNS công cộng", detail: "khi 10.0.2.3 cũng hỏng", action: .run("echo 'nameserver 1.1.1.1' | sudo tee /etc/resolv.conf >/dev/null && \(command)"))
                ],
                probes: [
                    Repair(title: "Ping gateway", detail: "10.0.2.2 là cổng ra của QEMU", action: .run("ping -c1 -W2 10.0.2.2; cat /etc/resolv.conf"), readOnly: true),
                    Repair(title: "Kiểm tra nhanh", detail: "đĩa, DNS, TLS tới registry", action: .healthCheck, readOnly: true)
                ],
                errorLine: line)
        }
        if scope.contains("no space left on device") || scope.contains("enospc") {
            return ErrorCase(
                headline: "Đĩa ảo đã đầy",
                cause: """
                Rootfs chỉ còn khoảng 400–500 MB cho user `dev`. `node_modules` của một dự án trung bình \
                đã vượt mức đó, nên npm ghi dở rồi báo ENOSPC/EINTEGRITY.
                """,
                repairs: [
                    Repair(title: "Dọn cache", detail: "apt + npm + pip, thường lấy lại được 100–200 MB", action: .run("sudo apt-get clean; rm -rf ~/.npm/_cacache ~/.cache/pip ~/.cache/node-gyp; df -h /")),
                    Repair(title: "Xem chỗ nào nặng", detail: "tìm thư mục lớn nhất trong /home", action: .run("du -xh --max-depth=2 ~ 2>/dev/null | sort -h | tail -12"))
                ],
                probes: [
                    Repair(title: "Còn bao nhiêu?", detail: "df + inode", action: .run("df -h /; df -i / | tail -1"), readOnly: true)
                ],
                errorLine: line)
        }
        if scope.contains("permission denied (publickey)") {
            return ErrorCase(
                headline: "Git không có khoá SSH để vào repo",
                cause: """
                Repo dùng `git@github.com:...` cần khoá SSH, mà máy ảo chưa có. Với repo công khai, \
                đổi sang HTTPS là xong; repo riêng tư thì phải tạo khoá và thêm lên GitHub.
                """,
                repairs: [
                    Repair(title: "Đổi sang HTTPS", detail: "repo công khai không cần khoá", action: .run("git config --global url.\"https://github.com/\".insteadOf \"git@github.com:\" && \(command)")),
                    Repair(title: "Tạo khoá SSH", detail: "rồi dán public key vào GitHub", action: .run("ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519 <<< y >/dev/null; cat ~/.ssh/id_ed25519.pub"))
                ],
                probes: [
                    Repair(title: "Đã có khoá chưa?", detail: "liệt kê ~/.ssh", action: .run("ls -la ~/.ssh 2>/dev/null || echo 'chưa có ~/.ssh'"), readOnly: true)
                ],
                errorLine: line)
        }
        if scope.contains("permission denied") {
            return ErrorCase(
                headline: "Không đủ quyền để đọc/ghi tệp",
                cause: """
                File thuộc root, hoặc file trên `/mnt/share` (9p) không giữ bit `+x` sau khi chép từ iPhone. \
                Với script, gọi thẳng trình thông dịch (`python3 file.py`) là cách chắc ăn nhất.
                """,
                repairs: [
                    Repair(title: "Chạy bằng python3", detail: "bỏ qua bit +x của 9p", action: .run("python3 \(lastToken(command))")),
                    Repair(title: "Cấp quyền", detail: "chmod +x rồi chạy lại", action: .run("sudo chmod +x \(lastToken(command)) && \(command)")),
                    Repair(title: "Chép vào home rồi chạy", detail: "9p không giữ quyền, ext4 thì có", action: .run("mkdir -p ~/bin && cp \(lastToken(command)) ~/bin/ && chmod +x ~/bin/\(lastComponent(command)) && ~/bin/\(lastComponent(command))"))
                ],
                probes: [
                    Repair(title: "Ai sở hữu tệp?", detail: "ls -l tệp vừa lỗi", action: .run("ls -l \(lastToken(command))"), readOnly: true)
                ],
                errorLine: line)
        }
        if scope.contains("no such file or directory") || scope.contains("can't open file")
            || scope.contains("cannot find module") || scope.contains("no such file") {
            let token = missingToken(window) ?? lastToken(command)
            let component = (token as NSString).lastPathComponent
            return ErrorCase(
                headline: "Không thấy “\(component)” trong máy ảo",
                cause: """
                File đang ở phía iPhone (`Devbox/…`) chứ chưa vào `/mnt/share`, hoặc bạn đang đứng sai thư mục. \
                Chỉ `Devbox/share` mới nối vào máy ảo.
                """,
                repairs: [
                    Repair(title: "Tìm trong share", detail: "tìm không phân biệt hoa thường rồi cd đúng chỗ", action: .run("find /mnt/share -iname '\(component)' -maxdepth 4 2>/dev/null | head -5")),
                    Repair(title: "Đưa file vào share", detail: "chép vào `_import` để chắc chắn đúng thư mục", action: .run("mkdir -p /mnt/share/_import && ls -la /mnt/share/_import")),
                    Repair(title: "Xem đang ở đâu", detail: "pwd + ls thư mục hiện tại", action: .run("pwd; ls -la"))
                ],
                probes: [
                    Repair(title: "Liệt kê ~/projects", detail: "dự án nằm trong ext4 của image", action: .run("ls -la ~/projects 2>/dev/null | head -20"), readOnly: true),
                    Repair(title: "Kiểm tra nhanh", detail: "đĩa, DNS, node/python", action: .healthCheck, readOnly: true)
                ],
                errorLine: line)
        }
        if scope.contains("syntaxerror") || scope.contains("indentationerror") || scope.contains("taberror") {
            let file = capture(#"file "([^"]+)""#, in: joined) ?? lastToken(command)
            return ErrorCase(
                headline: "Script Python sai cú pháp/thụt lề",
                cause: """
                Python đọc tới dòng báo lỗi và dừng. Hay gặp khi file được sửa trên Windows (tab lẫn space) \
                hoặc khi dán code bị mất thụt lề. Đây là lỗi trong file, không phải app hay image.
                """,
                repairs: [
                    Repair(title: "Xem dòng lỗi", detail: "in 25 dòng quanh chỗ báo lỗi", action: .run("python3 -m py_compile \(file) 2>&1 | head -25")),
                    Repair(title: "Đổi tab thành 4 space", detail: "chuẩn hoá thụt lề toàn file", action: .run("expand -t4 \(file) > \(file).fixed && mv \(file).fixed \(file) && python3 \(file)"))
                ],
                probes: [
                    Repair(title: "File có CRLF?", detail: "ký tự \\r của Windows", action: .run("grep -c $'\\r' \(file) || true"), readOnly: true)
                ],
                errorLine: line)
        }
        if scope.contains("unicode decode error") || scope.contains("unicodedecodeerror") {
            let file = capture(#"file "([^"]+)""#, in: joined) ?? lastToken(command)
            return ErrorCase(
                headline: "File không phải UTF-8",
                cause: """
                Python mặc định đọc UTF-8; file lưu bằng CP1252/ANSI trên Windows sẽ lỗi ở byte lạ. \
                Chuyển sang UTF-8 (hoặc mở bằng `encoding=` phù hợp) là xong.
                """,
                repairs: [
                    Repair(title: "Chuyển sang UTF-8", detail: "iconv từ CP1252 (Windows) sang UTF-8", action: .run("iconv -f CP1252 -t UTF-8 \(file) > \(file).utf8 && mv \(file).utf8 \(file) && echo OK")),
                    Repair(title: "Xem byte lỗi", detail: "hexdump quanh vị trí lỗi", action: .run("python3 -c \"import sys;d=open(sys.argv[1],'rb').read();print(d[:200])\" \(file)"))
                ],
                probes: [
                    Repair(title: "File ở đâu?", detail: "đường dẫn đầy đủ", action: .run("ls -l \(file)"), readOnly: true)
                ],
                errorLine: line)
        }
        if scope.contains("killed") && (scope.contains("memory") || scope.contains("oom") || scope.contains("npm")) {
            return ErrorCase(
                headline: "Tiến trình bị iOS giết vì hết RAM",
                cause: """
                Máy ảo chỉ có 1–2 GB RAM; `npm install` trên dự án lớn hoặc build TypeScript dễ vượt mức. \
                iOS kill tiến trình nên bạn chỉ thấy `Killed`, không có stack trace.
                """,
                repairs: [
                    Repair(title: "Giảm việc cho npm", detail: "bỏ audit/fund, cài tuần tự", action: .run("npm i --no-audit --no-fund --maxsockets 3")),
                    Repair(title: "Xem RAM còn lại", detail: "free -m", action: .run("free -m; ps aux --sort=-rss | head -6"))
                ],
                probes: [
                    Repair(title: "Kiểm tra nhanh", detail: "RAM, đĩa, node", action: .healthCheck, readOnly: true)
                ],
                errorLine: line)
        }
        if scope.contains("command not found") || scope.contains("not found and is not installed") {
            let name = capture(#"([\w.+-]+): command not found"#, in: scope) ?? lastToken(command)
            return ErrorCase(
                headline: "Chưa cài “\(name)”",
                cause: """
                Lệnh không có trong image. Với gói Debian thường cài được bằng apt; với CLI Node thì \
                `npm i -g` (đã trỏ về `~/.local` nên không cần sudo).
                """,
                repairs: [
                    Repair(title: "Cài bằng apt", detail: "thử trước, thường nhẹ và ổn định", action: .run("sudo apt-get install -y \(name)")),
                    Repair(title: "Cài bằng npm", detail: "cho CLI viết bằng Node", action: .run("npm i -g \(name)")),
                    Repair(title: "Tìm gói chứa lệnh", detail: "apt-file nếu đã cài, không thì apt-cache", action: .run("apt-cache search \(name) | head -8"))
                ],
                probes: [
                    Repair(title: "Lệnh có ở đâu?", detail: "which + ls ~/.local/bin", action: .run("command -v \(name); ls ~/.local/bin | head -20"), readOnly: true)
                ],
                errorLine: line)
        }
        // Chỉ đưa thẻ "lỗi lạ" khi biết chắc lệnh đã hỏng (có mã thoát ≠ 0).
        // Nếu dựa vào output thì mọi lệnh in chữ "error" (vd `cat log`) đều
        // bị gắn thẻ oan.
        guard failed, let code = exitCode else { return nil }
        return ErrorCase(
            headline: "Lệnh thoát với mã \(code) nhưng chưa khớp lỗi nào app biết",
            cause: """
            App chỉ nhận dạng các mẫu lỗi phổ biến (npm/pip/apt/python/node/git). Lỗi lạ thì đoán bừa sẽ \
            làm hỏng thêm, nên đây là các bước kiểm tra an toàn. Gửi mình 20 dòng cuối là cách nhanh nhất \
            để bổ sung mẫu mới vào app.
            """,
            repairs: [
                Repair(title: "Sao chép 20 dòng cuối", detail: "gửi cho người hỗ trợ hoặc dán vào ghi chú", action: .copyTail),
                Repair(title: "Chạy kiểm tra nhanh", detail: "đĩa, RAM, DNS, python/node/npm", action: .healthCheck)
            ],
            probes: [
                Repair(title: "Mã thoát thật", detail: "xác nhận exit code của lệnh vừa rồi", action: .run("echo \"exit=$?\"; df -h / | tail -1"), readOnly: true)
            ],
            errorLine: line)
    }

    // MARK: - npm

    private static func npmCase(code: String, command: String, spec: String?, window: [String], line: String) -> ErrorCase? {
        let package = spec ?? npmPackage(window) ?? ""
        let bare: String = {
            guard !package.isEmpty else { return "" }
            if package.hasPrefix("@") { return package }
            return package.split(separator: "@").first.map(String.init) ?? package
        }()
        switch code {
        case "E404", "E403":
            // `npm i -g owner/repo` là hiểu nhầm phổ biến: npm đi tìm gói tên
            // "owner/repo" trên registry chứ không vào GitHub.
            if !package.isEmpty, let repo = githubRepo(package) {
                let repoName = repo.split(separator: "/").last.map(String.init) ?? repo
                return ErrorCase(
                    headline: "npm không có gói “\(package)” — có thể ý bạn là repo GitHub",
                    cause: """
                    `npm install \(package)` bị hiểu là *tên gói trên registry.npmjs.org*, nên npm trả 404. \
                    Repo GitHub không tự có trên npm; phải ghi rõ nguồn bằng `github:owner/repo` hoặc URL.
                    """,
                    repairs: [
                        Repair(title: "Cài từ GitHub", detail: "npm lấy thẳng repo \(repo) qua git", action: .run("npm i -g github:\(repo)")),
                        Repair(title: "Cài từ file nén", detail: "không cần git, tải tar.gz nhánh main", action: .run("npm i -g https://github.com/\(repo)/archive/refs/heads/main.tar.gz")),
                        Repair(title: "Clone rồi cài tại chỗ", detail: "xem mã nguồn trước, sửa được lỗi build", action: .run("git clone https://github.com/\(repo) ~/src/\(repoName) && cd ~/src/\(repoName) && npm i && npm i -g ."))
                    ],
                    probes: [
                        Repair(title: "Repo có thật không?", detail: "sai tên hoặc repo riêng tư cũng 404", action: .run("git ls-remote https://github.com/\(repo) HEAD"), readOnly: true),
                        Repair(title: "Trên npm có gói này?", detail: "xem bản phát hành chính thức", action: .run("npm view \(bare) version"), readOnly: true)
                    ],
                    errorLine: line)
            }
            return ErrorCase(
                headline: "npm không tìm thấy “\(bare.isEmpty ? "gói này" : bare)”",
                cause: """
                E404/403 thường là sai chính tả tên gói, gói đã bị xoá, hoặc registry bị đổi sang mirror \
                không có gói đó. Nếu là repo GitHub thì phải dùng `github:owner/repo`.
                """,
                repairs: [
                    Repair(title: "Xem tên trên npm", detail: "npm view — 404 nghĩa là tên sai", action: .run("npm view \(bare) version")),
                    Repair(title: "Đổi registry về mặc định", detail: "mirror cũ có thể thiếu gói", action: .run("npm config set registry https://registry.npmjs.org/ && \(command)")),
                    Repair(title: "Cài từ GitHub", detail: "nếu gói chỉ có trên GitHub", action: .run("npm i -g github:\(bare)"))
                ],
                probes: [
                    Repair(title: "Registry đang dùng", detail: "so sánh với registry.npmjs.org", action: .run("npm config get registry"), readOnly: true),
                    Repair(title: "Mạng tới registry", detail: "DNS/TLS hỏng cũng báo lỗi gói", action: .run("curl -sI --max-time 8 https://registry.npmjs.org | head -1"), readOnly: true)
                ],
                errorLine: line)
        case "EACCES", "EPERM":
            return ErrorCase(
                headline: "npm không có quyền ghi thư mục cài đặt",
                cause: """
                npm đang cố ghi vào `/usr/local/lib/node_modules` của root. Cách đúng là đổi prefix về \
                `~/.local` (app cũng tự làm việc này mỗi lần boot) — đừng dùng sudo cho npm.
                """,
                repairs: [
                    Repair(title: "Đổi prefix về ~/.local", detail: "rồi cài lại, không cần sudo", action: .run("npm config set prefix ~/.local && export PATH=\"$HOME/.local/bin:$PATH\" && hash -r && \(command)")),
                    Repair(title: "Sửa quyền thư mục", detail: "nếu bạn cố ý dùng prefix hệ thống", action: .run("sudo chown -R $(id -u):$(id -g) /usr/local/lib/node_modules /usr/local/bin && \(command)"))
                ],
                probes: [
                    Repair(title: "Prefix hiện tại", detail: "phải là /home/dev/.local", action: .run("npm config get prefix; npm config get cache"), readOnly: true)
                ],
                errorLine: line)
        case "ERESOLVE":
            return ErrorCase(
                headline: "Hai gói đòi hai phiên bản khác nhau của cùng một dependency",
                cause: """
                npm 7+ chặn cài khi peer dependency xung đột. `--legacy-peer-deps` bỏ qua kiểm tra (giống \
                npm 6) — chạy được nhưng có thể lỗi runtime nếu hai bản thật sự không tương thích.
                """,
                repairs: [
                    Repair(title: "Bỏ qua kiểm tra peer", detail: "cách nhanh nhất, hợp với đa số dự án cũ", action: .run("\(command) --legacy-peer-deps")),
                    Repair(title: "Xem vì sao xung đột", detail: "in cây dependency để tự quyết", action: .run("npm ls --all 2>&1 | head -30")),
                    Repair(title: "Xoá lock rồi cài lại", detail: "khi lockfile cũ giữ phiên bản sai", action: .run("rm -rf node_modules package-lock.json && npm i --legacy-peer-deps"))
                ],
                probes: [
                    Repair(title: "Node/npm phiên bản", detail: "npm cũ xử lý peer khác npm mới", action: .run("node -v; npm -v"), readOnly: true)
                ],
                errorLine: line)
        case "EINTEGRITY", "ERR_SOCKET_TIMEOUT":
            return ErrorCase(
                headline: "Cache npm hỏng (hay xảy ra sau khi hết đĩa)",
                cause: """
                npm phát hiện file trong `~/.npm/_cacache` không khớp checksum. Xoá cache rồi tải lại là đủ; \
                nếu lặp lại thì kiểm tra dung lượng đĩa.
                """,
                repairs: [
                    Repair(title: "Xoá cache rồi cài lại", detail: "npm cache clean --force", action: .run("npm cache clean --force && \(command)")),
                    Repair(title: "Xoá node_modules + lock", detail: "khi cache sạch vẫn lỗi", action: .run("rm -rf node_modules package-lock.json && npm i"))
                ],
                probes: [
                    Repair(title: "Còn bao nhiêu chỗ?", detail: "ENOSPC cũng gây checksum sai", action: .run("df -h / | tail -1"), readOnly: true)
                ],
                errorLine: line)
        case "ENOSPC":
            return ErrorCase(
                headline: "Hết đĩa khi npm đang cài",
                cause: """
                Rootfs chỉ còn vài trăm MB cho user `dev`; `node_modules` một dự án Next/Vite dễ vượt mức. \
                Dọn cache trước, và nếu vẫn thiếu thì cần tăng dung lượng image (báo mình để làm bản riêng).
                """,
                repairs: [
                    Repair(title: "Dọn cache", detail: "apt + npm + pip", action: .run("sudo apt-get clean; rm -rf ~/.npm/_cacache ~/.cache/pip; df -h /")),
                    Repair(title: "Xem chỗ nào nặng", detail: "du trong home", action: .run("du -xh --max-depth=2 ~ 2>/dev/null | sort -h | tail -12"))
                ],
                probes: [
                    Repair(title: "Dung lượng", detail: "df -h /", action: .run("df -h /; df -i / | tail -1"), readOnly: true)
                ],
                errorLine: line)
        case "EAI_AGAIN", "ENOTFOUND", "ETIMEDOUT", "ECONNRESET", "ECONNREFUSED":
            return ErrorCase(
                headline: "npm không kết nối được registry",
                cause: """
                DNS hoặc đường ra Internet của máy ảo hỏng. Mọi lệnh apt/pip/git cũng sẽ lỗi cùng lúc; \
                sửa `/etc/resolv.conf` là xong trong đa số trường hợp.
                """,
                repairs: [
                    Repair(title: "Sửa DNS rồi cài lại", detail: "DNS của QEMU: 10.0.2.3", action: .run("echo 'nameserver 10.0.2.3' | sudo tee /etc/resolv.conf >/dev/null && \(command)")),
                    Repair(title: "Kiểm tra nhanh", detail: "đĩa, DNS, TLS tới registry npm", action: .healthCheck)
                ],
                probes: [
                    Repair(title: "DNS có trả lời?", detail: "getent hosts + curl -I", action: .run("getent hosts registry.npmjs.org; curl -sI --max-time 8 https://registry.npmjs.org | head -1"), readOnly: true)
                ],
                errorLine: line)
        case "ETARGET":
            return ErrorCase(
                headline: "Không có phiên bản bạn yêu cầu",
                cause: """
                Tag/phiên bản trong lệnh không tồn tại (gõ sai, hoặc gói chỉ có bản khác). Xem danh sách \
                bản phát hành rồi chọn một bản có thật.
                """,
                repairs: [
                    Repair(title: "Xem bản có thật", detail: "8 bản mới nhất", action: .run("npm view \(bare) versions --json | tail -8")),
                    Repair(title: "Cài bản mới nhất", detail: "bỏ tag/phiên bản đã sai", action: .run("npm i -g \(bare)@latest"))
                ],
                probes: [],
                errorLine: line)
        case "EBADENGINE":
            return ErrorCase(
                headline: "Gói đòi phiên bản Node khác",
                cause: """
                `engines` của gói không khớp Node trong image (22.x). Cài bản cũ hơn của gói, hoặc tắt \
                kiểm tra engines nếu bạn biết nó vẫn chạy được.
                """,
                repairs: [
                    Repair(title: "Tắt kiểm tra engines", detail: "dùng khi gói vẫn chạy được trên Node 22", action: .run("npm config set engine-strict false && \(command)")),
                    Repair(title: "Xem gói cần gì", detail: "engines + phiên bản đang có", action: .run("npm view \(bare) engines --json; node -v"))
                ],
                probes: [],
                errorLine: line)
        case "EJSONPARSE":
            return ErrorCase(
                headline: "package.json bị sai cú pháp",
                cause: """
                Thiếu dấu phẩy/ngoặc, hoặc có BOM/ký tự lạ do sửa trên Windows. npm không đọc được nên \
                dừng trước khi cài.
                """,
                repairs: [
                    Repair(title: "Kiểm tra và sửa", detail: "npm pkg fix tự chuẩn hoá file", action: .run("npm pkg fix && \(command)")),
                    Repair(title: "Xem chỗ lỗi", detail: "in 20 dòng quanh lỗi parse", action: .run("node -e \"try{JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))}catch(e){console.log(e.message)}\" package.json"))
                ],
                probes: [
                    Repair(title: "Có BOM không?", detail: "3 byte đầu của file", action: .run("head -c3 package.json | xxd"), readOnly: true)
                ],
                errorLine: line)
        case "ENOENT":
            return ErrorCase(
                headline: "Không thấy package.json",
                cause: """
                Bạn đang đứng ngoài thư mục dự án (hay gặp khi mở Shell ở `~/projects`). `npm install` chỉ \
                chạy trong thư mục có `package.json`.
                """,
                repairs: [
                    Repair(title: "Xem đang ở đâu", detail: "pwd + liệt kê", action: .run("pwd; ls -la")),
                    Repair(title: "Tạo package.json", detail: "nếu đây là dự án mới", action: .run("npm init -y && \(command)"))
                ],
                probes: [
                    Repair(title: "Dự án trong ~/projects", detail: "liệt kê để cd đúng", action: .run("ls -d ~/projects/*/ 2>/dev/null | head -20"), readOnly: true)
                ],
                errorLine: line)
        case "ELIFECYCLE":
            return ErrorCase(
                headline: "Script của dự án chạy và thoát lỗi",
                cause: """
                `npm run <script>` gọi script trong `package.json`; script đó lỗi nên npm in ELIFECYCLE. \
                Lỗi thật nằm ở các dòng phía trên, không phải ở npm.
                """,
                repairs: [
                    Repair(title: "Xem các script có", detail: "npm run in danh sách script", action: .run("npm run")),
                    Repair(title: "Sao chép 20 dòng cuối", detail: "để xem lỗi thật của script", action: .copyTail)
                ],
                probes: [
                    Repair(title: "Script trong package.json", detail: "in phần scripts", action: .run("node -e \"console.log(JSON.stringify(require('./package.json').scripts,null,2))\""), readOnly: true)
                ],
                errorLine: line)
        default:
            return ErrorCase(
                headline: "npm báo lỗi \(code)",
                cause: """
                Mã này chưa có trong bảng của app. Các bước dưới đây kiểm tra những nguyên nhân chung \
                (đĩa, mạng, prefix, phiên bản node) trước khi đoán tiếp.
                """,
                repairs: [
                    Repair(title: "Kiểm tra nhanh", detail: "đĩa, RAM, DNS, node/npm, prefix", action: .healthCheck),
                    Repair(title: "Xoá cache + node_modules", detail: "cách sửa chung cho lỗi npm lạ", action: .run("npm cache clean --force; rm -rf node_modules package-lock.json; \(command)")),
                    Repair(title: "Sao chép 20 dòng cuối", detail: "gửi mình mã lỗi để bổ sung vào app", action: .copyTail)
                ],
                probes: [
                    Repair(title: "Phiên bản + prefix", detail: "node, npm, prefix, registry", action: .run("node -v; npm -v; npm config get prefix; npm config get registry"), readOnly: true)
                ],
                errorLine: line)
        }
    }

    // MARK: - Trích xuất

    /// Dòng lỗi đáng chú ý nhất trong cửa sổ output.
    static func errorLine(_ lines: [String]) -> String {
        let keys = ["error", "err!", "traceback", "fatal", "no such file", "permission denied",
                    "not found", "killed", "e404", "eacces", "enospc"]
        let ranked = lines.filter { raw in
            let text = raw.lowercased()
            return keys.contains { text.contains($0) }
        }
        return (ranked.last ?? lines.last ?? "").trimmingCharacters(in: .whitespaces)
    }

    static func npmCode(_ lines: [String]) -> String? {
        for raw in lines.reversed() {
            let lower = raw.lowercased()
            guard let range = lower.range(of: "npm error code ")
                    ?? lower.range(of: "npm err! code ") else { continue }
            let tail = lower[range.upperBound...]
            let code = String(tail.prefix { !$0.isWhitespace })
            if !code.isEmpty { return code.uppercased() }
        }
        return nil
    }

    /// Tên gói trong URL registry của npm (E404/ETARGET in ra).
    static func npmPackage(_ lines: [String]) -> String? {
        for raw in lines.reversed() {
            guard let range = raw.range(of: "registry.npmjs.org/") else { continue }
            let tail = raw[range.upperBound...]
            let name = String(tail.prefix { $0 != " " && $0 != "/" && $0 != "?" })
            let decoded = name.removingPercentEncoding ?? name
            if !decoded.isEmpty { return decoded }
        }
        return nil
    }

    /// Gói đứng sau `npm i/install/add` (bỏ qua cờ như `-g`, `--save-dev`).
    static func installSpec(_ command: String) -> String? {
        let parts = command.split(separator: " ").map(String.init)
        guard let start = parts.firstIndex(where: {
            $0 == "npm" || $0 == "yarn" || $0 == "pnpm" || $0.hasSuffix("/npm")
        }) else { return nil }
        let verbs: Set<String> = ["i", "install", "isntall", "add", "in"]
        var seenVerb = false
        for token in parts[(start + 1)...] {
            if verbs.contains(token) {
                seenVerb = true
                continue
            }
            guard seenVerb else { continue }
            if token.hasPrefix("-") { continue }
            if token.hasPrefix(".") || token.hasPrefix("/") || token.hasPrefix("~")
                || token.contains("://") || token.hasPrefix("file:") || token.hasPrefix("git+")
                || token.hasPrefix("github:") {
                return token.hasPrefix("github:") ? token : nil
            }
            return token
        }
        return nil
    }

    /// `owner/repo` (hoặc `github:owner/repo`) — dạng npm hay hiểu nhầm thành
    /// tên gói. Trả nil cho tên gói scoped (`@scope/name`) và đường dẫn.
    static func githubRepo(_ spec: String) -> String? {
        var text = spec
        if text.hasPrefix("github:") { text = String(text.dropFirst(7)) }
        if let at = text.lastIndex(of: "@"), at != text.startIndex {
            text = String(text[text.startIndex..<at])
        }
        guard !text.hasPrefix("@"), !text.contains(":"), !text.contains("//") else { return nil }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return text
    }

    static func missingToken(_ lines: [String]) -> String? {
        for line in lines.reversed() {
            if let open = line.range(of: "can't open file '"),
               let close = line[open.upperBound...].firstIndex(of: "'") {
                return String(line[open.upperBound..<close])
            }
            for suffix in [": No such file or directory", ": not found"] {
                guard let range = line.range(of: suffix) else { continue }
                let head = line[..<range.lowerBound]
                if let colon = head.lastIndex(of: ":") {
                    let tail = head[head.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if !tail.isEmpty { return tail }
                }
            }
        }
        return nil
    }

    private static func lastToken(_ command: String) -> String {
        command.split(separator: " ").last.map(String.init) ?? command
    }

    private static func lastComponent(_ command: String) -> String {
        (lastToken(command) as NSString).lastPathComponent
    }

    private static func aptName(_ command: String) -> String {
        let parts = command.split(separator: " ").map(String.init)
        if let index = parts.firstIndex(of: "install"), index + 1 < parts.count {
            return parts[(index + 1)...].first { !$0.hasPrefix("-") } ?? ""
        }
        return lastToken(command)
    }

    /// Gói trong `pip install …` (bỏ cờ và `-r requirements.txt`).
    private static func pipPackages(_ command: String) -> String {
        let parts = command.split(separator: " ").map(String.init)
        guard let index = parts.firstIndex(of: "install"), index + 1 < parts.count else {
            return lastToken(command)
        }
        let tail = parts[(index + 1)...].filter { !$0.hasPrefix("-") && $0 != "requirements.txt" }
        return tail.isEmpty ? lastToken(command) : tail.joined(separator: " ")
    }

    /// Tên module Python → tên gói trên PyPI.
    static func pipAlias(_ module: String) -> String {
        let name = module.split(separator: ".").first.map(String.init) ?? module
        let map: [String: String] = [
            "cv2": "opencv-python", "PIL": "pillow", "yaml": "pyyaml", "sklearn": "scikit-learn",
            "bs4": "beautifulsoup4", "dotenv": "python-dotenv", "Crypto": "pycryptodome",
            "OpenSSL": "pyopenssl", "jwt": "pyjwt", "serial": "pyserial", "MySQLdb": "mysqlclient",
            "psycopg2": "psycopg2-binary", "magic": "python-magic", "dateutil": "python-dateutil",
            "pkg_resources": "setuptools", "fitz": "pymupdf", "docx": "python-docx",
            "pptx": "python-pptx", "telegram": "python-telegram-bot", "discord": "discord.py",
            "win32com": "pywin32", "gi": "pygobject", "wx": "wxpython", "torch": "torch",
            "google": "google-api-python-client", "pandas": "pandas", "numpy": "numpy"
        ]
        return map[name] ?? name.lowercased()
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let group = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[group])
    }
}
