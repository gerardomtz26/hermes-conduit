import Foundation

/// The durable identity of "the conversation the user was in".
///
/// A session id alone cannot express that identity. Hermes Bot Mode
/// conversations are ordinary gateway sessions living in the SAME id space as
/// the Sessions surface's: the client tells them apart with evidence that does
/// not survive a relaunch (the runtime-only `botChatSessionProfiles` registry,
/// a roster fetched seconds ago, the reserved wire title on a row the listing
/// may not even carry). Persisting the conversation's KIND and the profile
/// scope its RPCs must ride is what lets background→foreground, cold launch,
/// reconnect, and workspace switching land back in the exact conversation, on
/// the exact surface, instead of resolving an id as "some conversation of this
/// workspace".
struct SessionReference: Codable, Equatable {
    /// Which surface's conversation this is. The kind decides how the
    /// reference may be restored — never the id.
    enum Kind: String, Codable {
        /// A conversation of the dashboard workspace's Sessions surface.
        case dashboard
        /// A bot's canonical Bot Chat. Reachable only through the Bots roster,
        /// resumed against the BOT's profile, and never part of the Sessions
        /// surface's selection or its "latest activity" fallback.
        case bot
    }

    let kind: Kind
    /// The profile the conversation's RPCs ride: the workspace profile for
    /// `.dashboard`, the bot's profile for `.bot`.
    let scopeProfile: String
    /// The bot this conversation belongs to (`.bot` only). Today it equals
    /// `scopeProfile`; it stays a separate field so a future Bot Mode address
    /// (group chats, rooms) can name a member without redefining the scope the
    /// conversation's RPCs ride.
    let botName: String?
    /// The bot's display label at the time the conversation was opened, so a
    /// restored Bot Chat presents the bot's name immediately instead of the
    /// dashboard profile's generic title. Never the wire title (which is the
    /// reserved identity, not a user-facing string).
    let botLabel: String?
    /// The session identity to resume. For a `.bot` conversation this is the
    /// canonical chat's registry row (or a lineage tip of it).
    let sessionID: String

    /// A conversation of the dashboard workspace's Sessions surface.
    static func dashboard(profile: String, sessionID: String) -> SessionReference {
        SessionReference(
            kind: .dashboard,
            scopeProfile: profile,
            botName: nil,
            botLabel: nil,
            sessionID: sessionID
        )
    }

    /// A bot's canonical Bot Chat, scoped to the bot's own profile.
    static func bot(
        botName: String,
        label: String? = nil,
        sessionID: String
    ) -> SessionReference {
        SessionReference(
            kind: .bot,
            scopeProfile: botName,
            botName: botName,
            botLabel: label,
            sessionID: sessionID
        )
    }

    /// The profile scope to address this conversation's RPCs with, or nil for
    /// the dashboard workspace's own scope.
    var resumeProfileScope: String? {
        kind == .bot ? scopeProfile : nil
    }

}

/// Decides whether a conversation is Bot Mode owned, from every signal the
/// client has at the moment of the decision.
///
/// Kept as one value so the restore path and the sessions-list hygiene read the
/// SAME evidence: a conversation is bot-owned when this process's bot-chat
/// registry knows any of its ids, or when the roster positively names it as a
/// bot's canonical chat (the registry row OR the lineage tip a compaction moved
/// the conversation to).
struct SessionBotOwnership {
    /// The roster this evidence was captured from — needed to name the owning
    /// bot, not just to decide ownership.
    private let roster: [BotProfile]
    /// This process's bot-chat registry: canonical chat id → the BOT profile
    /// its RPCs ride. The authoritative answer for a conversation this process
    /// has opened, independent of whether a roster is loaded.
    private let registryProfiles: [String: String]
    private let rosterCanonicalIDs: Set<String>

    init(roster: [BotProfile], registryProfiles: [String: String]) {
        var canonicalIDs = Set<String>()
        for bot in roster {
            for id in [bot.canonicalSession?.id, bot.canonicalSession?.resolvedID] {
                guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !id.isEmpty else { continue }
                canonicalIDs.insert(id)
            }
        }
        self.roster = roster
        self.registryProfiles = registryProfiles.reduce(into: [:]) { result, entry in
            guard let id = SessionBotOwnership.normalized(entry.key),
                  let profile = SessionBotOwnership.normalized(entry.value) else { return }
            result[id] = profile
        }
        self.rosterCanonicalIDs = canonicalIDs
    }

    /// Every id this evidence positively attributes to a Bot Mode
    /// conversation. Consumers (the resume resolver's selection guard, the
    /// sessions-list projection) use this instead of re-deriving the rule.
    var botOwnedIDs: Set<String> {
        rosterCanonicalIDs.union(registryProfiles.keys)
    }

    var isEmpty: Bool {
        rosterCanonicalIDs.isEmpty && registryProfiles.isEmpty
    }

    /// The bot profile this name matches, and whether the match was spelled
    /// exactly. Refusal folds case (see `ownsProfile`), so the caller can tell
    /// "this IS that bot's profile" from "this only matches with different
    /// casing" — the second case may be an unrelated workspace.
    func botProfileMatch(for profile: String) -> (name: String, isExact: Bool)? {
        guard let normalized = SessionBotOwnership.normalized(profile) else { return nil }
        if let rosterName = roster.first(where: {
            $0.name.caseInsensitiveCompare(normalized) == .orderedSame
        })?.name {
            return (rosterName, rosterName == normalized)
        }
        if let registryName = registryProfiles.values.first(where: {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return (registryName, registryName == normalized)
        }
        return nil
    }

    /// Whether this profile is a bot's own profile — not a workspace the
    /// dashboard may adopt. Bots are ordinary Hermes profiles, so nothing but
    /// bot evidence distinguishes "switch the workspace to `Atlas`" from
    /// "open Atlas's Bot Chat": the roster names every bot, and the runtime
    /// registry names the profiles known Bot Chats already ride (which is the
    /// only evidence available while the roster is empty or unloaded).
    func ownsProfile(_ profile: String) -> Bool {
        let normalized = SessionBotOwnership.normalized(profile)
        guard let normalized else { return false }
        if roster.contains(where: { $0.name.caseInsensitiveCompare(normalized) == .orderedSame }) {
            return true
        }
        return registryProfiles.values.contains {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        }
    }


    /// The roster entry owning this conversation, when the roster names it.
    func bot(owning sessionID: String?) -> BotProfile? {
        guard let sessionID = SessionBotOwnership.normalized(sessionID) else { return nil }
        return bot(owningAny: [sessionID])
    }

    /// The roster entry owning the conversation when ANY of its identities is
    /// a bot's canonical chat. A conversation answers to several ids (the
    /// runtime id a resume minted, the durable row, its aliases); judging by a
    /// single one would misread a rotated-runtime Bot Chat as ordinary.
    func bot(owningAny sessionIDs: Set<String>) -> BotProfile? {
        let ids = Set(sessionIDs.compactMap(SessionBotOwnership.normalized))
        guard !ids.isEmpty else { return nil }
        return roster.first { bot in
            let canonical = [bot.canonicalSession?.id, bot.canonicalSession?.resolvedID]
            return canonical.contains { id in
                guard let id = SessionBotOwnership.normalized(id) else { return false }
                return ids.contains(id)
            }
        }
    }

    /// The BOT PROFILE the conversation's RPCs must ride: the ROSTER first
    /// (its `bot.name` is the server's verbatim spelling, and a scope
    /// persisted by an earlier build may be case-folded), then this process's
    /// registry (which also covers a runtime id the roster does not name, such
    /// as a lineage tip). Nil when nothing attributes the conversation to a
    /// bot.
    func botProfileName(owningAny sessionIDs: Set<String>) -> String? {
        let ids = Set(sessionIDs.compactMap(SessionBotOwnership.normalized))
        guard !ids.isEmpty else { return nil }
        // The ROSTER first: it is the server's own spelling of the profile a
        // Bot Chat's RPCs must ride (`bot.name` verbatim), and a scope
        // persisted by an earlier build was case-folded. The registry is the
        // fallback — it is keyed by EVERY id the conversation has ever
        // answered to, so a rotated runtime id still resolves.
        if let rosterName = bot(owningAny: ids)?.name { return rosterName }
        for id in ids.sorted() {
            if let profile = registryProfiles[id] { return profile }
        }
        return nil
    }

    /// The reference AS a Bot Mode reference when this evidence attributes any
    /// of the conversation's identities to a Bot Chat — the healing path for a
    /// reference recorded before the kind existed, and for one recorded while
    /// the roster was still loading. It runs in exactly one direction:
    /// ordinary → bot, on positive evidence.
    ///
    /// `aliases` are the conversation's other known identities (a rotated
    /// runtime id, a lineage tip, a scroll-identity alias). Judging by the
    /// stored id alone would miss a conversation whose only bot evidence is
    /// the alias a rebind registered — the exact shape this fix exists for.
    func referenceIfBot(
        _ reference: SessionReference?,
        aliases: Set<String> = []
    ) -> SessionReference? {
        guard let reference else { return nil }
        guard reference.kind != .bot else { return reference }
        let ids: Set<String> = [reference.sessionID].reduce(into: aliases) { $0.insert($1) }
        guard let profile = botProfileName(owningAny: ids) else { return nil }
        return .bot(
            botName: profile,
            label: bot(owningAny: ids)?.displayLabel,
            sessionID: reference.sessionID
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
