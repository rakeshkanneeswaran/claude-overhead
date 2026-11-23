import Foundation
import Testing
@testable import ChimloCore

@Suite("Configuration file writer")
struct ConfigurationFileWriterTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overhead-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func mode(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return try #require(value).intValue
    }

    @Test("A symlinked settings file stays a symlink, and its target is what changes")
    func writesThroughASymlink() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dotfiles = root.appendingPathComponent("dotfiles", isDirectory: true)
        let claude = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("settings.json")
        let link = claude.appendingPathComponent("settings.json")
        let before = Data(#"{"theme":"dark"}"#.utf8)
        try before.write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let after = Data(#"{"theme":"dark","hooks":{}}"#.utf8)
        try ConfigurationFileWriter.replace(link, with: after, expecting: before)

        let linkType = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(linkType == .typeSymbolicLink)
        #expect(try Data(contentsOf: real) == after)
        #expect(try Data(contentsOf: link) == after)
        // The real file's mode, not the link's.
        #expect(try mode(real) == 0o640)
    }

    @Test("A plain file keeps its permissions")
    func keepsPermissions() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let before = Data("{}".utf8)
        try before.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        try ConfigurationFileWriter.replace(file, with: Data(#"{"a":1}"#.utf8), expecting: before)
        #expect(try mode(file) == 0o644)
    }

    @Test("A new file is private to its owner")
    func newFileIsPrivate() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")

        try ConfigurationFileWriter.replace(file, with: Data("{}".utf8), expecting: nil)
        #expect(try mode(file) == 0o600)
    }

    @Test("A file that changed since it was read is not overwritten")
    func refusesToOverwriteANewerFile() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let read = Data(#"{"model":"a"}"#.utf8)
        try read.write(to: file)
        // Claude Code saves a change after our read.
        let newer = Data(#"{"model":"b"}"#.utf8)
        try newer.write(to: file)

        #expect(throws: ConfigurationFileWriter.WriteError.changedMeanwhile) {
            try ConfigurationFileWriter.replace(file, with: Data(#"{"model":"a","hooks":{}}"#.utf8), expecting: read)
        }
        #expect(try Data(contentsOf: file) == newer)
    }

    @Test("A file that appeared since it was found missing is not overwritten")
    func refusesToOverwriteAFileThatAppeared() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let appeared = Data(#"{"model":"b"}"#.utf8)
        try appeared.write(to: file)

        #expect(throws: ConfigurationFileWriter.WriteError.changedMeanwhile) {
            try ConfigurationFileWriter.replace(file, with: Data("{}".utf8), expecting: nil)
        }
        #expect(try Data(contentsOf: file) == appeared)
    }
}
