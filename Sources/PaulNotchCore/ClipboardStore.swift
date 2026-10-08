import AppKit
import CryptoKit
import Foundation

@MainActor
final class ClipboardStore: ObservableObject {
    enum CaptureState: Equatable { case disabled, paused, recording, failed }
    @Published private(set) var captureState: CaptureState = .disabled
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var errorMessage: String?
    private var persistenceBlocked = false

    private let pasteboard: NSPasteboard
    private let defaults: UserDefaults
    private let metadataURL: URL
    private let imageFolderURL: URL
    private let diagnosticsURL: URL
    private var lastChangeCount: Int
    private var monitorTimer: Timer?

    init(base: URL = AppEnvironment.dataDirectory, defaults: UserDefaults = AppEnvironment.defaults,
         pasteboard: NSPasteboard = .general) {
        self.defaults = defaults
        self.pasteboard = pasteboard
        imageFolderURL = base.appendingPathComponent("ClipboardImages", isDirectory: true)
        metadataURL = base.appendingPathComponent("clipboard-history.json")
        diagnosticsURL = base.appendingPathComponent("clipboard-types.log")
        lastChangeCount = pasteboard.changeCount

        try? FileManager.default.createDirectory(at: imageFolderURL, withIntermediateDirectories: true)
        load()
    }

    func startMonitoring() {
        applyPreferences()
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        lastChangeCount = pasteboard.changeCount
    }

    func copy(_ entry: ClipboardEntry) {
        switch entry.kind {
        case .text:
            pasteboard.clearContents()
            pasteboard.setString(entry.text ?? "", forType: .string)
        case .image:
            guard let fileName = entry.imageFileName,
                  let data = try? Data(contentsOf: imageFolderURL.appendingPathComponent(fileName)),
                  NSImage(data: data) != nil else {
                errorMessage = "图片缓存已丢失或无法读取，未更改当前剪贴板。请从原处重新复制图片。"
                return
            }
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
        }
        if !persistenceBlocked { errorMessage = nil }
        lastChangeCount = pasteboard.changeCount
        moveToFront(entry.id)
    }

    func image(for entry: ClipboardEntry) -> NSImage? {
        guard let fileName = entry.imageFileName else { return nil }
        return NSImage(contentsOf: imageFolderURL.appendingPathComponent(fileName))
    }

    func pollPasteboard() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !persistenceBlocked, !defaults.bool(forKey: "clipboard-capture-paused"),
              !SensitivePasteboard.shouldExclude(pasteboard) else { return }
        let source = NSWorkspace.shared.frontmostApplication?.localizedName

        let capturesText = defaults.object(forKey: "clipboard-capture-text") as? Bool ?? false
        let capturesImages = defaults.object(forKey: "clipboard-capture-images") as? Bool ?? false
        guard capturesText || capturesImages else { return }

        // Finder supplies both the actual file URL and a TIFF document-icon preview.
        // Resolve the file first so the history stores the real photo, not its icon.
        if capturesImages, let imageData = imageFileDataFromPasteboard() {
            recordImage(imageData, source: source)
        } else if capturesImages, let imageData = imageDataFromAvailableTypes() {
            recordImage(imageData, source: source)
        } else if capturesText, let text = pasteboard.string(forType: .string), !text.isEmpty {
            recordText(text, source: source)
        } else {
            writeUnhandledTypeDiagnostics(source: source)
        }
    }

    private func recordText(_ text: String, source: String?) {
        let fingerprint = digest(Data(text.utf8))
        if let existing = entries.first(where: { $0.fingerprint == fingerprint }) {
            moveToFront(existing.id, copiedAt: .now, source: source)
            return
        }
        var updated = entries
        updated.insert(ClipboardEntry(
            id: UUID(), kind: .text, fingerprint: fingerprint, text: text,
            imageFileName: nil, copiedAt: .now, sourceApplication: source
        ), at: 0)
        trimAndSave(updated)
    }

    private func recordImage(_ data: Data, source: String?) {
        let fingerprint = digest(data)
        if let existing = entries.first(where: { $0.fingerprint == fingerprint }) {
            moveToFront(existing.id, copiedAt: .now, source: source)
            return
        }
        let id = UUID()
        let fileName = "\(id.uuidString).png"
        do {
            try data.write(to: imageFolderURL.appendingPathComponent(fileName), options: .atomic)
            var updated = entries
            updated.insert(ClipboardEntry(
                id: id, kind: .image, fingerprint: fingerprint, text: nil,
                imageFileName: fileName, copiedAt: .now, sourceApplication: source
            ), at: 0)
            trimAndSave(updated)
        } catch {
            blockPersistence("图片未能保存，已暂停采集。请检查磁盘空间和工作区访问权限，再重新打开应用。")
        }
    }

    private func imageDataFromAvailableTypes() -> Data? {
        for type in pasteboard.types ?? [] {
            guard type != .fileURL,
                  let data = pasteboard.data(forType: type),
                  data.count <= 30_000_000 else { continue }
            if let png = pngData(from: data) { return png }
            if let embedded = embeddedImageData(in: data) { return embedded }
            if let webArchiveImage = imageDataFromPropertyList(data) { return webArchiveImage }
        }
        return nil
    }

    private func pngData(from data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }

    private func embeddedImageData(in data: Data) -> Data? {
        guard let markup = String(data: data, encoding: .utf8) else { return nil }
        let pattern = #"data:image/[^;]+;base64,([^\"'\s<>]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: markup, range: NSRange(markup.startIndex..., in: markup)),
              let range = Range(match.range(at: 1), in: markup),
              let decoded = Data(base64Encoded: String(markup[range]), options: .ignoreUnknownCharacters) else { return nil }
        return pngData(from: decoded)
    }

    private func imageDataFromPropertyList(_ data: Data) -> Data? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return firstImageData(in: root)
    }

    private func firstImageData(in value: Any) -> Data? {
        if let data = value as? Data, let png = pngData(from: data) { return png }
        if let values = value as? [Any] {
            for child in values { if let data = firstImageData(in: child) { return data } }
        }
        if let values = value as? [String: Any] {
            for child in values.values { if let data = firstImageData(in: child) { return data } }
        }
        return nil
    }


    private func imageFileDataFromPasteboard() -> Data? {
        var candidateURLs: [URL] = []

        if let urlText = pasteboard.string(forType: .fileURL),
           let url = URL(string: urlText), url.isFileURL {
            candidateURLs.append(url)
        }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            candidateURLs.append(contentsOf: urls)
        }

        // Some apps expose a copied file as a plain path in addition to the filename URL.
        if let path = pasteboard.string(forType: .string), path.hasPrefix("/"),
           FileManager.default.fileExists(atPath: path) {
            candidateURLs.append(URL(fileURLWithPath: path))
        }

        for url in candidateURLs {
            guard let image = NSImage(contentsOf: url),
                  let tiff = image.tiffRepresentation,
                  let representation = NSBitmapImageRep(data: tiff),
                  let png = representation.representation(using: .png, properties: [:]) else { continue }
            return png
        }
        return nil
    }

    private func writeUnhandledTypeDiagnostics(source: String?) {
        let typeSummary = (pasteboard.types ?? []).map { type in
            "\(type.rawValue)=\(pasteboard.data(forType: type)?.count ?? 0)"
        }.joined(separator: ", ")
        let line = "[\(Date().formatted(.iso8601))] source=\(source ?? "unknown") types: \(typeSummary)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: diagnosticsURL.path),
           let handle = try? FileHandle(forWritingTo: diagnosticsURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: diagnosticsURL, options: .atomic)
        }
    }

    private func moveToFront(_ id: UUID, copiedAt: Date? = nil, source: String? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var updated = entries
        var entry = updated.remove(at: index)
        if let copiedAt { entry.copiedAt = copiedAt }
        if let source { entry.sourceApplication = source }
        updated.insert(entry, at: 0)
        save(updated)
    }

    private func trimAndSave(_ candidate: [ClipboardEntry]) {
        guard !persistenceBlocked else { return }
        let savedLimit = defaults.integer(forKey: "clipboard-max-items")
        let limit = savedLimit > 0 ? min(max(savedLimit, 5), 100) : 20
        let retained = Array(candidate.prefix(limit))
        // Commit metadata before deleting evicted images; failed writes retain the old history.
        if save(retained) {
            for removed in candidate.dropFirst(limit) { deleteCachedImage(for: removed) }
        }
    }

    private func deleteCachedImage(for entry: ClipboardEntry) {
        guard let fileName = entry.imageFileName else { return }
        try? FileManager.default.removeItem(at: imageFolderURL.appendingPathComponent(fileName))
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return }
        guard let data = try? Data(contentsOf: metadataURL) else {
            persistenceBlocked = true
            errorMessage = "无法读取剪贴板历史，暂停采集以防覆盖"
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([ClipboardEntry].self, from: data) else {
            persistenceBlocked = true
            errorMessage = "剪贴板历史读取失败，原文件已保留，暂停采集以防覆盖"
            return
        }
        entries = decoded.filter { entry in
            guard entry.kind == .image, let fileName = entry.imageFileName else { return true }
            return FileManager.default.fileExists(atPath: imageFolderURL.appendingPathComponent(fileName).path)
        }
        // Reading must not rewrite history or delete cached files.
    }

    func applyPreferences() {
        // Enabling capture never imports the previously copied value.
        stopMonitoring()
        guard !persistenceBlocked else { captureState = .failed; return }
        let enabled = defaults.bool(forKey: "clipboard-capture-text") || defaults.bool(forKey: "clipboard-capture-images")
        guard enabled else { captureState = .disabled; return }
        guard !defaults.bool(forKey: "clipboard-capture-paused") else { captureState = .paused; return }
        let savedLimit = defaults.integer(forKey: "clipboard-max-items")
        let limit = savedLimit > 0 ? min(max(savedLimit, 5), 100) : 20
        if entries.count > limit { trimAndSave(entries) }
        guard !persistenceBlocked else { return }
        captureState = .recording
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.captureState == .recording, self.monitorTimer != nil else { return }
                self.pollPasteboard()
            }
        }
    }

    private func blockPersistence(_ message: String) {
        persistenceBlocked = true
        errorMessage = message
        stopMonitoring()
        captureState = .failed
    }

    @discardableResult
    private func save(_ candidate: [ClipboardEntry]) -> Bool {
        guard !persistenceBlocked else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(candidate)
            try data.write(to: metadataURL, options: .atomic)
            entries = candidate
            return true
        } catch {
            blockPersistence("复制记录未能保存，已暂停采集。请检查磁盘空间和工作区访问权限，再重新打开应用；已有记录不会被新内容替换。")
            return false
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
