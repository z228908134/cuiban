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
        // 需要缩放，或方向不是正（相机拍的照片带旋转标记）时，都用渲染器重画一遍：
        // draw(in:) 会按 imageOrientation 把像素「摆正」，落盘的 JPEG 就是正确的方向
        let needsNormalize = image.imageOrientation != .up
        guard (m > maxSide || needsNormalize), m > 0 else { return image }
        let scale = m > maxSide ? maxSide / m : 1
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
                    .font(.app(max(size * 0.26, 10), weight: .semibold))
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
    /// 下拉关闭：跟手的位移与背景变暗程度
    @State private var dragY: CGFloat = 0
    @State private var dismissing = false

    init(images: [UIImage], titles: [String] = [], start: Int = 0) {
        self.images = images
        self.titles = titles
        self._index = State(initialValue: max(0, min(start, images.count - 1)))
    }

    private var close: () -> Void { presentationMode.wrappedValue.dismiss() }

    var body: some View {
        ZStack {
            // 背景：下拉时露出下面的内容，越往下越透明
            Color.black.opacity(1 - min(Double(dragY) / 900.0, 0.75))
                .ignoresSafeArea()

            if images.isEmpty {
                Text("图片读不出来了")
                    .foregroundColor(.white.opacity(0.8))
            } else {
                VStack(spacing: 10) {
                    // 顶部提示条：第几张 / 怎么关闭
                    HStack(spacing: 5) {
                        if images.count > 1 {
                            Text("\(index + 1) / \(images.count)")
                                .font(.app(13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        Text("· 下滑关闭")
                            .font(.app(12))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
                    .padding(.top, 6)

                    TabView(selection: $index) {
                        ForEach(images.indices, id: \.self) { i in
                            Image(uiImage: images[i])
                                .resizable()
                                .scaledToFit()
                                .padding(.horizontal, 8)
                                .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    if index < titles.count, !titles[index].isEmpty {
                        Text(titles[index])
                            .font(.app(13))
                            .foregroundColor(.white.opacity(0.78))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    Spacer(minLength: 12)
                }
                // 只有图片区域响应下拉，TabView 仍能正常左右翻页
                .offset(y: dragY)
                .scaleEffect(1 - min(dragY / 4000.0, 0.06), anchor: .center)
            }

            // 右上角关闭按钮：实心深色圆 + 白色描边 + 阴影，压在任何图片上都看得清
            VStack {
                HStack {
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.app(17, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.black.opacity(0.72)))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 2))
                            .shadow(color: .black.opacity(0.5), radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
            // 关闭按钮不参与下拉手势，点哪儿都能关
            .allowsHitTesting(true)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(dismissGesture)
        .statusBarHidden(true)
    }

    /// 下滑关闭：跟手位移，松手按距离/速度决定是否关
    private var dismissGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                guard !dismissing else { return }
                // 只认向下；如果图片只有一张，往上也能拉（露出下方内容）
                dragY = max(0, v.translation.height)
            }
            .onEnded { v in
                guard !dismissing else { return }
                // 位移够大或下滑够快就关
                if v.translation.height > 110
                    || (v.translation.height > 24
                        && v.predictedEndTranslation.height > 260) {
                    dismissing = true
                    withAnimation(.easeOut(duration: 0.18)) { dragY = 900 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { close() }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragY = 0
                    }
                }
            }
    }
}
