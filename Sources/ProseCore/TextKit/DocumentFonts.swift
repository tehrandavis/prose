import AppKit
import CoreText
import Foundation

/// The document's own fonts as `NSFont`s (Phase 6 decision 6). The engine
/// reports a block's font by identifier (`BlockTextFont.id`); this cache gets
/// the face's bytes from the renderer once and makes fonts of any size from
/// them.
///
/// Fonts are made from the bytes with `CTFontManagerCreateFontDescriptorsFromData`
/// and `CTFontCreateWithFontDescriptor`. Nothing is registered with the font
/// manager or installed: a face made this way exists only in this process,
/// only through the fonts this cache returns, and cannot be found by name.
/// That is needed because Typst's embedded fonts (Libertinus Serif, New
/// Computer Modern) are not on the Mac, and because a document font with a
/// system font's name may differ from the installed one. For the same reason
/// faces are keyed by the engine (`BlockRenderer.engineID`) and the engine's
/// identifier, never by name.
///
/// Getting a font is asynchronous the first time, because the bytes come
/// from the renderer's actor:
///
/// - `font(_:size:in:strong:emphasis:)` answers at once from the cache, and
///   returns nil while the face has not been loaded. The caller draws in the
///   editor's font meanwhile.
/// - `load(_:in:strong:emphasis:)` gets the face (and for `strong` or
///   `emphasis` the face Typst chooses for them, `BlockRenderer.fontFace`)
///   and returns whether it can be drawn. Afterwards `font` answers for every
///   size. Concurrent loads of one face share one request.
///
/// Each face is made from its bytes once; each size of it is made once from
/// that face and kept. Fonts of an engine stay until `forget(_:)`.
@MainActor
public final class DocumentFonts {
    private struct FaceKey: Hashable {
        let engine: UUID
        let font: Int
    }

    private struct VariantKey: Hashable {
        let face: FaceKey
        let strong: Bool
        let emphasis: Bool
    }

    private struct SizeKey: Hashable {
        let face: FaceKey
        let size: CGFloat
    }

    /// Faces made from bytes, at the size they were made at. Nil for a face
    /// whose bytes could not be read or parsed, so it is not asked for again.
    private var faces: [FaceKey: CTFont?] = [:]
    private var sized: [SizeKey: NSFont] = [:]
    /// The face for strong and emphasis text, by the base face.
    private var variants: [VariantKey: Int] = [:]
    private var loading: [FaceKey: Task<Void, Never>] = [:]
    /// How many faces were made from bytes, for tests.
    private(set) var facesMade = 0

    public init() {}

    /// The document font `font` of `renderer`'s engine at `size` points, or
    /// its face for strong or emphasis text; nil until `load` has made it.
    public func font(
        _ font: Int,
        size: CGFloat,
        in renderer: BlockRenderer,
        strong: Bool = false,
        emphasis: Bool = false,
    ) -> NSFont? {
        let base = FaceKey(engine: renderer.engineID, font: font)
        let face: FaceKey
        if strong || emphasis {
            guard let variant = variants[VariantKey(face: base, strong: strong, emphasis: emphasis)] else {
                return nil
            }
            face = FaceKey(engine: base.engine, font: variant)
        } else {
            face = base
        }
        guard size > 0, size.isFinite, case let .some(.some(made)) = faces[face] else {
            return nil
        }
        let key = SizeKey(face: face, size: size)
        if let font = sized[key] {
            return font
        }
        let font = CTFontCreateCopyWithAttributes(made, size, nil, nil) as NSFont
        sized[key] = font
        return font
    }

    /// Makes the document font `font` of `renderer`'s engine, and for
    /// `strong` or `emphasis` the face Typst chooses for that text, ready for
    /// `font(_:size:in:strong:emphasis:)`. Returns whether that face can be
    /// drawn. Cheap once loaded.
    @discardableResult
    public func load(
        _ font: Int,
        in renderer: BlockRenderer,
        strong: Bool = false,
        emphasis: Bool = false,
    ) async -> Bool {
        let base = FaceKey(engine: renderer.engineID, font: font)
        var face = base
        if strong || emphasis {
            let key = VariantKey(face: base, strong: strong, emphasis: emphasis)
            if let variant = variants[key] {
                face = FaceKey(engine: base.engine, font: variant)
            } else {
                guard let variant = await renderer.fontFace(font, strong: strong, emphasis: emphasis) else {
                    return false
                }
                variants[key] = variant
                face = FaceKey(engine: base.engine, font: variant)
            }
        }
        await make(face, renderer)
        return faces[face].map { $0 != nil } ?? false
    }

    /// Drops every font of `renderer`'s engine.
    public func forget(_ renderer: BlockRenderer) {
        let engine = renderer.engineID
        faces = faces.filter { $0.key.engine != engine }
        sized = sized.filter { $0.key.face.engine != engine }
        variants = variants.filter { $0.key.face.engine != engine }
        for (key, task) in loading where key.engine == engine {
            task.cancel()
        }
        loading = loading.filter { $0.key.engine != engine }
    }

    /// Makes `face` from the engine's bytes, once.
    private func make(_ face: FaceKey, _ renderer: BlockRenderer) async {
        if faces[face] != nil {
            return
        }
        if let running = loading[face] {
            await running.value
            return
        }
        let task = Task { @MainActor [weak self] in
            let data = await renderer.fontData(face.font)
            guard let self, !Task.isCancelled else {
                return
            }
            let made = data.flatMap(Self.face)
            // Kept even when nil, so a face that cannot be made is not asked for again.
            faces.updateValue(made, forKey: face)
            if made != nil {
                facesMade += 1
            }
            loading[face] = nil
        }
        loading[face] = task
        await task.value
    }

    /// The face at `faceIndex` of the font file's bytes, at 12 points.
    private static func face(_ data: BlockFontData) -> CTFont? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data.data as CFData)
            as? [CTFontDescriptor], descriptors.indices.contains(data.faceIndex)
        else {
            return nil
        }
        return CTFontCreateWithFontDescriptor(descriptors[data.faceIndex], 12, nil)
    }
}
