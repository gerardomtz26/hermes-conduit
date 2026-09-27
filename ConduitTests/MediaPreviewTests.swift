import XCTest
@testable import Conduit

/// #195: inline chat media opens full screen for save/share. These cover the
/// pure pieces — which `MEDIA:` lines render as media, and the file names a
/// preview is staged and shared under.
final class MediaPreviewTests: XCTestCase {

    // MARK: - MEDIA: recognition

    func testGatewayMediaPathStillRecognizesImages() {
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/out/result.png"), "/tmp/out/result.png")
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA:/tmp/a.JPEG?v=2"), "/tmp/a.JPEG?v=2")
    }

    func testGatewayMediaPathRecognizesVideoAudioAndDocuments() {
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/clip.mp4"), "/tmp/clip.mp4")
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/voice.ogg"), "/tmp/voice.ogg")
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/report.pdf"), "/tmp/report.pdf")
    }

    func testGatewayMediaPathRejectsUnknownExtensionsAndProse() {
        XCTAssertNil(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/archive.tar.gz"))
        XCTAssertNil(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/no-extension"))
        XCTAssertNil(MarkdownParser.gatewayMediaPath("MEDIA: see /tmp/clip.mp4 later"))
        XCTAssertNil(MarkdownParser.gatewayMediaPath("/tmp/clip.mp4"))
    }

    func testParsedVideoLineBecomesMediaBlockOnlyWhenGatewayMediaIsRecognized() {
        let source = "Here it is:\n\nMEDIA: /home/me/render.mov"
        let withGateway = MarkdownParser.parse(source, recognizesGatewayMedia: true)
        XCTAssertTrue(withGateway.contains { block in
            if case .image(let url, let alt) = block { return url == "MEDIA: /home/me/render.mov" && alt == "render.mov" }
            return false
        })
        let withoutGateway = MarkdownParser.parse(source, recognizesGatewayMedia: false)
        XCTAssertFalse(withoutGateway.contains { block in
            if case .image = block { return true }
            return false
        })
    }

    func testGatewayMediaKindClassifiesByExtension() {
        XCTAssertEqual(GatewayMediaKind(path: "/a/b.HEIC"), .image)
        XCTAssertEqual(GatewayMediaKind(path: "/a/b.mov"), .video)
        XCTAssertEqual(GatewayMediaKind(path: "/a/b.m4a?x=1"), .audio)
        XCTAssertEqual(GatewayMediaKind(path: "/a/b.docx"), .document)
        XCTAssertNil(GatewayMediaKind(path: "/a/b.exe"))
    }

    // MARK: - File naming

    func testSanitizedFilenameKeepsLastComponentWithoutQuery() {
        XCTAssertEqual(MediaPreviewPresenter.sanitizedFilename("/tmp/out/result.png?v=3"), "result.png")
        XCTAssertEqual(MediaPreviewPresenter.sanitizedFilename("C:\\renders\\clip.mp4"), "clip.mp4")
        XCTAssertEqual(MediaPreviewPresenter.sanitizedFilename("/tmp/.."), "media")
        XCTAssertEqual(MediaPreviewPresenter.sanitizedFilename(""), "media")
    }

    func testAttachmentPreviewFilenameBorrowsExtensionFromStoredPath() {
        XCTAssertEqual(AttachmentPreviewFilename.make(name: "Screenshot", uri: "/uploads/abc.png"), "Screenshot.png")
        XCTAssertEqual(AttachmentPreviewFilename.make(name: "photo.jpg", uri: "/uploads/abc.png"), "photo.jpg")
        XCTAssertEqual(AttachmentPreviewFilename.make(name: "  ", uri: "/uploads/abc.png"), "abc.png")
    }

    func testStageWritesBytesUnderOriginalNameInOwnDirectory() throws {
        let data = Data("hello".utf8)
        let staged = try XCTUnwrap(MediaPreviewPresenter.stage(data: data, filename: "/remote/dir/note.txt"))
        defer { MediaPreviewPresenter.removeDirectory(staged.directory) }
        XCTAssertEqual(staged.file.lastPathComponent, "note.txt")
        XCTAssertEqual(staged.file.deletingLastPathComponent().standardizedFileURL, staged.directory.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: staged.file), data)

        MediaPreviewPresenter.removeDirectory(staged.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.path))
    }
}
