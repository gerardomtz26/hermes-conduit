//
//  OfflineChatCache.swift
//  Conduit
//
//  Read-only on-disk copy of recently opened conversations (#99), so a cold
//  launch (after iOS reclaimed the process, or with the server unreachable)
//  can still show the last chat.
//
//  The copy is PRESENTATION ONLY. It never enters `AppState.messages` or
//  `AppState.sessions`, so nothing that decides resume, pagination,
//  conversation selection, bot-vs-workspace routing, or pending
//  approval/clarify cards can read it. The first authoritative answer from
//  the server replaces it wholesale.
//

import Foundation

/// One persisted transcript row. Only the fields the read-only transcript
/// renders; interactive rows (approval/clarify cards, streaming partials)
/// are never stored.
struct OfflineCachedMessage: Codable, Equatable {
    let id: String
    let role: MessageRole
    let content: String
    let timestamp: String
    let author: String?
    let reasoning: String?
    let tool: ToolActivity?
    let displayKind: String?

    static let storableRoles: Set<MessageRole> = [.user, .assistant, .reasoning, .system, .tool]

    init?(_ message: ChatMessage) {
        guard Self.storableRoles.contains(message.role) else { return nil }
        id = message.id
        role = message.role
        content = message.content
        timestamp = message.timestamp
        author = message.author
        reasoning = message.reasoning
        tool = message.tool
        displayKind = message.displayKind
    }

    var chatMessage: ChatMessage {
        ChatMessage(
            id: id,
            role: role,
            content: content,
            timestamp: timestamp,
            author: author,
            reasoning: reasoning,
            tool: tool,
            displayKind: displayKind
        )
    }
}

struct OfflineCachedSession: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let updatedLabel: String
    let lastActivityAt: TimeInterval?
    let source: SessionSource

    init(id: String, title: String, updatedLabel: String, lastActivityAt: TimeInterval?, source: SessionSource) {
        self.id = id
        self.title = title
        self.updatedLabel = updatedLabel
        self.lastActivityAt = lastActivityAt
        self.source = source
    }

    init(_ summary: SessionSummary) {
        id = summary.storedSessionId ?? summary.id
        title = summary.title
        updatedLabel = summary.updatedLabel
        lastActivityAt = summary.lastActivityAt
        source = summary.source
    }
}

struct OfflineCachedTranscript: Codable, Equatable {
    let sessionID: String
    let title: String
    let savedAt: Date
    let messages: [OfflineCachedMessage]
}

/// Everything cached for one (dashboard, profile) scope.
struct OfflineChatSnapshot: Codable, Equatable {
    static let formatVersion = 1

    var version: Int = Self.formatVersion
    var lastSessionID: String?
    var sessions: [OfflineCachedSession]
    /// Most recently opened first.
    var transcripts: [OfflineCachedTranscript]

    func transcript(for sessionID: String) -> OfflineCachedTranscript? {
        transcripts.first { $0.sessionID == sessionID }
    }
}

/// What the chat surface presents while the server has not answered yet.
struct OfflineChatPresentation: Equatable {
    let dashboardID: UUID
    let profile: String
    let snapshot: OfflineChatSnapshot
    var displayedSessionID: String?

    var displayedTranscript: OfflineCachedTranscript? {
        displayedSessionID.flatMap(snapshot.transcript(for:))
    }

    var displayedMessages: [ChatMessage] {
        displayedTranscript?.messages.map(\.chatMessage) ?? []
    }
}

/// File-backed store. One JSON file per (dashboard, profile), written
/// atomically with complete-until-first-user-authentication protection and
/// excluded from backups.
final class OfflineChatCacheStore {
    static let maxMessagesPerTranscript = 120
    static let maxTranscripts = 5
    static let maxSessions = 60

    /// Complete-until-first-user-authentication: unreadable from a device
    /// that has not been unlocked since boot, while still writable at the
    /// background transition after the device locks.
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("OfflineChatCache", isDirectory: true)
    }

    func load(dashboardID: UUID, profile: String) -> OfflineChatSnapshot? {
        let url = fileURL(dashboardID: dashboardID, profile: profile)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(OfflineChatSnapshot.self, from: data),
              snapshot.version == OfflineChatSnapshot.formatVersion else {
            return nil
        }
        return snapshot
    }

    /// Records the newest page of `messages` for `sessionID` (moved to the
    /// front of the recent list) together with the current session list.
    /// An empty storable transcript records nothing for that session.
    func record(
        dashboardID: UUID,
        profile: String,
        sessionID: String,
        title: String,
        messages: [ChatMessage],
        sessions: [SessionSummary],
        now: Date = Date()
    ) {
        let rows = messages.compactMap(OfflineCachedMessage.init)
            .suffix(Self.maxMessagesPerTranscript)
        guard !rows.isEmpty else { return }
        var snapshot = load(dashboardID: dashboardID, profile: profile)
            ?? OfflineChatSnapshot(lastSessionID: nil, sessions: [], transcripts: [])
        snapshot.transcripts.removeAll { $0.sessionID == sessionID }
        snapshot.transcripts.insert(
            OfflineCachedTranscript(sessionID: sessionID, title: title, savedAt: now, messages: Array(rows)),
            at: 0
        )
        snapshot.transcripts = Array(snapshot.transcripts.prefix(Self.maxTranscripts))
        snapshot.lastSessionID = sessionID
        let catalog = sessions.filter { $0.source != .cron && !$0.isArchived }
        if !catalog.isEmpty {
            snapshot.sessions = Array(catalog.prefix(Self.maxSessions).map(OfflineCachedSession.init))
        }
        write(snapshot, dashboardID: dashboardID, profile: profile)
    }

    func removeDashboard(_ dashboardID: UUID) {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        let prefix = dashboardID.uuidString.lowercased() + "--"
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: file)
        }
    }

    func removeAll() {
        try? fileManager.removeItem(at: directory)
    }

    private func write(_ snapshot: OfflineChatSnapshot, dashboardID: UUID, profile: String) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var directoryURL = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directoryURL.setResourceValues(values)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(
                to: fileURL(dashboardID: dashboardID, profile: profile),
                options: Self.writeOptions
            )
        } catch {
            // Best effort: the cache is a convenience copy, never a source of
            // truth, so a failed write only means a colder next launch.
        }
    }

    func fileURL(dashboardID: UUID, profile: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeProfile = profile.addingPercentEncoding(withAllowedCharacters: allowed) ?? "default"
        return directory.appendingPathComponent(
            "\(dashboardID.uuidString.lowercased())--\(safeProfile).json"
        )
    }
}
