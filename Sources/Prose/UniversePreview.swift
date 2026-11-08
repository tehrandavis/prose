import AppKit
import ImageIO
import ProseCore
import SwiftUI

/// Official, versioned thumbnails are a visual aid only. A missing preview never
/// blocks catalog browsing or template creation, and loading stays off the UI thread.
struct UniversePreview: View {
    let package: UniversePackage
    let cacheURL: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(hex: 0xE5E3DD)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(9)
            } else {
                VStack(spacing: 10) {
                    Text(package.name.split(separator: "-").prefix(2).map { String($0.prefix(1)).uppercased() }
                        .joined())
                        .font(.system(size: 42, weight: .light, design: .serif)).foregroundStyle(Color(hex: 0x73736F))
                    Text(L10n.text("Preview unavailable")).font(.system(size: 9)).foregroundStyle(Color(hex: 0x83837D))
                }.padding(14)
            }
        }.accessibilityHidden(true)
            .task(id: package.thumbnailURL) {
                image = nil
                guard let url = package.thumbnailURL else {
                    return
                }
                if let cached = UniversePreviewImages.cache.object(forKey: url as NSURL) {
                    image = cached
                    return
                }
                guard let data = await UniversePreviewLoader.shared.data(for: url, cacheURL: cacheURL),
                      !Task.isCancelled
                else {
                    return
                }
                let thumbnail = await Task.detached(priority: .utility) { () -> CGImage? in
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                        return nil
                    }
                    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                    kCGImageSourceThumbnailMaxPixelSize: 600,
                                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                                    kCGImageSourceShouldCacheImmediately: true]
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                }.value
                guard let thumbnail, !Task.isCancelled else {
                    return
                }
                let result = NSImage(cgImage: thumbnail, size: .zero)
                UniversePreviewImages.cache.setObject(
                    result,
                    forKey: url as NSURL,
                    cost: thumbnail.bytesPerRow * thumbnail.height,
                )
                image = result
            }
    }
}

@MainActor
private enum UniversePreviewImages {
    static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 60
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
}
