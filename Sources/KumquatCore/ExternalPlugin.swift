import Foundation

/// A command supplied outside the app bundle through a versioned JSON manifest.
/// Plugin files live in Application Support, so replacing Kumquat.app never removes them.
public struct ExternalAction: Hashable, Sendable, Codable {
    public let pluginID: String
    public let actionID: String
    public let title: String
    public let symbol: String
    public let acceptedExtensions: [String]
    public let executablePath: String
    public let arguments: [String]
    public let order: Int

    public var id: String { "plugin.\(pluginID).\(actionID)" }

    public func accepts(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy { acceptedExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Runs the executable and validates its one-line JSON response.
    /// Response contract: {"outputs":["/absolute/path"],"detail":"optional text"}
    public func run(on input: URL) throws -> (outputs: [URL], detail: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments.map {
            $0.replacingOccurrences(of: "{input}", with: input.path)
                .replacingOccurrences(of: "{inputDirectory}", with: input.deletingLastPathComponent().path)
                .replacingOccurrences(of: "{inputName}", with: input.lastPathComponent)
        }
        process.currentDirectoryURL = URL(fileURLWithPath: executablePath).deletingLastPathComponent()

        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw KumquatError.toolFailed(title, "Could not launch plugin: \(error.localizedDescription)")
        }
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw KumquatError.toolFailed(title, errorText.isEmpty ? "Plugin exited with status \(process.terminationStatus)." : errorText)
        }
        let response: ExternalActionResponse
        do {
            response = try JSONDecoder().decode(ExternalActionResponse.self, from: outputData)
        } catch {
            let raw = String(data: outputData, encoding: .utf8)?.prefix(300) ?? ""
            throw KumquatError.toolFailed(title, "Invalid plugin response: \(raw)")
        }
        guard !response.outputs.isEmpty else {
            throw KumquatError.toolFailed(title, "Plugin returned no output file.")
        }
        let urls = response.outputs.map { URL(fileURLWithPath: $0).standardizedFileURL }
        guard urls.allSatisfy({ $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }) else {
            throw KumquatError.toolFailed(title, "Plugin reported an output that does not exist.")
        }
        return (urls, response.detail)
    }
}

private struct ExternalActionResponse: Decodable {
    let outputs: [String]
    let detail: String?
}

private struct PluginManifest: Decodable {
    let schemaVersion: Int
    let id: String
    let actions: [ManifestAction]
}

private struct ManifestAction: Decodable {
    let id: String
    let title: String
    let symbol: String?
    let extensions: [String]
    let executable: String
    let arguments: [String]?
    let order: Int?
}

public enum ExternalPluginCatalog {
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["KUMQUAT_PLUGIN_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Kumquat/Plugins", isDirectory: true)
    }

    public static func actions(for urls: [URL], directory: URL = defaultDirectory) -> [ExternalAction] {
        load(directory: directory).filter { $0.accepts(urls) }
    }

    public static func load(directory: URL = defaultDirectory) -> [ExternalAction] {
        let manager = FileManager.default
        guard let pluginDirs = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var loaded: [ExternalAction] = []
        for pluginDir in pluginDirs.sorted(by: { $0.path < $1.path }) {
            let manifestURL = pluginDir.appendingPathComponent("plugin.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data),
                  manifest.schemaVersion == 1,
                  validIdentifier(manifest.id) else { continue }

            for item in manifest.actions where validIdentifier(item.id) && !item.title.isEmpty {
                let relative = item.executable as NSString
                guard !relative.isAbsolutePath, !relative.pathComponents.contains("..") else { continue }
                let executable = pluginDir.appendingPathComponent(item.executable).standardizedFileURL
                let pluginRoot = pluginDir.standardizedFileURL.path + "/"
                guard executable.path.hasPrefix(pluginRoot), manager.isExecutableFile(atPath: executable.path) else { continue }
                let extensions = Array(Set(item.extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty })).sorted()
                guard !extensions.isEmpty else { continue }
                loaded.append(ExternalAction(
                    pluginID: manifest.id,
                    actionID: item.id,
                    title: item.title,
                    symbol: item.symbol?.isEmpty == false ? item.symbol! : "puzzlepiece.extension",
                    acceptedExtensions: extensions,
                    executablePath: executable.path,
                    arguments: item.arguments ?? ["{input}"],
                    order: item.order ?? 1_000
                ))
            }
        }
        return loaded.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id < $1.id
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)
        }
    }
}
