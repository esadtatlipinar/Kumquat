import Foundation
import XCTest
@testable import KumquatCore

final class BundledPluginInstallerTests: XCTestCase {
    func testInstallsAndUpgradesOnlyBundledPlugin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let bundled = resources.appendingPathComponent("DefaultPlugins/sample", isDirectory: true)
        let appSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        let installed = appSupport.appendingPathComponent("Kumquat/Plugins/sample", isDirectory: true)
        let unrelated = appSupport.appendingPathComponent("Kumquat/Plugins/unrelated", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: bundled.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appendingPathComponent("marker"))
        try Data("keep".utf8).write(to: unrelated.appendingPathComponent("marker"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundled.appendingPathComponent("bin/run"))
        try Data(#"{"version":2,"actions":[{"executable":"bin/run"}]}"#.utf8).write(to: bundled.appendingPathComponent("plugin.json"))
        try Data(#"{"version":1,"actions":[]}"#.utf8).write(to: installed.appendingPathComponent("plugin.json"))

        let first = try BundledPluginInstaller.installDefaults(from: resources, into: appSupport)
        XCTAssertEqual(first, [installed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.appendingPathComponent("marker").path))
        XCTAssertEqual(try String(contentsOf: unrelated.appendingPathComponent("marker")), "keep")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.appendingPathComponent("bin/run").path))

        let second = try BundledPluginInstaller.installDefaults(from: resources, into: appSupport)
        XCTAssertTrue(second.isEmpty)
    }
}
