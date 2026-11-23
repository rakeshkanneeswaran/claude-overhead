import ChimloCore
import Foundation

// overhead-release-notes: checks and publishes a release's What's New.
//
//   overhead-release-notes check [--release 1.2.3] [--root <repository>]
//       Every file in ReleaseNotes/ is well formed, CHANGELOG.md and the
//       notes agree, and (with --release) that version is ready to publish.
//
//   overhead-release-notes emit 1.2.3 --output <file> [--assets <folder>] [--root <repository>]
//       Writes the notes as they are published: compact, self-contained,
//       every picture's SHA-256 filled in. Copies the pictures to --assets.
//
// All the rules live in ChimloCore, where they are tested; this only reads
// and writes files.

struct Failure: Error {
    let message: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func value(of flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

struct Repository {
    let root: URL

    var notesFolder: URL { root.appendingPathComponent("ReleaseNotes", isDirectory: true) }

    func changelog() throws -> String {
        try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
    }

    func appVersion() throws -> String {
        let url = root.appendingPathComponent("Packaging/Info.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        guard let version = (plist as? [String: Any])?["CFBundleShortVersionString"] as? String else {
            throw Failure(message: "Packaging/Info.plist has no CFBundleShortVersionString.")
        }
        return version
    }

    /// The version each notes file is named for.
    func notesVersions() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: notesFolder.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    func notes(for version: String) throws -> ReleaseNotes {
        let url = notesFolder.appendingPathComponent("\(version).json")
        do {
            return try JSONDecoder().decode(ReleaseNotes.self, from: Data(contentsOf: url))
        } catch let error as DecodingError {
            throw Failure(message: "ReleaseNotes/\(version).json cannot be read: \(describe(error))")
        } catch {
            throw Failure(message: "ReleaseNotes/\(version).json cannot be read: \(error.localizedDescription)")
        }
    }

    /// A release's pictures sit in ReleaseNotes/<version>/.
    func asset(_ file: String, for version: String) -> Data? {
        guard ReleaseImageCheck.isSafeFileName(file) else { return nil }
        return try? Data(contentsOf: notesFolder.appendingPathComponent(version, isDirectory: true).appendingPathComponent(file))
    }
}

func describe(_ error: DecodingError) -> String {
    switch error {
    case let .keyNotFound(key, context):
        "\"\(key.stringValue)\" is missing at \(path(context))."
    case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context):
        "\(context.debugDescription) (at \(path(context)))"
    @unknown default:
        "\(error)"
    }
}

func path(_ context: DecodingError.Context) -> String {
    let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    return path.isEmpty ? "the top level" : path
}

func check(repository: Repository, releasing: String?) throws {
    var problems: [String] = []
    var notes: [String: ReleaseNotes] = [:]
    for version in repository.notesVersions() {
        do {
            let release = try repository.notes(for: version)
            notes[version] = release
            // Publishing fills in the pictures, so their files are checked too.
            let published = ReleaseNotesPublisher.publish(release) { repository.asset($0, for: version) }
            let structural = Set(ReleaseNotesValidator.problems(in: release))
            problems.append(contentsOf: published.problems.filter { !structural.contains($0) }.map {
                "ReleaseNotes/\(version).json: \($0)"
            })
        } catch let failure as Failure {
            problems.append(failure.message)
        }
    }
    let appVersion = try repository.appVersion()
    problems.append(contentsOf: ReleaseReadiness.problems(
        changelog: try repository.changelog(),
        appVersion: appVersion,
        notes: notes,
        releasing: releasing
    ))
    // A file that could not be read is already reported; do not also call it missing.
    let unreadable = Set(repository.notesVersions()).subtracting(notes.keys)
    problems.removeAll { problem in unreadable.contains { problem.contains("no ReleaseNotes/\($0).json") } }

    guard problems.isEmpty else {
        for problem in problems { FileHandle.standardError.write(Data("  ✘ \(problem)\n".utf8)) }
        fail("\(problems.count) problem\(problems.count == 1 ? "" : "s") with the release notes. See Docs/RELEASING.md.")
    }
    for version in notes.keys.sorted() {
        guard let release = notes[version] else { continue }
        print("  ✔ ReleaseNotes/\(version).json: \(release.cards.count) cards (\(release.summaryLine))")
    }
    if let releasing {
        print("What's New for \(releasing) is ready to publish.")
    } else {
        print("Release notes are in order (app version \(appVersion)).")
    }
}

func emit(repository: Repository, version: String, output: String, assets: String?) throws {
    let release = try repository.notes(for: version)
    guard release.version == version else {
        throw Failure(message: "ReleaseNotes/\(version).json describes version \(release.version).")
    }
    let published = ReleaseNotesPublisher.publish(release) { repository.asset($0, for: version) }
    guard published.problems.isEmpty else {
        for problem in published.problems { FileHandle.standardError.write(Data("  ✘ \(problem)\n".utf8)) }
        throw Failure(message: "ReleaseNotes/\(version).json is not fit to publish.")
    }
    let data = try published.notes.published()
    // What the app will read back must be exactly these notes.
    guard case let .notes(read) = ReleaseNotesReader.content(data: data, expectedVersion: version),
          read == published.notes else {
        throw Failure(message: "The published notes for \(version) do not read back as written.")
    }
    let outputURL = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: outputURL, options: .atomic)
    if let assets {
        let folder = URL(fileURLWithPath: assets, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ReleaseNotesPublisher.imageFiles(in: published.notes) {
            guard let bytes = repository.asset(file, for: version) else { continue }
            try bytes.write(to: folder.appendingPathComponent(file), options: .atomic)
            print(folder.appendingPathComponent(file).path)
        }
    }
    print(outputURL.path)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let repository = Repository(root: URL(
    fileURLWithPath: value(of: "--root", in: arguments) ?? FileManager.default.currentDirectoryPath,
    isDirectory: true
))

do {
    switch arguments.first {
    case "check":
        try check(repository: repository, releasing: value(of: "--release", in: arguments))
    case "emit":
        guard arguments.count >= 2, AppVersion(arguments[1]) != nil,
              let output = value(of: "--output", in: arguments) else {
            fail("usage: overhead-release-notes emit <version> --output <file> [--assets <folder>]")
        }
        try emit(repository: repository, version: arguments[1], output: output, assets: value(of: "--assets", in: arguments))
    default:
        fail("usage: overhead-release-notes check [--release <version>] | emit <version> --output <file> [--assets <folder>]")
    }
} catch let failure as Failure {
    fail(failure.message)
} catch {
    fail(error.localizedDescription)
}
