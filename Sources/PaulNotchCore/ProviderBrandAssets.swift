import AppKit

/// Official, source-attributed assets only. Missing artwork stays absent rather than invented.
@MainActor
enum ProviderBrandAssets {
    private static let names = ["codex", "kimi", "grok", "doubao", "deepseek", "minimax-api", "minimax-audio"]
    // Measured transparent app-icon gutters in the attributed source assets.
    // Leave the edge antialiasing intact; full-bleed marks need no adjustment.
    // This is display-only normalization: packaged originals remain unchanged.
    private static let displayInsets: [String: CGFloat] = [
        "codex": 98.0 / 1024,
        "kimi": 12.0 / 128,
        "doubao": 12.0 / 128,
        "cursor": 13.0 / 128,
        "grok": 13.0 / 128,
        "muse": 24.0 / 256,
    ]
    private static let images: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        for name in names {
            var url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "ProviderLogos")
            #if DEBUG
            if url == nil {
                url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("Resources/ProviderLogos/\(name).png")
            }
            #endif
            if let url, let image = NSImage(contentsOf: url) {
                result[name] = fitted(image, for: name)
            }
        }
        return result
    }()

    private static let desktopImages: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        for (id, name, identifier) in [("cursor", "Cursor", "com.todesktop.230313mzl4w4u92"),
                                        ("grok", "Grok Bot", "com.anysphere.sand"),
                                        ("muse", "Muse", "com.meta.endo")] {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
                ?? URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true)
            // LaunchServices can be unavailable in an isolated debug process. Only
            // use the actual application's declared artwork after verifying identity.
            guard let bundle = Bundle(url: url), bundle.bundleIdentifier == identifier,
                  let icon = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
                  (icon as NSString).lastPathComponent == icon else { continue }
            let resource = (icon as NSString).pathExtension.isEmpty ? icon + ".icns" : icon
            guard let resourceURL = bundle.resourceURL?.appendingPathComponent(resource),
                  let image = NSImage(contentsOf: resourceURL) else { continue }
            result[id] = fitted(image, for: id)
        }
        return result
    }()
    private static func fitted(_ image: NSImage, for id: String) -> NSImage {
        guard let inset = displayInsets[id],
              let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let bounds = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        let margin = CGFloat(min(original.width, original.height)) * inset
        guard let content = original.cropping(to: bounds.insetBy(dx: margin, dy: margin)) else { return image }
        return NSImage(cgImage: content, size: NSSize(width: content.width, height: content.height))
    }
    static func image(for accountID: String) -> NSImage? {
        // Actual installed product artwork, cached rather than queried during pointer tracking.
        if ["cursor", "grok", "muse"].contains(accountID) { return desktopImages[accountID] }
        return images[accountID]
    }
}
