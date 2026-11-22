import Foundation

/// Recognizes test-runner invocations inside a Bash tool command and reduces
/// them to a display-safe string. Claude usually wraps tests in compound lines
/// (`cd pkg && FOO=1 swift test 2>&1 | tail`), so the line is split into
/// simple commands and only the one that runs the suite is kept: the `cd`
/// path, pipes, and environment assignments never reach the UI.
enum TranscriptInsightsTestCommand {
    static let maximumCharacters = 160

    /// Long heredocs can make a Bash command arbitrarily large; test runners
    /// appear near the start, so analysis stops after this many bytes.
    private static let maximumAnalyzedUTF8Bytes = 16_384

    /// Returns the redacted test-runner segment of `bashCommand`, or `nil`
    /// when nothing in it runs tests.
    static func testRunnerCommand(from bashCommand: String) -> String? {
        let analyzed = String(decoding: bashCommand.utf8.prefix(maximumAnalyzedUTF8Bytes), as: UTF8.self)
        for segment in segments(of: analyzed) {
            let command = strippingEnvironment(segment)
            guard !command.isEmpty, runsTests(command.map(\.value)) else { continue }
            return truncated(command.map(\.raw).joined(separator: " "))
        }
        return nil
    }

    // MARK: Matching

    private static let packageManagers: Set<String> = ["npm", "pnpm", "yarn", "bun"]
    private static let packageRunners: Set<String> = ["npx", "bunx", "pnpx"]
    private static let javaScriptRunners: Set<String> = ["jest", "vitest"]
    private static let standaloneRunners: Set<String> = ["jest", "vitest", "pytest", "rspec", "phpunit"]

    private static func runsTests(_ words: [String]) -> Bool {
        let words = strippingWrappers(words)
        guard let first = words.first else { return false }
        // Match on the executable name so `./gradlew` or `.venv/bin/pytest`
        // count like their bare forms.
        let tool = first.split(separator: "/").last.map(String.init) ?? first
        let rest = Array(words.dropFirst())
        let subcommand = rest.first

        if standaloneRunners.contains(tool) { return true }
        if packageRunners.contains(tool) {
            return subcommand.map { javaScriptRunners.contains($0) } ?? false
        }
        if packageManagers.contains(tool) {
            guard let subcommand else { return false }
            if subcommand == "test" || subcommand.hasPrefix("test:") { return true }
            if subcommand == "run" || subcommand == "exec" {
                guard rest.count > 1 else { return false }
                let script = rest[1]
                return script == "test" || script.hasPrefix("test:") || javaScriptRunners.contains(script)
            }
            return javaScriptRunners.contains(subcommand)
        }
        if tool.hasPrefix("python") {
            return rest.count >= 2 && rest[0] == "-m" && rest[1] == "pytest"
        }
        switch tool {
        case "swift", "go", "cargo":
            return subcommand == "test"
        case "xcodebuild":
            return rest.contains("test") || rest.contains("test-without-building")
        case "make", "mvn", "mvnw":
            return rest.contains("test")
        case "gradle", "gradlew":
            return rest.contains { $0 == "test" || $0.hasSuffix(":test") }
        default:
            return false
        }
    }

    /// Drops launchers that run another command unchanged, so `uv run pytest`
    /// and `bundle exec rspec` match like their bare forms.
    private static func strippingWrappers(_ words: [String]) -> [String] {
        var words = words[...]
        while let first = words.first {
            if first == "time" || first == "nice" || first == "command" {
                words = words.dropFirst()
            } else if ["uv", "poetry", "pipenv", "pdm"].contains(first), words.dropFirst().first == "run" {
                words = words.dropFirst(2)
            } else if first == "bundle", words.dropFirst().first == "exec" {
                words = words.dropFirst(2)
            } else {
                break
            }
        }
        return Array(words)
    }

    // MARK: Redaction

    /// Removes `NAME=value` words, because that is where API keys and tokens
    /// are passed inline: leading ones are environment for the command, and
    /// later ones are usually make/build variables carrying the same secrets.
    /// A leading `env` launcher goes too. Quoted words are left alone, so
    /// arguments such as `-k "name=x"` survive.
    private static func strippingEnvironment(_ words: [Word]) -> [Word] {
        var words = words[...]
        if words.first?.value == "env" { words = words.dropFirst() }
        return words.filter { !isAssignment($0.raw) }
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "=") else { return false }
        let name = word[..<equals].unicodeScalars
        guard let head = name.first, isNameHead(head) else { return false }
        return name.allSatisfy { isNameHead($0) || ("0"..."9").contains($0) }
    }

    private static func isNameHead(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func truncated(_ command: String) -> String {
        guard command.count > maximumCharacters else { return command }
        return String(command.prefix(maximumCharacters - 1)) + "…"
    }

    // MARK: Tokenizing

    /// A shell word: `raw` keeps the original quoting for display, `value`
    /// is the unquoted text used for matching.
    struct Word: Equatable {
        var raw: String
        var value: String
    }

    /// A deliberately small shell tokenizer: quotes, backslash escapes, and
    /// the control operators that separate simple commands. Redirections such
    /// as `2>&1` and `$(...)` substitutions stay inside their word. It is not
    /// a full shell parser; a misread only changes which segment is shown.
    static func segments(of command: String) -> [[Word]] {
        var segments: [[Word]] = []
        var current: [Word] = []
        var raw = ""
        var value = ""
        var inWord = false
        var substitutionDepth = 0

        func endWord() {
            if inWord { current.append(Word(raw: raw, value: value)) }
            raw = ""
            value = ""
            inWord = false
        }
        func endSegment() {
            endWord()
            if !current.isEmpty { segments.append(current) }
            current = []
        }

        let scalars = Array(command.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let next: Unicode.Scalar? = index + 1 < scalars.count ? scalars[index + 1] : nil
            switch scalar {
            case "'":
                // Single quotes are literal until the closing quote.
                inWord = true
                raw.unicodeScalars.append(scalar)
                index += 1
                while index < scalars.count, scalars[index] != "'" {
                    raw.unicodeScalars.append(scalars[index])
                    value.unicodeScalars.append(scalars[index])
                    index += 1
                }
                if index < scalars.count { raw.unicodeScalars.append(scalars[index]) }
            case "\"":
                inWord = true
                raw.unicodeScalars.append(scalar)
                index += 1
                while index < scalars.count, scalars[index] != "\"" {
                    if scalars[index] == "\\", index + 1 < scalars.count {
                        raw.unicodeScalars.append(scalars[index])
                        index += 1
                    }
                    raw.unicodeScalars.append(scalars[index])
                    value.unicodeScalars.append(scalars[index])
                    index += 1
                }
                if index < scalars.count { raw.unicodeScalars.append(scalars[index]) }
            case "\\":
                inWord = true
                if let next {
                    if next != "\n" {
                        raw.unicodeScalars.append(scalar)
                        raw.unicodeScalars.append(next)
                        value.unicodeScalars.append(next)
                    }
                    index += 1
                } else {
                    raw.unicodeScalars.append(scalar)
                }
            case " ", "\t":
                endWord()
            case "\n", "\r", ";":
                endSegment()
            case "|":
                endSegment()
                if next == "|" || next == "&" { index += 1 }
            case "&":
                if next == "&" {
                    endSegment()
                    index += 1
                } else if raw.hasSuffix(">") || raw.hasSuffix("<") || next == ">" {
                    inWord = true
                    raw.unicodeScalars.append(scalar)
                    value.unicodeScalars.append(scalar)
                } else {
                    endSegment()
                }
            case "(" where !inWord:
                endSegment()
            case ")" where substitutionDepth == 0:
                endSegment()
            default:
                inWord = true
                if scalar == "(", raw.hasSuffix("$") { substitutionDepth += 1 }
                if scalar == ")" { substitutionDepth -= 1 }
                raw.unicodeScalars.append(scalar)
                value.unicodeScalars.append(scalar)
            }
            index += 1
        }
        endSegment()
        return segments
    }
}
