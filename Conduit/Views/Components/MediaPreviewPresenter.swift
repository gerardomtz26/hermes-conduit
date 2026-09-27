//
//  MediaPreviewPresenter.swift
//  Conduit
//
//  Full-screen preview for chat media (#195): agent `MEDIA:` images, video,
//  audio and documents, web images, and the user's own attachments.
//
//  Presentation goes through Quick Look rather than a hand-rolled viewer:
//  QLPreviewController already gives pinch-to-zoom for images, playback for
//  video and audio, paged documents, a Done button, and the system share
//  sheet (Save Image / Save Video / Save to Files / Copy). It is presented
//  from UIKit by this singleton so transcript rows — which are Equatable-
//  gated and often inside lazy stacks — don't need presentation state of
//  their own; a row only has to hand over a local file or bytes.
//
//  Previewed bytes are written under a per-preview temporary directory that
//  keeps the original filename (the share sheet uses it as the saved name)
//  and is removed when the preview is dismissed. Files the user already had
//  on disk (local attachments) are previewed in place and never deleted.
//

import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What an inline `MEDIA:` path points at, decided from its extension.
enum GatewayMediaKind: Equatable {
    case image
    case video
    case audio
    case document

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "avi"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "ogg", "oga", "opus", "flac", "caf", "aiff"]
    static let documentExtensions: Set<String> = [
        "pdf", "txt", "md", "csv", "json", "rtf", "html",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers"
    ]

    /// Classifies a gateway path (optionally carrying a `?query`), or nil
    /// when the extension is not one Conduit renders as chat media.
    init?(path: String) {
        let withoutQuery = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        let ext = (withoutQuery as NSString).pathExtension.lowercased()
        if Self.imageExtensions.contains(ext) { self = .image }
        else if Self.videoExtensions.contains(ext) { self = .video }
        else if Self.audioExtensions.contains(ext) { self = .audio }
        else if Self.documentExtensions.contains(ext) { self = .document }
        else { return nil }
    }

    var systemImage: String {
        switch self {
        case .image: return "photo"
        case .video: return "play.rectangle.fill"
        case .audio: return "waveform"
        case .document: return "doc.fill"
        }
    }

    var label: String {
        switch self {
        case .image: return AppLocalization.string("Image")
        case .video: return AppLocalization.string("Video")
        case .audio: return AppLocalization.string("Audio")
        case .document: return AppLocalization.string("File")
        }
    }
}

@MainActor
final class MediaPreviewPresenter: NSObject {
    static let shared = MediaPreviewPresenter()

    private struct Item {
        let url: URL
        let title: String
        /// Temporary directory created for this preview, removed on dismiss.
        let ownedDirectory: URL?
    }

    private var item: Item?

    /// Previews a file already on disk (a local attachment). The file is
    /// left in place afterwards.
    func present(fileURL: URL, title: String? = nil) {
        show(Item(url: fileURL, title: title ?? fileURL.lastPathComponent, ownedDirectory: nil))
    }

    /// Previews in-memory bytes (a decoded gateway data URL or a download)
    /// under `filename`, so Save/Share keep the original name and type.
    @discardableResult
    func present(data: Data, filename: String) -> Bool {
        guard let staged = Self.stage(data: data, filename: filename) else { return false }
        show(Item(url: staged.file, title: staged.file.lastPathComponent, ownedDirectory: staged.directory))
        return true
    }

    /// Downloads a web image and previews it. Bounded by the same 16 MB
    /// ceiling as gateway media so a hostile URL can't exhaust memory.
    func presentRemote(url: URL, fallbackName: String) async -> Bool {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled,
                  !data.isEmpty,
                  data.count <= DataURLLimits.maxDecodedBytes,
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return false }
            let name = Self.filename(for: url, response: response, fallback: fallbackName)
            return present(data: data, filename: name)
        } catch {
            return false
        }
    }

    // MARK: - Presentation

    private func show(_ newItem: Item) {
        guard let presenter = Self.topViewController() else {
            Self.removeDirectory(newItem.ownedDirectory)
            return
        }
        if let previous = item { Self.removeDirectory(previous.ownedDirectory) }
        item = newItem
        let controller = QLPreviewController()
        controller.dataSource = self
        controller.delegate = self
        controller.modalPresentationStyle = .fullScreen
        presenter.present(controller, animated: true)
    }

    private func finish() {
        Self.removeDirectory(item?.ownedDirectory)
        item = nil
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    // MARK: - Staging

    nonisolated static let stagingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("Conduit-Media-Preview", isDirectory: true)

    /// Writes `data` to `<tmp>/Conduit-Media-Preview/<uuid>/<filename>`.
    nonisolated static func stage(data: Data, filename: String) -> (directory: URL, file: URL)? {
        let directory = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent(sanitizedFilename(filename))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return (directory, file)
        } catch {
            removeDirectory(directory)
            return nil
        }
    }

    /// Keeps the last path component of a gateway path or URL, stripped of
    /// separators and a query, so it is always a single safe file name.
    nonisolated static func sanitizedFilename(_ raw: String) -> String {
        let withoutQuery = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        let last = withoutQuery.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = last
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "media" }
        return cleaned
    }

    nonisolated static func filename(for url: URL, response: URLResponse?, fallback: String) -> String {
        let candidate = response?.suggestedFilename ?? url.lastPathComponent
        var name = sanitizedFilename(candidate.isEmpty ? fallback : candidate)
        if (name as NSString).pathExtension.isEmpty,
           let mime = response?.mimeType,
           let ext = UTType(mimeType: mime)?.preferredFilenameExtension {
            name += ".\(ext)"
        }
        return name
    }

    nonisolated static func removeDirectory(_ directory: URL?) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

extension MediaPreviewPresenter: QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        MainActor.assumeIsolated { item == nil ? 0 : 1 }
    }

    nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        MainActor.assumeIsolated {
            PreviewItem(url: item?.url, title: item?.title)
        }
    }

    nonisolated func previewControllerDidDismiss(_ controller: QLPreviewController) {
        MainActor.assumeIsolated { finish() }
    }

    nonisolated func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
        .disabled
    }
}

private final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL?, title: String?) {
        previewItemURL = url
        previewItemTitle = title
    }
}

/// Makes an inline media view open the full-screen preview on tap, and
/// tells VoiceOver it is a button that does so.
struct MediaPreviewTapModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Opens full screen with save and share"))
    }
}

extension View {
    func opensMediaPreview(_ action: @escaping () -> Void) -> some View {
        modifier(MediaPreviewTapModifier(action: action))
    }
}
