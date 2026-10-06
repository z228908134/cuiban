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
