import AppKit
import CoreGraphics
import Foundation

public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias StorageEditActions = NSTextStorageEditActions

extension PlatformFont {
    func italic() -> PlatformFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }
}
