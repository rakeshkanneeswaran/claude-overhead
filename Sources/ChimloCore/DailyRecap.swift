import Foundation

/// GitHub activity for the day, gathered by the caller. Plain counts so the
/// recap does not depend on how GitHub was queried.
public struct RecapGitHubInput: Equatable, Sendable {
    public var pullRequestsOpened: Int
    public var pullRequestsMerged: Int
    public var ciFailures: Int
    public var ciSuccesses: Int
    public var reviewsWaiting: Int

    public init(
        pullRequestsOpened: Int = 0,
        pullRequestsMerged: Int = 0,
        ciFailures: Int = 0,
        ciSuccesses: Int = 0,
        reviewsWaiting: Int = 0
    ) {
        self.pullRequestsOpened = pullRequestsOpened
        self.pullRequestsMerged = pullRequestsMerged
        self.ciFailures = ciFailures
        self.ciSuccesses = ciSuccesses
        self.reviewsWaiting = reviewsWaiting
    }

    public var hasActivity: Bool {
        pullRequestsOpened + pullRequestsMerged + ciFailures + ciSuccesses + reviewsWaiting > 0
    }
}

/// What happened on one calendar day. Highlights are factual sentences only:
/// no scores, streaks or praise, because the recap reports work rather than
/// judging it.
public struct DailyRecap: Equatable, Sendable {
    /// Start of the calendar day.
    public let day: Date
    public let sessionsCompleted: Int
    public let sessionsFailed: Int
    public let sessionsInterrupted: Int
    /// Display names, most recently active first.
    public let projects: [String]
    public let agentsUsed: Int
    /// Unique files across the day's sessions (per project).
    public let filesChanged: Int
    /// Nil when no session reported line counts.
    public let linesAdded: Int?
    public let linesRemoved: Int?
    /// Nil when no session reported a cost.
    public let costUSD: Double?
    public let github: RecapGitHubInput?
    public let highlights: [String]

    public init(
        day: Date,
        sessionsCompleted: Int,
        sessionsFailed: Int,
        sessionsInterrupted: Int,
        projects: [String],
        agentsUsed: Int,
        filesChanged: Int,
        linesAdded: Int?,
        linesRemoved: Int?,
        costUSD: Double?,
        github: RecapGitHubInput?,
        highlights: [String]
    ) {
        self.day = day
        self.sessionsCompleted = sessionsCompleted
        self.sessionsFailed = sessionsFailed
        self.sessionsInterrupted = sessionsInterrupted
        self.projects = projects
        self.agentsUsed = agentsUsed
        self.filesChanged = filesChanged
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.costUSD = costUSD
        self.github = github
        self.highlights = highlights
    }

    /// True when there is nothing to show: no session touched the day and
    /// GitHub reported no activity.
    public var isEmpty: Bool {
        projects.isEmpty && sessionsCompleted == 0 && sessionsFailed == 0 && sessionsInterrupted == 0
            && !(github?.hasActivity ?? false)
    }
}

public enum DailyRecapBuilder {
    /// A record belongs to the day when its active span
    /// (`startedAt`...`endedAt ?? lastActivityAt`) overlaps it. Outcome counts
    /// additionally require the session to have *ended* that day, so a session
    /// that finished after midnight counts as completed on the next day only.
    /// Line, file and cost totals are per session, not per day: a session that
    /// spans midnight contributes its totals to both days.
    public static func build(
        records: [SessionHistoryRecord],
        day: Date,
        calendar: Calendar = .current,
        github: RecapGitHubInput? = nil
    ) -> DailyRecap {
        let interval = calendar.dateInterval(of: .day, for: day)
            ?? DateInterval(start: calendar.startOfDay(for: day), duration: 86_400)
        let dayStart = interval.start
        let dayEnd = interval.end

        func isInDay(_ date: Date) -> Bool { date >= dayStart && date < dayEnd }

        let included = records
            .filter { record in
                let spanEnd = max(record.endedAt ?? record.lastActivityAt, record.lastActivityAt)
                return record.startedAt < dayEnd && spanEnd >= dayStart
            }
            .sorted(by: SessionHistoryOrdering.newestFirst)

        func endedInDay(_ record: SessionHistoryRecord, _ status: HistoryStatus) -> Bool {
            record.status == status && isInDay(record.endedAt ?? record.lastActivityAt)
        }
        let completed = included.filter { endedInDay($0, .completed) }
        let failed = included.filter { endedInDay($0, .failed) }
        let interrupted = included.filter { endedInDay($0, .interrupted) }

        let projects = projectNames(of: included)
        let completedProjects = projectNames(of: completed)

        var agentIDs = Set<String>()
        for record in included {
            for agent in record.agents where agent.startedAt.map(isInDay) ?? true {
                agentIDs.insert("\(record.id)/\(agent.id)")
            }
        }

        var files = Set<String>()
        for record in included {
            let key = ProjectPulseBuilder.projectKey(for: record)
            for path in record.filesChanged { files.insert("\(key)\u{0}\(path)") }
        }

        let linesAdded = sum(included.compactMap(\.linesAdded))
        let linesRemoved = sum(included.compactMap(\.linesRemoved))
        let costs = included.compactMap(\.costUSD)
        let costUSD: Double? = costs.isEmpty ? nil : costs.reduce(0, +)

        var highlights: [String] = []
        if !completed.isEmpty {
            let scope = completedProjects.count == 1
                ? "in \(completedProjects[0])"
                : "across \(HistoryFormatting.count(completedProjects.count, "project"))"
            highlights.append("Completed \(HistoryFormatting.count(completed.count, "session")) \(scope).")
        } else if !projects.isEmpty {
            let scope = projects.count == 1 ? "in \(projects[0])" : "across \(HistoryFormatting.count(projects.count, "project"))"
            highlights.append("Worked \(scope).")
        }
        if !failed.isEmpty {
            highlights.append("\(HistoryFormatting.count(failed.count, "session")) failed.")
        }
        if !interrupted.isEmpty {
            highlights.append("\(HistoryFormatting.count(interrupted.count, "session")) \(interrupted.count == 1 ? "was" : "were") interrupted.")
        }
        if !files.isEmpty {
            let counts = HistoryFormatting.lineCounts(added: linesAdded, removed: linesRemoved).map { " (\($0))" } ?? ""
            highlights.append("Changed \(HistoryFormatting.count(files.count, "file"))\(counts).")
        } else if let counts = HistoryFormatting.lineCounts(added: linesAdded, removed: linesRemoved) {
            highlights.append("Changed \(counts) lines.")
        }
        if !agentIDs.isEmpty {
            highlights.append("Ran \(HistoryFormatting.count(agentIDs.count, "agent")).")
        }
        if let github {
            if github.pullRequestsOpened > 0 {
                highlights.append("Opened \(HistoryFormatting.count(github.pullRequestsOpened, "pull request")).")
            }
            if github.pullRequestsMerged > 0 {
                highlights.append("Merged \(HistoryFormatting.count(github.pullRequestsMerged, "pull request")).")
            }
            if github.ciFailures > 0 {
                highlights.append("\(HistoryFormatting.count(github.ciFailures, "CI run")) failed.")
            }
            if github.ciSuccesses > 0 {
                highlights.append("\(HistoryFormatting.count(github.ciSuccesses, "CI run")) passed.")
            }
            if github.reviewsWaiting > 0 {
                let noun = HistoryFormatting.count(github.reviewsWaiting, "review")
                highlights.append("\(noun) \(github.reviewsWaiting == 1 ? "is" : "are") waiting.")
            }
        }
        if let costUSD, costUSD > 0 {
            highlights.append("Reported cost: \(HistoryFormatting.currency(costUSD)).")
        }

        return DailyRecap(
            day: dayStart,
            sessionsCompleted: completed.count,
            sessionsFailed: failed.count,
            sessionsInterrupted: interrupted.count,
            projects: projects,
            agentsUsed: agentIDs.count,
            filesChanged: files.count,
            linesAdded: linesAdded,
            linesRemoved: linesRemoved,
            costUSD: costUSD,
            github: github,
            highlights: highlights
        )
    }

    /// Unique display names in the input order (newest first), keyed by
    /// project so two checkouts that share a folder name stay distinct.
    private static func projectNames(of records: [SessionHistoryRecord]) -> [String] {
        let unique = HistoryMerge.union(records, key: ProjectPulseBuilder.projectKey(for:), merge: { old, _ in old })
        return unique.map { record in
            if !record.projectName.isEmpty { return record.projectName }
            return record.projectPath.map(HistorySearch.lastPathComponent(of:)) ?? "Unknown project"
        }
    }

    private static func sum(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : values.reduce(0, +)
    }
}
