import Foundation

/// Installs versioned default plugins shipped inside Kumquat.app without touching
/// unrelated user plugins. Plugin payloads still run from Application Support,
/// so replacing the app does not remove them.
public enum BundledPluginInstaller {
    private struct Manifest: Decodable {
        struct Action: Decodable { let executable: String }
        let version: Int?
        let actions: [Action]?
    }

    @discardableResult
    public static func installDefaults(
        from resourceRoot: URL,
        into applicationSupport: URL,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let sourceRoot = resourceRoot.appendingPathComponent("DefaultPlugins", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        let kumquatRoot = applicationSupport.appendingPathComponent("Kumquat", isDirectory: true)
        let pluginRoot = kumquatRoot.appendingPathComponent("Plugins", isDirectory: true)
        let backupRoot = kumquatRoot.appendingPathComponent("PluginBackups", isDirectory: true)
        try fileManager.createDirectory(at: pluginRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let sources = try fileManager.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        var installed: [URL] = []
        for source in sources.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = source.lastPathComponent
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { continue }

            let sourceManifest = try readManifest(at: source, fileManager: fileManager)
            let sourceVersion = sourceManifest.version ?? 0
            guard sourceVersion > 0 else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: source.path])
            }

            let destination = pluginRoot.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: destination.path),
               let installedManifest = try? readManifest(at: destination, fileManager: fileManager),
               (installedManifest.version ?? 0) >= sourceVersion {
                continue
            }

            let staging = pluginRoot.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
            let backup = backupRoot.appendingPathComponent(name, isDirectory: true)
            try? fileManager.removeItem(at: staging)
            try fileManager.copyItem(at: source, to: staging)
            try makeExecutablesRunnable(in: staging, manifest: sourceManifest, fileManager: fileManager)

            var movedPrevious = false
            do {
                if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.moveItem(at: destination, to: backup)
                    movedPrevious = true
                }
                try fileManager.moveItem(at: staging, to: destination)
                if movedPrevious { try? fileManager.removeItem(at: backup) }
                installed.append(destination)
            } catch {
                try? fileManager.removeItem(at: staging)
                if movedPrevious,
                   !fileManager.fileExists(atPath: destination.path),
                   fileManager.fileExists(atPath: backup.path) {
                    try? fileManager.moveItem(at: backup, to: destination)
                }
                throw error
            }
        }
        return installed
    }

    private static func readManifest(at plugin: URL, fileManager: FileManager) throws -> Manifest {
        let url = plugin.appendingPathComponent("plugin.json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    private static func makeExecutablesRunnable(
        in plugin: URL,
        manifest: Manifest,
        fileManager: FileManager
    ) throws {
        for action in manifest.actions ?? [] {
            let relative = action.executable
            let components = NSString(string: relative).pathComponents
            guard !relative.hasPrefix("/"), !components.contains("..") else {
                throw CocoaError(.fileReadInvalidFileName, userInfo: [NSFilePathErrorKey: relative])
            }
            let executable = plugin.appendingPathComponent(relative).standardizedFileURL
            guard executable.path.hasPrefix(plugin.standardizedFileURL.path + "/"),
                  fileManager.fileExists(atPath: executable.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: executable.path])
            }
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
    }
}
