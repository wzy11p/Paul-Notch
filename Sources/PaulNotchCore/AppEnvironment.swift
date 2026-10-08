import Foundation
import CryptoKit
import Darwin

/// Resolve before constructing any store. Isolated workspaces never fall back to legacy data.
struct AppDataEnvironment: Sendable {
    enum Mode: Sendable { case legacy, preview, personal }

    let dataDirectory: URL
    let preferencesSuite: String?
    let mode: Mode
    var isPreview: Bool { mode == .preview }
    var isPersonal: Bool { mode == .personal }
    var usesIsolatedWorkspace: Bool { mode != .legacy }

    enum ConfigurationError: Error {
        case invalidPreviewDirectory, conflictingConfiguration, incompletePersonalConfiguration
        case invalidPersonalDirectory, invalidPersonalPreferencesSuite, invalidPersonalMarker
        case invalidConfiguration, missingIsolatedConfiguration
    }

    init(previewDirectory: String?, productionDirectory: URL,
         personalDirectory: String? = nil, personalPreferencesSuite: String? = nil,
         applicationSupportDirectory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]) throws {
        let hasPersonalConfiguration = personalDirectory != nil || personalPreferencesSuite != nil
        guard !(previewDirectory != nil && hasPersonalConfiguration) else {
            throw ConfigurationError.conflictingConfiguration
        }
        if hasPersonalConfiguration {
            guard let personalDirectory, let personalPreferencesSuite else {
                throw ConfigurationError.incompletePersonalConfiguration
            }
            guard Self.isPreservedPreviewSuite(personalPreferencesSuite) else {
                throw ConfigurationError.invalidPersonalPreferencesSuite
            }
            let root = try Self.personalRoot(personalDirectory, applicationSupportDirectory: applicationSupportDirectory,
                                             productionDirectory: productionDirectory)
            try Self.validatePersonalMarker(at: root, preferencesSuite: personalPreferencesSuite,
                                            productionDirectory: productionDirectory)
            dataDirectory = root
            preferencesSuite = personalPreferencesSuite
            mode = .personal
            return
        }
        guard let previewDirectory else {
            dataDirectory = productionDirectory
            preferencesSuite = nil
            mode = .legacy
            return
        }
        let root = try Self.previewRoot(previewDirectory, productionDirectory: productionDirectory)
        dataDirectory = root
        preferencesSuite = Self.previewSuite(for: root.path)
        mode = .preview
    }

    /// Pure configuration resolution: this neither opens preferences nor creates any directories.
    static func resolve(arguments: [String], environment: [String: String], bundleInfo: [String: Any],
                        bundleIdentifier: String?, applicationSupportDirectory: URL) throws -> Self {
        func stringValue(_ key: String) throws -> String? {
            guard let value = bundleInfo[key] else { return nil }
            guard let text = value as? String else { throw ConfigurationError.invalidConfiguration }
            return text
        }
        let bundlePreview = try stringValue("PaulPreviewDataDirectory")
        let personal = try stringValue("PaulPersonalDataDirectory")
        let personalSuite = try stringValue("PaulPersonalPreferencesSuite")
        let previewIndices = arguments.indices.filter { arguments[$0] == "--memo-ui-preview" }
        guard previewIndices.count <= 1 else { throw ConfigurationError.invalidConfiguration }
        var preview = environment["PAUL_PREVIEW_DIRECTORY"] ?? bundlePreview
        if let index = previewIndices.first {
            guard arguments.indices.contains(index + 1) else { throw ConfigurationError.invalidConfiguration }
            preview = arguments[index + 1]
        }
        if (personal != nil || personalSuite != nil),
           bundlePreview != nil || environment["PAUL_PREVIEW_DIRECTORY"] != nil || !previewIndices.isEmpty {
            throw ConfigurationError.conflictingConfiguration
        }
        let result = try Self(previewDirectory: preview,
                              productionDirectory: applicationSupportDirectory.appendingPathComponent("Paul Notch", isDirectory: true),
                              personalDirectory: personal, personalPreferencesSuite: personalSuite,
                              applicationSupportDirectory: applicationSupportDirectory)
        // The accepted installation keeps its original Bundle ID to preserve its identity.
        if bundleIdentifier?.hasPrefix("local.paul.") == true,
           bundleIdentifier?.contains("preview") == true, !result.usesIsolatedWorkspace {
            throw ConfigurationError.missingIsolatedConfiguration
        }
        return result
    }

    private static func previewRoot(_ previewDirectory: String, productionDirectory: URL) throws -> URL {
        guard previewDirectory.hasPrefix("/"), !previewDirectory.contains("\0") else {
            throw ConfigurationError.invalidPreviewDirectory
        }
        let root = URL(fileURLWithPath: previewDirectory, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let production = productionDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let temporaryRoots = [URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath(),
                              FileManager.default.temporaryDirectory.resolvingSymlinksInPath()]
        // Only dedicated temporary children are accepted; never /tmp itself, HOME,
        // the live workspace, or an ancestor of it. Symlink aliases are resolved first.
        guard temporaryRoots.contains(where: { root.path.hasPrefix($0.path + "/") }),
              root.path != production.path,
              !root.path.hasPrefix(production.path + "/"),
              !production.path.hasPrefix(root.path + "/") else {
            throw ConfigurationError.invalidPreviewDirectory
        }
        return root
    }

    private static func previewSuite(for canonicalPath: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalPath.utf8)).map { String(format: "%02x", $0) }.joined()
        return "local.paul.preview." + digest
    }

    private static func isPreservedPreviewSuite(_ suite: String) -> Bool {
        let prefix = "local.paul.preview."
        guard suite.hasPrefix(prefix) else { return false }
        let digest = suite.dropFirst(prefix.count)
        return digest.utf8.count == 64 && digest.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func personalRoot(_ path: String, applicationSupportDirectory: URL,
                                     productionDirectory: URL) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0"), applicationSupportDirectory.isFileURL else {
            throw ConfigurationError.invalidPersonalDirectory
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let expected = applicationSupportDirectory.standardizedFileURL
            .appendingPathComponent("Paul Notch", isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)
        let production = productionDirectory.standardizedFileURL.resolvingSymlinksInPath()
        // Compare before resolving links, so a linked Paul Notch parent cannot redefine the allowed root.
        guard root.path == expected.path, root.resolvingSymlinksInPath().path == expected.path,
              root.path != production.path, !root.path.hasPrefix(production.path + "/"),
              !production.path.hasPrefix(root.path + "/") else {
            throw ConfigurationError.invalidPersonalDirectory
        }
        for directory in [root.deletingLastPathComponent(), root] {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw ConfigurationError.invalidPersonalDirectory
            }
        }
        return root
    }

    private struct InstallationMarker: Decodable {
        let schemaVersion: Int
        let preferencesSuite: String
        let sourceDirectory: String
    }

    private static func validatePersonalMarker(at root: URL, preferencesSuite: String,
                                               productionDirectory: URL) throws {
        let directoryDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw ConfigurationError.invalidPersonalMarker }
        defer { close(directoryDescriptor) }
        let markerDescriptor = openat(directoryDescriptor, "installation-v1.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard markerDescriptor >= 0 else { throw ConfigurationError.invalidPersonalMarker }
        let handle = FileHandle(fileDescriptor: markerDescriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(markerDescriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_size > 0, attributes.st_size <= 65_536 else {
            throw ConfigurationError.invalidPersonalMarker
        }
        do {
            guard let bytes = try handle.read(upToCount: 65_537), bytes.count <= 65_536 else {
                throw ConfigurationError.invalidPersonalMarker
            }
            let marker = try JSONDecoder().decode(InstallationMarker.self, from: bytes)
            guard marker.schemaVersion == 1, marker.preferencesSuite == preferencesSuite,
                  let source = canonicalHistoricalTemporaryPath(marker.sourceDirectory),
                  previewSuite(for: source) == preferencesSuite else {
                throw ConfigurationError.invalidPersonalMarker
            }
            let production = productionDirectory.standardizedFileURL.resolvingSymlinksInPath().path
            guard source != production, !source.hasPrefix(production + "/"),
                  !production.hasPrefix(source + "/") else {
                throw ConfigurationError.invalidPersonalMarker
            }
        } catch {
            throw ConfigurationError.invalidPersonalMarker
        }
    }

    /// Validate historical path metadata without reading or depending on the old, disposable workspace.
    private static func canonicalHistoricalTemporaryPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let source = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        let temporaryRoots = [URL(fileURLWithPath: "/tmp", isDirectory: true), FileManager.default.temporaryDirectory]
        for temporary in temporaryRoots {
            let canonical = temporary.resolvingSymlinksInPath().standardizedFileURL.path
            for alias in [temporary.standardizedFileURL.path, canonical] where source.hasPrefix(alias + "/") {
                return canonical + source.dropFirst(alias.count)
            }
        }
        return nil
    }
}

enum AppEnvironment {
    static let current: AppDataEnvironment = {
        do {
            return try AppDataEnvironment.resolve(
                arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment,
                bundleInfo: Bundle.main.infoDictionary ?? [:], bundleIdentifier: Bundle.main.bundleIdentifier,
                applicationSupportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        } catch {
            fatalError("Invalid workspace configuration; refusing to open legacy data (\(error))")
        }
    }()

    static var dataDirectory: URL { current.dataDirectory }
    static var isPreview: Bool { current.isPreview }
    static var isPersonal: Bool { current.isPersonal }
    static var usesIsolatedWorkspace: Bool { current.usesIsolatedWorkspace }
    /// Dedicated quota connections are opt-in in an ordinary public runtime as
    /// well as the maintainer profile. This does not enable legacy integrations
    /// or weaken the independent credential-helper identity checks.
    static var ownedQuotaConnectionsEnabled: Bool { !isPreview }
    /// The Home refresh button must honor the same explicit opt-in as app startup.
    static var codexStatusReadsEnabled: Bool {
        !usesIsolatedWorkspace || ProcessInfo.processInfo.arguments.contains("--preview-live-codex")
            || Bundle.main.object(forInfoDictionaryKey: "PaulPreviewLiveCodex") as? Bool == true
    }
    // Foundation documents UserDefaults as thread-safe. The selected instance is immutable.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard let suite = current.preferencesSuite else { return .standard }
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Cannot open workspace preferences") }
        return defaults
    }()
    /// Independent, crash-safe WebKit profiles require macOS 14+. Isolated
    /// previews and older systems must never silently share the default store.
    static var ownedWebsiteDefaults: UserDefaults? {
        guard ownedQuotaConnectionsEnabled, #available(macOS 14, *) else { return nil }
        return defaults
    }
}
