import Foundation
import XCTest
@testable import KumquatCore

final class ExternalPluginTests: XCTestCase {
    func testManifestDiscoveryFiltersByExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let plugin = root.appendingPathComponent("sample", isDirectory: true)
        let executable = plugin.appendingPathComponent("bin/run")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let manifest = """
        {"schemaVersion":1,"id":"test.plugin","actions":[
          {"id":"json","title":"JSON Tool","symbol":"curlybraces","extensions":["json"],"executable":"bin/run","arguments":["{input}"],"order":1}
        ]}
        """
        try Data(manifest.utf8).write(to: plugin.appendingPathComponent("plugin.json"))
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(ExternalPluginCatalog.actions(for: [URL(fileURLWithPath: "/tmp/a.json")], directory: root).map(\.id), ["plugin.test.plugin.json"])
        XCTAssertTrue(ExternalPluginCatalog.actions(for: [URL(fileURLWithPath: "/tmp/a.har")], directory: root).isEmpty)
    }

    func testExternalActionRunsAndValidatesOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.json")
        let output = root.appendingPathComponent("input_llm_ready.json")
        try Data("{}".utf8).write(to: input)
        let executable = root.appendingPathComponent("run")
        let body = "#!/bin/sh\nprintf '{\"outputs\":[\"\(output.path)\"],\"detail\":\"ok\"}'\nprintf '{}' > '\(output.path)'\n"
        try Data(body.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let action = ExternalAction(pluginID: "test", actionID: "json", title: "JSON", symbol: "curlybraces", acceptedExtensions: ["json"], executablePath: executable.path, arguments: ["{input}"], order: 1)

        let result = try action.run(on: input)
        XCTAssertEqual(result.outputs, [output])
        XCTAssertEqual(result.detail, "ok")
    }
}
