import SwiftUI
import UniformTypeIdentifiers

// MARK: - 系统文件导出面板
//
// 免签名 App 拿不到 iCloud 容器权限，但把文件交给系统「文件」面板导出是通的：
// 用户在面板里选「iCloud 云盘」下的任意目录，文件就真的存进 iCloud，
// 换设备也能从「文件」App 里拿到。

/// 把文件复制到用户选的位置（文件 App / iCloud 云盘）
struct ExportFilesSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onFinish()
        }
    }
}

/// 从「文件 App」（含 iCloud 云盘、本机目录）选一个备份文件
struct ImportFileSheet: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .data], asCopy: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
    }
}

/// 选一个「文件夹」（用于指定同步位置：飞牛 WebDAV / iCloud 云盘 / 本机目录都行）。
/// asCopy: false 拿到的是安全作用域 URL，读写前需要 startAccessingSecurityScopedResource。
struct FolderPickerSheet: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.folder],
                                                asCopy: false)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        vc.directoryURL = docs
        vc.allowsMultipleSelection = false
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let u = urls.first else { return }
            // 持续持有安全作用域访问权，否则 App 一退出就再也读不到这个目录
            let ok = u.startAccessingSecurityScopedResource()
            if ok {
                CloudSyncBookmark.shared.keep(u)
            }
            onPick(u)
        }
    }
}

/// 保存用户选中的同步文件夹的安全作用域书签，
/// 这样 App 下次启动还能访问同一个目录（iOS 的沙盒机制要求）。
final class CloudSyncBookmark {
    static let shared = CloudSyncBookmark()
    private(set) var url: URL?

    private init() { load() }

    private var defaultsKey: String { "cloudsync.bookmark" }

    func keep(_ u: URL) {
        url = u
        do {
            let d = try u.bookmarkData(options: .withSecurityScope,
                                       includingResourceValuesForKeys: nil,
                                       relativeTo: nil)
            UserDefaults.standard.set(d, forKey: defaultsKey)
        } catch {
            print("存书签失败：\(error.localizedDescription)")
        }
    }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        var stale = false
        if let u = try? URL(resolvingBookmarkData: d,
                           options: .withSecurityScope,
                           relativeTo: nil,
                           bookmarkDataIsStale: &stale) {
            if u.startAccessingSecurityScopedResource() { url = u }
            if stale { keep(u) }
        }
    }
}
