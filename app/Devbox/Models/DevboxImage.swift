import Foundation

enum DevboxConfig {
    static let imageRelease = "https://github.com/Mobimi/winlator-ios/releases/download/img-v1"
    static let manifestURL = URL(string: imageRelease + "/manifest.json")!
    static let slug = "debian13-arm64"
    static let consolePort: UInt16 = 4444
    static let qmpPort: UInt16 = 4445

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var root: URL {
        documents.appendingPathComponent("Devbox", isDirectory: true)
    }

    static var logsDirectory: URL {
        documents.appendingPathComponent("logs", isDirectory: true)
    }

    static var qemuLogURL: URL {
        logsDirectory.appendingPathComponent("qemu.log")
    }

    static var diagnosticsURL: URL {
        logsDirectory.appendingPathComponent("diagnostics.txt")
    }

    static var imagesRoot: URL { root.appendingPathComponent("images", isDirectory: true) }
    static var imageDirectory: URL { imagesRoot.appendingPathComponent(slug, isDirectory: true) }
    static var shareDirectory: URL { root.appendingPathComponent("share", isDirectory: true) }
}

struct ImageManifest: Codable {
    struct Packages: Codable {
        var python: String
        var pip: String
        var node: String
        var npm: String
    }

    struct FileRef: Codable {
        var file: String
        var sha256: String
        var size: Int?
    }

    var name: String
    var version: Int
    var suite: String
    var arch: String
    var kernelVersion: String
    var packages: Packages
    var image: FileRef
    var kernel: FileRef
    var initrd: FileRef

    func url(for file: FileRef) -> URL {
        URL(string: DevboxConfig.imageRelease + "/" + file.file)!
    }
}

extension ImageManifest.FileRef {
    var remoteURL: URL {
        URL(string: DevboxConfig.imageRelease + "/" + file)!
    }
}

struct InstalledImage {
    var directory: URL
    var manifest: ImageManifest

    var rootfs: URL { directory.appendingPathComponent("rootfs.ext4") }
    var kernel: URL { directory.appendingPathComponent("vmlinuz") }
    var initrd: URL { directory.appendingPathComponent("initrd.img") }
    var manifestFile: URL { directory.appendingPathComponent("manifest.json") }

    var isComplete: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: rootfs.path)
            && fm.fileExists(atPath: kernel.path)
            && fm.fileExists(atPath: initrd.path)
    }

    static func load() -> InstalledImage? {
        let dir = DevboxConfig.imageDirectory
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(ImageManifest.self, from: data) else {
            return nil
        }
        let image = InstalledImage(directory: dir, manifest: manifest)
        return image.isComplete ? image : nil
    }
}
