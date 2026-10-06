import SwiftUI
import UIKit

// MARK: - 图片附件仓库
//
// 照片存到沙盒 Documents/attachments/ 下，任务里只记文件名。
// 这样任务 JSON 很小，照片可以随时读取、删除，也不会丢。

enum AttachmentStore {

    static let folderName = "attachments"

    static var dir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    static func url(_ name: String) -> URL {
        dir.appendingPathComponent(name)
    }

    // MARK: 写入

    /// 保存一张图片，返回文件名。会先按最长边压缩，避免占空间
    @discardableResult
    static func save(_ image: UIImage, maxSide: CGFloat = 1600, quality: CGFloat = 0.82) -> String? {
        let scaled = resize(image, maxSide: maxSide)
        guard let data = scaled.jpegData(compressionQuality: quality) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do {
            try data.write(to: url(name), options: .atomic)
            cache.setObject(scaled, forKey: name as NSString)
            return name
        } catch {
            return nil
        }
    }

    // MARK: 读取

    private static let cache = NSCache<NSString, UIImage>()

    static func load(_ name: String) -> UIImage? {
        if let hit = cache.object(forKey: name as NSString) { return hit }
        guard let data = try? Data(contentsOf: url(name)),
              let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: name as NSString)
        return img
    }

    static func loadAll(_ names: [String]) -> [UIImage] {
        names.compactMap { load($0) }
    }

    // MARK: 删除

    static func delete(_ names: [String]) {
        for n in names {
            cache.removeObject(forKey: n as NSString)
            try? FileManager.default.removeItem(at: url(n))
        }
    }

    /// 清掉没有被任何任务引用的图片，返回清理数量
    @discardableResult
    static func vacuum(keeping used: Set<String>) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var n = 0
        for f in files where !used.contains(f) && !f.hasPrefix(".") {
            cache.removeObject(forKey: f as NSString)
            try? FileManager.default.removeItem(at: url(f))
            n += 1
        }
        return n
    }

    // MARK: 统计

    static var fileCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count ?? 0
    }

    static var totalBytes: Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var total: Int64 = 0
        for f in files {
            if let a = try? FileManager.default.attributesOfItem(atPath: url(f).path),
               let n = a[.size] as? NSNumber {
                total += n.int64Value
            }
        }
        return total
    }

    static var sizeText: String {
        let bytes = totalBytes
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024.0)
    }

    // MARK: 内部

    private static func resize(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let w = image.size.width
        let h = image.size.height
        let m = max(w, h)
        guard m > maxSide, m > 0 else { return image }
        let scale = maxSide / m
        let target = CGSize(width: max(1, w * scale), height: max(1, h * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

// MARK: - 编辑时用的照片槽位

/// 新建 / 编辑任务时，页面上的一张照片
struct PhotoSlot: Identifiable, Equatable {
    let id: String
    var image: UIImage
    /// 非 nil 表示已经落盘（编辑老任务时读出来的）
    var fileName: String?

    init(image: UIImage, fileName: String? = nil) {
        self.id = fileName ?? UUID().uuidString
        self.image = image
        self.fileName = fileName
    }

    static func == (a: PhotoSlot, b: PhotoSlot) -> Bool { a.id == b.id }
}

// MARK: - 通用缩略图条

/// 任务列表 / 日历 / 催促页共用的缩略图条
struct PhotoStrip: View {
    let names: [String]
    var size: CGFloat = 40
    var maxCount: Int = 4
    var radius: CGFloat = 7

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(names.prefix(maxCount).enumerated()), id: \.offset) { _, n in
                if let img = AttachmentStore.load(n) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: radius))
                        .overlay(
                            RoundedRectangle(cornerRadius: radius)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                        )
                }
            }
            if names.count > maxCount {
                Text("+\(names.count - maxCount)")
                    .font(.system(size: max(size * 0.26, 10), weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: size, height: size)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: radius))
            }
        }
    }
}

// MARK: - 全屏看图

struct PhotoViewer: View {
    let images: [UIImage]
    let titles: [String]
    @State private var index: Int
    @Environment(\.presentationMode) private var presentationMode

    init(images: [UIImage], titles: [String] = [], start: Int = 0) {
        self.images = images
        self.titles = titles
        self._index = State(initialValue: max(0, min(start, images.count - 1)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if images.isEmpty {
                Text("图片读不出来了")
                    .foregroundColor(.white.opacity(0.8))
            } else {
                TabView(selection: $index) {
                    ForEach(images.indices, id: \.self) { i in
                        VStack(spacing: 12) {
                            Image(uiImage: images[i])
                                .resizable()
                                .scaledToFit()
                                .padding(.horizontal, 8)

                            if i < titles.count, !titles[i].isEmpty {
                                Text(titles[i])
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.75))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 20)
                            }
                        }
                        .tag(i)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: images.count > 1 ? .automatic : .never))
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                Spacer()
            }
        }
    }
}
