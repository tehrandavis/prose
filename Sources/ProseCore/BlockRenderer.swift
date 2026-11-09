internal import ProseRenderFFI
import CoreGraphics
import Foundation

/// Why the renderer could not start or a call failed, with the engine's message
/// (for a render, the first Typst diagnostic).
public struct BlockRendererError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

/// What the last full compile found. `headings`, `equations` and `references`
/// describe the context renders use: after a failed compile, the previous good one.
public struct RenderRefresh: Equatable, Sendable {
    public let succeeded: Bool
    public let errors: Int
    public let warnings: Int
    /// Pages of the full document; 0 when the compile failed.
    public let pages: Int
    public let headings: Int
    public let equations: Int
    public let references: Int
    /// The first error's message when the compile failed.
    public let message: String?
}

/// One top-level block of a file: a UTF-16 range (`NSRange`) and its kind. The
/// blocks of a file are in order, do not overlap, and cover every character
/// that is not whitespace between them; a block ends at its last character
/// that is not whitespace.
public struct RenderBlock: Equatable, Sendable {
    public enum Kind: Sendable {
        case heading
        /// A display equation (`$ x $`).
        case equation
        case paragraph
        /// A `#set`, `#show`, `#let` or `#import` line, with a comment on the
        /// same line. Its text is the context of every later block. Drawn as a
        /// pill, not rendered.
        case context
        /// An `#include` line. Drawn as a pill, not rendered.
        case include
        /// A single fenced raw block. It renders, though Writing mode shows it
        /// as source.
        case raw
        /// Only bullet, numbered and term list items.
        case list
        /// Only comments. Drawn as a muted pill, not rendered.
        case comment

        /// Whether blocks of this kind are drawn from a render. Context,
        /// include and comment blocks are pills.
        public var renders: Bool {
            switch self {
            case .context, .include, .comment: false
            case .heading, .equation, .paragraph, .raw, .list: true
            }
        }
    }

    public let range: NSRange
    public let kind: Kind
}

/// How to render a block.
public struct RenderOptions: Equatable, Sendable {
    /// Dark appearance: the block renders with the document's own colours,
    /// and the engine maps every paint (not images) onto the dark page, black
    /// ink to `#E8E4DE` and white to `#262626`. Part of the cache key.
    public var dark: Bool
    /// Pixels per point for `RenderedBlock.bitmap`; 0 means no bitmap. At most
    /// `maximumBitmapScale`. Bitmaps are made from the cached vector result on
    /// every call that asks for one; the engine does not cache them.
    public var bitmapScale: Double

    public static let maximumBitmapScale = PR_MAX_BITMAP_SCALE

    public init(dark: Bool = false, bitmapScale: Double = 0) {
        self.dark = dark
        self.bitmapScale = bitmapScale
    }
}

/// One glyph's box, in points from the block's top-left corner, y pointing down.
public struct RenderedGlyph: Equatable, Sendable {
    public let rect: CGRect
    /// UTF-16 offset in the file of the character the glyph starts at; nil for
    /// generated text such as numbers and reference text.
    public let source: Int?
}

/// A typeset block. Geometry is in points from the block's top-left corner.
public struct RenderedBlock: Equatable, Sendable {
    /// SVG of `drawnRect`, UTF-8. Transparent outside ink.
    public let svg: Data
    /// The block's page: the measure wide, as tall as its content plus a small margin.
    public let size: CGSize
    /// The first line's baseline, from the top.
    public let baseline: Double
    /// The bounds of everything drawn.
    public let ink: CGRect
    /// What `svg` and `bitmap` cover: the page and the ink, which can pass the
    /// page's edges where punctuation hangs. Its origin is zero or negative.
    /// Draw the image into this rectangle and the glyphs line up with it.
    public let drawnRect: CGRect
    public let glyphs: [RenderedGlyph]
    /// `drawnRect` at the options' bitmap scale (pixel size rounded up; the part
    /// of a pixel past the rectangle is transparent), premultiplied RGBA in
    /// sRGB. Nil when no bitmap was asked for or it would be larger than 32 Mi
    /// pixels. Immutable, so safe to share across threads.
    public let bitmap: CGImage?
    /// Whether the vector result came from the engine's cache.
    public let cached: Bool
    /// The plain text of the block's text runs, separated by spaces: what it
    /// shows, numbers and citations included. For tests and measurement.
    public let text: String
}

/// The engine's result cache, for tests and tuning. Sizes are in bytes.
public struct RenderCacheStats: Equatable, Sendable {
    public let entries: Int
    public let bytes: Int
    public let budget: Int
    public let hits: Int
    public let misses: Int
}

/// The renderer's C function table and one engine from it, freed with this
/// object. The engine locks internally, so calls from any thread are safe.
private final class RenderEngine: @unchecked Sendable {
    let api: UnsafePointer<PRRenderAPI>
    let pointer: OpaquePointer

    init(api: UnsafePointer<PRRenderAPI>, pointer: OpaquePointer) {
        self.api = api
        self.pointer = pointer
    }

    deinit {
        api.pointee.engine_free(pointer)
    }
}

/// Renders single blocks of a Typst project with the context of its last full
/// compile (`Engine/RenderBridge`). All Typst work runs off the main thread, one
/// call at a time. Offsets are UTF-16, as `NSString` uses.
public actor BlockRenderer {
    private let engine: RenderEngine

    /// Scans fonts (Typst's embedded fonts, the system fonts, then
    /// `fontDirectories`) and opens the project. `main` must exist inside `root`.
    /// Package directories are read only; nothing is downloaded. Missing
    /// directories are skipped.
    public init(
        root: URL,
        main: URL,
        packageDirectories: [URL] = [],
        fontDirectories: [URL] = [],
        cacheBudget: Int = 64 << 20,
    ) async throws {
        let api = prose_render_api()
        guard Self.isCompatible(api.pointee) else {
            throw BlockRendererError("The render engine does not match this build of Prose.")
        }
        guard FileManager.default.fileExists(atPath: main.path) else {
            throw BlockRendererError("The main file \(main.lastPathComponent) does not exist.")
        }
        var error: UnsafeMutablePointer<CChar>?
        let pointer = withCStrings(packageDirectories.map(\.path)) { packages, packageCount in
            withCStrings(fontDirectories.map(\.path)) { fonts, fontCount in
                api.pointee.engine_create(
                    root.path,
                    main.path,
                    packages,
                    packageCount,
                    fonts,
                    fontCount,
                    UInt64(max(0, cacheBudget)),
                    &error,
                )
            }
        }
        guard let pointer else {
            let message = error.map { String(cString: $0) } ?? "The render engine could not start."
            api.pointee.string_free(error)
            throw BlockRendererError(message)
        }
        engine = RenderEngine(api: api, pointer: pointer)
    }

    /// Whether a function table has the ABI version and struct layouts this file
    /// was compiled against.
    static func isCompatible(_ api: PRRenderAPI) -> Bool {
        api.abi_version == PR_RENDER_ABI_VERSION
            && Int(api.block_size) == MemoryLayout<PRBlock>.size
            && Int(api.glyph_size) == MemoryLayout<PRGlyphBox>.size
            && Int(api.result_size) == MemoryLayout<PRRenderResult>.size
            && Int(api.refresh_size) == MemoryLayout<PRRefreshInfo>.size
            && Int(api.stats_size) == MemoryLayout<PRCacheStats>.size
            && Int(api.options_size) == MemoryLayout<PRRenderOptions>.size
    }

    /// The app's bundled packages, the editor's package cache when given (the
    /// one Tinymist downloads into), and the user's Typst package cache.
    public static func defaultPackageDirectories(packageCache: URL? = nil) -> [URL] {
        var bundled = Bundle.main.resourceURL?.appendingPathComponent("Packages")
        #if DEBUG
            if bundled.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
                // SwiftPM builds and tests run outside the app bundle.
                bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("Resources/Packages")
            }
        #endif
        let user = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).map {
            $0.appendingPathComponent("typst/packages")
        }
        return [bundled, packageCache].compactMap(\.self) + user
    }

    /// Replaces a file's text in memory with the editor's buffer. The file need
    /// not exist on disk. Cheap.
    public func setText(_ text: String, of file: URL) throws {
        var text = text
        let applied = text.withUTF8 {
            engine.api.pointee.set_text(engine.pointer, file.path, $0.baseAddress, $0.count)
        }
        guard applied else {
            throw lastError(or: "The text could not be set.")
        }
    }

    /// Files changed on disk (bibliographies, data, images, Typst files the
    /// editor did not give it). The engine reads every file from disk again on
    /// its next use, and renders that read a changed file compile again; text
    /// set with `setText` stays. Files outside the project are ignored. Cheap:
    /// nothing is read or compiled here. Returns how many of the files the
    /// document read (the main file, the last full compile, any render): when
    /// none, nothing shown can have changed and no refresh is needed.
    @discardableResult
    public func filesChanged(_ urls: [URL]) -> Int {
        withCStrings(urls.map(\.path)) { paths, count in
            engine.api.pointee.files_changed(engine.pointer, paths, count)
        }
    }

    /// The bibliography files the document's `bibliography(...)` calls name,
    /// relative to the project root, in the order found: the main file, then
    /// each file it includes, depth first, from their current texts. Only
    /// string literals count (`bibliography("a.bib")`,
    /// `bibliography(("a.bib", "b.yml"))`), each path relative to the file
    /// holding the call. Nothing is compiled.
    public func bibliographyFiles() -> [String] {
        guard let raw = engine.api.pointee.bibliography_files(engine.pointer) else {
            return []
        }
        defer { engine.api.pointee.string_free(raw) }
        let json = Data(bytes: raw, count: strlen(raw))
        return (try? JSONDecoder().decode([String].self, from: json)) ?? []
    }

    /// The entries of bibliography files (paths relative to the root or
    /// absolute), parsed with Hayagriva as Typst parses them. An editor buffer
    /// set with `setText` wins over the disk, and a file changed on disk is read
    /// again after `filesChanged`. The engine caches each file's parse by its
    /// version, so an unchanged file is not parsed again. Problems (syntax
    /// errors, fields Hayagriva cannot read, missing files, keys defined twice)
    /// are in `errors`.
    public func bibliography(_ files: [String]) -> BibliographyContents {
        let raw = withCStrings(files) { paths, count in
            engine.api.pointee.bibliography_entries(engine.pointer, paths, count)
        }
        guard let raw else {
            return .empty
        }
        defer { engine.api.pointee.string_free(raw) }
        let json = Data(bytes: raw, count: strlen(raw))
        return (try? JSONDecoder().decode(BibliographyContents.self, from: json)) ?? .empty
    }

    /// Compiles the whole document and keeps its counters and reference texts
    /// for later renders. Slow: up to a few seconds on a book. A failed compile
    /// keeps the previous context.
    public func refresh() -> RenderRefresh {
        var info = PRRefreshInfo()
        let succeeded = engine.api.pointee.refresh(engine.pointer, &info)
        return RenderRefresh(
            succeeded: succeeded,
            errors: Int(info.errors),
            warnings: Int(info.warnings),
            pages: Int(info.pages),
            headings: Int(info.headings),
            equations: Int(info.equations),
            references: Int(info.references),
            message: succeeded ? nil : lastError(or: "The document did not compile.").message,
        )
    }

    /// The file's blocks in order, from its current text.
    public func blocks(in file: URL) throws -> [RenderBlock] {
        var count = 0
        guard let raw = engine.api.pointee.blocks(engine.pointer, file.path, &count) else {
            throw lastError(or: "The file's blocks could not be read.")
        }
        defer { engine.api.pointee.blocks_free(raw, count) }
        return UnsafeBufferPointer(start: raw, count: count).map { block in
            let kind: RenderBlock.Kind = switch block.kind {
            case PR_BLOCK_HEADING: .heading
            case PR_BLOCK_EQUATION: .equation
            case PR_BLOCK_CONTEXT: .context
            case PR_BLOCK_INCLUDE: .include
            case PR_BLOCK_RAW: .raw
            case PR_BLOCK_LIST: .list
            case PR_BLOCK_COMMENT: .comment
            default: .paragraph
            }
            return RenderBlock(
                range: NSRange(location: Int(block.start), length: Int(block.end) - Int(block.start)),
                kind: kind,
            )
        }
    }

    /// Renders UTF-16 `range` of a file, `width` points wide, with the file's
    /// current text and the last refreshed context, with no text colour and no
    /// bitmap. Usually a range from `blocks(in:)`. Results are cached.
    public func render(_ range: NSRange, in file: URL, width: Double) -> Result<RenderedBlock, BlockRendererError> {
        render(range, in: file, width: width, options: RenderOptions())
    }

    /// Renders UTF-16 `range` of a file with options: the appearance and
    /// a bitmap scale. The bitmap is built here, off the main thread.
    public func render(
        _ range: NSRange,
        in file: URL,
        width: Double,
        options: RenderOptions,
    ) -> Result<RenderedBlock, BlockRendererError> {
        let limit = Int(UInt32.max)
        guard range.location >= 0, range.length >= 0, range.location <= limit,
              range.length <= limit - range.location
        else {
            return .failure(BlockRendererError("The range \(range) is outside any file."))
        }
        var rawOptions = PRRenderOptions()
        rawOptions.dark = options.dark
        rawOptions.bitmap_scale = options.bitmapScale
        let raw = engine.api.pointee.render(
            engine.pointer,
            file.path,
            UInt32(range.location),
            UInt32(NSMaxRange(range)),
            width,
            &rawOptions,
        )
        defer { engine.api.pointee.result_free(raw) }
        let result = raw.pointee
        if let error = result.error {
            return .failure(BlockRendererError(String(cString: error)))
        }
        let glyphs = UnsafeBufferPointer(start: result.glyphs, count: result.glyph_count).map { glyph in
            RenderedGlyph(
                rect: CGRect(
                    x: Double(glyph.x),
                    y: Double(glyph.y),
                    width: Double(glyph.width),
                    height: Double(glyph.height),
                ),
                source: glyph.source == PR_NO_SOURCE ? nil : Int(glyph.source),
            )
        }
        return .success(RenderedBlock(
            svg: result.svg.map { Data(bytes: $0, count: result.svg_length) } ?? Data(),
            size: CGSize(width: result.width, height: result.height),
            baseline: result.baseline,
            ink: CGRect(result.ink),
            drawnRect: CGRect(result.drawn),
            glyphs: glyphs,
            bitmap: Self.image(result),
            cached: result.cached,
            text: Self.text(result),
        ))
    }

    /// The result's plain text.
    private static func text(_ result: PRRenderResult) -> String {
        guard let text = result.text else {
            return ""
        }
        return String(decoding: UnsafeBufferPointer(start: text, count: result.text_length), as: UTF8.self)
    }

    /// The result's bitmap as an image that owns a copy of its pixels.
    private static func image(_ result: PRRenderResult) -> CGImage? {
        guard let pixels = result.bitmap, result.bitmap_width > 0, result.bitmap_height > 0,
              let provider = CGDataProvider(data: Data(bytes: pixels, count: result.bitmap_length) as CFData),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return nil
        }
        return CGImage(
            width: Int(result.bitmap_width),
            height: Int(result.bitmap_height),
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: result.bitmap_row_bytes,
            space: srgb,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent,
        )
    }

    public func cacheStats() -> RenderCacheStats {
        let stats = engine.api.pointee.cache_stats(engine.pointer)
        return RenderCacheStats(
            entries: Int(stats.entries),
            bytes: Int(stats.bytes),
            budget: Int(stats.budget),
            hits: Int(stats.hits),
            misses: Int(stats.misses),
        )
    }

    /// The engine's most recent error message.
    private func lastError(or fallback: String) -> BlockRendererError {
        guard let raw = engine.api.pointee.last_error(engine.pointer) else {
            return BlockRendererError(fallback)
        }
        defer { engine.api.pointee.string_free(raw) }
        return BlockRendererError(String(cString: raw))
    }
}

private extension CGRect {
    init(_ rect: PRRect) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}

/// Calls `body` with a C array of NUL-terminated copies of `strings`, valid for
/// the call only.
private func withCStrings<Result>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) -> Result,
) -> Result {
    let copies = strings.map { strdup($0) }
    defer { copies.forEach { free($0) } }
    return copies.map { UnsafePointer($0) }.withUnsafeBufferPointer { body($0.baseAddress, $0.count) }
}
