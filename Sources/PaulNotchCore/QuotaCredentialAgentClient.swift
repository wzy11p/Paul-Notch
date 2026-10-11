import Foundation
import Security

/// Stable pinned helpers: legacy records or independently scoped custom APIs.
/// The helper authenticates the parent independently before reading its input.
@MainActor struct QuotaCredentialAgentClient {
    enum Generation {
        case legacyV1, stableV2, customV1
        var filename: String {
            switch self { case .legacyV1: "PaulCredentialAgent"; case .stableV2: "PaulCredentialAgentV2"; case .customV1: "PaulCustomQuotaAgentV1" }
        }
        var identifier: String {
            switch self {
            case .legacyV1: "local.paul.notch.credential-agent.v1"
            case .stableV2: "local.paul.notch.credential-agent.v2"
            case .customV1: "local.paul.notch.custom-quota-agent.v1"
            }
        }
    }
    private let executable: URL
    private let arguments: [String]
    let service: String
    private let account: String?
    init(executable: URL, service: String, arguments: [String] = [], account: String? = nil) {
        self.executable = executable; self.service = service; self.arguments = arguments; self.account = account
    }
    static func bundled(service: String, generation: Generation = .legacyV1, account: String? = nil) throws -> Self? {
        guard Bundle.main.bundleIdentifier == "local.paul.home-preview-20260905" else { return nil }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(generation.filename)")
        guard url.standardizedFileURL == url.resolvingSymlinksInPath() else { throw QuotaConnectionError.keychain }
        var code: SecStaticCode?; var requirement: SecRequirement?
        let pin = "identifier \"\(generation.identifier)\" and certificate leaf = H\"b93fcbf197e02d3e8568408d1ecdfc04adf1562e\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(pin as CFString, [], &requirement) == errSecSuccess,
              code != nil, SecStaticCodeCheckValidity(code!, [], requirement) == errSecSuccess else {
            throw QuotaConnectionError.keychain
        }
        return .init(executable: url, service: service, account: account)
    }
    func request(_ operation: String, value: String? = nil) throws -> String? {
        struct Request: Encodable { let operation, service: String; let value: String?; let account: String? }
        struct Response: Decodable { let status: Int32; let value: String? }
        let payload = try JSONEncoder().encode(Request(operation: operation, service: service, value: value, account: account))
        guard payload.count <= 65_536 else { throw QuotaConnectionError.keychain }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable; process.arguments = arguments
        // Never inherit a DYLD injection configuration or user credential env.
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw QuotaConnectionError.keychain }
        let deadline = CredentialAgentDeadline(process: process,
            seconds: account == nil && ["authorize", "save", "delete"].contains(operation) ? 180 : 8)
        defer { deadline.cancel() }
        do {
            try input.fileHandleForWriting.write(contentsOf: payload)
            try input.fileHandleForWriting.close()
            var bytes = Data()
            while let part = try output.fileHandleForReading.read(upToCount: 4096), !part.isEmpty {
                bytes.append(part)
                if bytes.count > 131_072 {
                    if process.isRunning { process.terminate() }; throw QuotaConnectionError.keychain
                }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let response = try? JSONDecoder().decode(Response.self, from: bytes) else { throw QuotaConnectionError.keychain }
            if response.status == errSecItemNotFound { return nil }
            if response.status == errSecNotAvailable { throw QuotaConnectionError.keychainLocked }
            guard response.status == errSecSuccess else { throw QuotaConnectionError.keychain }
            return response.value
        } catch let error as QuotaConnectionError { throw error }
        catch { throw QuotaConnectionError.keychain }
    }
}
private final class CredentialAgentDeadline: @unchecked Sendable {
    private let process: Process
    private let timer: DispatchSourceTimer
    init(process: Process, seconds: Int) {
        self.process = process
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(seconds))
        timer.setEventHandler { [weak self] in
            if let self, self.process.isRunning { self.process.terminate() }
        }
        timer.resume()
    }
    func cancel() { timer.cancel() }
}
