import AppKit
import ApplicationServices
import EzNTFSCore
import Testing

@Suite(.serialized)
struct MediaBrowsingImageTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZNTFS_TEST_MEDIA_BROWSING"] == "1"))
    func finderListsAllMediaDuringPlaybackAndImageViewing() async throws {
        try await runMediaBrowsing(stress: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZNTFS_TEST_MEDIA_STRESS"] == "1"))
    func finderListsLargeMediaDirectoryOnFirstVisitDuring4KPlayback() async throws {
        try await runMediaBrowsing(stress: true)
    }

    private func runMediaBrowsing(stress: Bool) async throws {
        let environment = ProcessInfo.processInfo.environment
        let ffmpeg = try #require(environment["EZNTFS_TEST_FFMPEG"], "Set EZNTFS_TEST_FFMPEG to an absolute path.")
        let mkntfs = try #require(environment["EZNTFS_TEST_MKNTFS"], "Set EZNTFS_TEST_MKNTFS to an absolute path.")
        try #require(ffmpeg.hasPrefix("/") && mkntfs.hasPrefix("/"))
        try #require(AXIsProcessTrusted(), "Allow Accessibility for the terminal running the desktop test.")

        let fs = FileManager.default
        let token = UUID().uuidString.prefix(8)
        let base = try canonicalPath(fs.temporaryDirectory.path)
        let root = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("ezntfs-media-\(token)")
        let image = root.appendingPathComponent("test.img")
        let mount = root.appendingPathComponent("mount")
        try fs.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var backing: MountedDisk?
        defer {
            do {
                if let backing { try unmountTestImage(image, at: mount, backing: backing) }
                try fs.removeItem(at: root)
            } catch {
                Issue.record("Temporary image cleanup failed at \(root.path): \(error.localizedDescription)")
            }
        }

        try Self.command("/usr/bin/truncate", ["-s", stress ? "1g" : "512m", image.path])
        try Self.command(mkntfs, ["-F", "-Q", "-s", "512", "-L", "EZNTFS-MEDIA-QA", image.path])
        let backingMount = try MountedDisk.at(root.path)
        try fs.createDirectory(at: mount, withIntermediateDirectories: false)
        backing = backingMount
        func attach() throws {
            try Mounting.mountImage(source: image.path, destination: mount, label: "EZNTFS-MEDIA-QA",
                                    driver: environment["EZNTFS_TEST_DRIVER"])
        }
        try attach()
        let media = mount.appendingPathComponent("Media-\(token)")
        let outside = mount.appendingPathComponent("Outside-\(token)")
        for folder in [media, outside] { try fs.createDirectory(at: folder, withIntermediateDirectories: false) }

        let photo = media.appendingPathComponent("photo-open-\(token).jpg")
        let movie = media.appendingPathComponent("video-play-\(token).mp4")
        let expected: [String]
        if stress {
            expected = try Self.makeStressMedia(ffmpeg: ffmpeg, in: media, photo: photo, movie: movie,
                                                seed: root.appendingPathComponent("seed.mp4"))
            // Start the first Finder visit on a new mount, after staging the fixtures.
            try unmountTestImage(image, at: mount, backing: backingMount)
            try attach()
        } else {
            expected = try Self.makeMedia(ffmpeg: ffmpeg, in: media, photo: photo, movie: movie)
        }

        let windowID = try Self.appleScript("""
            tell application "Finder"
                set testFolder to POSIX file (item 1 of argv) as alias
                set testWindow to make new Finder window to testFolder
                set statusbar visible of testWindow to true
                return id of testWindow
            end tell
            """, [outside.path])
        defer {
            do {
                try Self.appleScript("""
                    tell application "Finder"
                        if exists Finder window id (item 1 of argv as integer) then ¬
                            close Finder window id (item 1 of argv as integer)
                    end tell
                    """, [windowID])
            } catch { Issue.record("Could not close the test Finder window: \(error.localizedDescription)") }
        }

        // Play before the first visit so Finder has to populate the list and thumbnails during playback.
        let rounds = stress ? 3 : 8
        let timeout = stress ? 15 : 3
        try await Self.withPlayingMovie(movie) {
            try await Self.browse("video", rounds: rounds, windowID: windowID, media: media,
                                  outside: outside, expected: expected, timeout: timeout)
        }
        try await Self.withOpenPhoto(photo) {
            try await Self.browse("photo", rounds: rounds, windowID: windowID, media: media,
                                  outside: outside, expected: expected, timeout: timeout)
        }
        try await Self.browse("closed", rounds: stress ? 1 : 3, windowID: windowID, media: media,
                              outside: outside, expected: expected, timeout: timeout)
    }

    private static func makeMedia(ffmpeg: String, in folder: URL, photo: URL, movie: URL) throws -> [String] {
        let flags = ["-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i"]
        let encoding = ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-threads", "2"]
        let files = FileManager.default
        try command(ffmpeg, flags + ["testsrc2=size=960x540:rate=12", "-frames:v", "360", "-q:v", "3",
                                     folder.appendingPathComponent("photo-%03d.jpg").path], timeout: 90)
        try files.moveItem(at: folder.appendingPathComponent("photo-001.jpg"), to: photo)
        try command(ffmpeg, flags + ["testsrc2=size=320x180:rate=12", "-t", "238"] + encoding
                    + ["-g", "24", "-sc_threshold", "0", "-f", "segment", "-segment_time", "2", "-reset_timestamps", "1",
                       "-segment_start_number", "1", folder.appendingPathComponent("video-%03d.mp4").path], timeout: 90)
        try command(ffmpeg, flags + ["testsrc2=size=1280x720:rate=30", "-t", "45"] + encoding
                    + ["-movflags", "+faststart", movie.path], timeout: 90)
        let photos = (2...360).map { String(format: "photo-%03d.jpg", $0) } + [photo.lastPathComponent]
        let videos = (1...119).map { String(format: "video-%03d.mp4", $0) } + [movie.lastPathComponent]
        return (photos + videos).sorted()
    }

    private static func makeStressMedia(ffmpeg: String, in folder: URL, photo: URL, movie: URL,
                                        seed: URL) throws -> [String] {
        let flags = ["-hide_banner", "-loglevel", "error", "-nostdin"]
        try command(ffmpeg, flags + ["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24",
                                     "-frames:v", "3072", "-q:v", "3", "-threads", "4",
                                     folder.appendingPathComponent("photo-%04d.jpg").path], timeout: 300)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("photo-0001.jpg"), to: photo)
        try command(ffmpeg, flags + ["-f", "lavfi", "-i", "testsrc2=size=3840x2160:rate=24",
                                     "-t", "8", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                                     "-threads", "6", "-b:v", "44M", "-minrate", "44M", "-maxrate", "44M",
                                     "-bufsize", "44M", "-x264-params", "nal-hrd=cbr:force-cfr=1",
                                     "-g", "24", "-sc_threshold", "0", seed.path], timeout: 120)
        try command(ffmpeg, flags + ["-stream_loop", "7", "-i", seed.path, "-t", "60",
                                     "-c", "copy", "-movflags", "+faststart", movie.path], timeout: 120)
        let photos = (2...3072).map { String(format: "photo-%04d.jpg", $0) } + [photo.lastPathComponent]
        return (photos + [movie.lastPathComponent]).sorted()
    }

    private static func browse(_ phase: String, rounds: Int, windowID: String, media: URL, outside: URL,
                               expected: [String], timeout: Int) async throws {
        for round in 1...rounds {
            try navigate(windowID, to: outside)
            _ = try await waitForRows(in: outside, expected: 0, since: .now(), timeout: timeout)
            let start = DispatchTime.now()
            async let terminal = Result { try terminalListing(media, timeout: timeout) }
            let finder: (minimum: Int, elapsed: TimeInterval)
            do {
                try navigate(windowID, to: media, showPreviews: phase == "video" && round == 1)
                finder = try await waitForRows(in: media, expected: expected.count, since: start, timeout: timeout)
            } catch {
                let result = await terminal
                let listing = result.map { "\($0.0.count) files in \($0.1), expected names match: \($0.0 == expected)" }
                throw EZError("\(phase) \(round): \(error.localizedDescription); ls: \(listing)")
            }
            let (names, terminalTime) = try await terminal.get()
            #expect(names == expected, "\(phase) \(round): terminal list differs from the fixture manifest.")
            try await Task.sleep(nanoseconds: 350_000_000)
            let settled = finderRows(in: media)
            #expect(settled == expected.count, "\(phase) \(round): Finder list became incomplete after loading.")
            let status = finderStatus(in: media)
            print("\(phase) \(round): Finder min=\(finder.minimum), settled=\(settled ?? -1), full=\(finder.elapsed); status=\(status ?? "unavailable"); ls=\(names.count), time=\(terminalTime)")
        }
    }

    private static func terminalListing(_ folder: URL, timeout: Int) throws -> ([String], TimeInterval) {
        let start = DispatchTime.now()
        let output = try command("/bin/ls", ["-1", folder.path], timeout: TimeInterval(timeout))
        return (output.split(separator: "\n").map(String.init).sorted(), elapsed(since: start))
    }

    private static func navigate(_ windowID: String, to folder: URL, showPreviews: Bool = false) throws {
        try appleScript("""
            tell application "Finder"
                set testFolder to POSIX file (item 2 of argv) as alias
                set testWindow to Finder window id (item 1 of argv as integer)
                set target of testWindow to testFolder
                set current view of testWindow to list view
                if item 3 of argv is "true" then set shows icon preview of list view options of testWindow to true
            end tell
            """, [windowID, folder.path, String(showPreviews)])
    }

    private static func waitForRows(in folder: URL, expected: Int, since start: DispatchTime, timeout: Int) async throws
        -> (minimum: Int, elapsed: TimeInterval) {
        var minimum: Int?
        var latest: Int?
        while DispatchTime.now() < start + .seconds(timeout) {
            if let count = finderRows(in: folder) {
                minimum = min(minimum ?? count, count)
                latest = count
                if count == expected { return (minimum ?? count, elapsed(since: start)) }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let detail = finderStatus(in: folder) ?? "unavailable"
        throw EZError("Finder did not show \(expected) rows in \(timeout) s (last count: \(latest.map(String.init) ?? "unavailable"); status: \(detail)).")
    }

    private static func elapsed(since start: DispatchTime) -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    }

    private static func finderRows(in folder: URL) -> Int? {
        guard let window = window(of: "com.apple.finder", named: folder.lastPathComponent),
              let list = listView(in: window) else { return nil }
        var count = 0
        guard AXUIElementGetAttributeValueCount(list, kAXRowsAttribute as CFString, &count) == .success else { return nil }
        return count
    }

    private static func listView(in element: AXUIElement) -> AXUIElement? {
        if attribute(element, kAXIdentifierAttribute) as? String == "ListView" { return element }
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.lazy.compactMap { listView(in: $0) }.first
    }

    private static func finderStatus(in folder: URL) -> String? {
        guard let element = window(of: "com.apple.finder", named: folder.lastPathComponent) else { return nil }
        func status(_ node: AXUIElement) -> String? {
            if attribute(node, kAXIdentifierAttribute) as? String == "statusBarText" {
                return attribute(node, kAXValueAttribute) as? String
            }
            let role = attribute(node, kAXRoleAttribute) as? String
            if role == "AXOutline" || role == "AXToolbar" { return nil }
            let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            return children.lazy.compactMap { status($0) }.first
        }
        return status(element)
    }

    private static func window(of appID: String, named title: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.75)
        let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.first { attribute($0, kAXTitleAttribute) as? String == title }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func withPlayingMovie(_ movie: URL, check: () async throws -> Void) async throws {
        let title = movie.deletingPathExtension().lastPathComponent
        defer {
            do {
                try appleScript("""
                    tell application "QuickTime Player"
                        set testMovies to documents whose name is item 1 of argv or name is item 2 of argv
                        repeat with testMovie in testMovies
                            close testMovie saving no
                        end repeat
                    end tell
                    """, [title, movie.lastPathComponent])
            } catch { Issue.record("Could not close the test video: \(error.localizedDescription)") }
        }
        try appleScript("""
            tell application "QuickTime Player"
                set testFile to POSIX file (item 1 of argv) as alias
                set testMovie to open testFile
                set looping of testMovie to true
                play testMovie
            end tell
            """, [movie.path])
        try await Task.sleep(nanoseconds: 600_000_000)
        func playbackTime() throws -> Double {
            let output = try appleScript("""
                tell application "QuickTime Player"
                    set testMovie to first document whose name is item 1 of argv or name is item 2 of argv
                    if not playing of testMovie then error "The test movie is not playing."
                    return current time of testMovie
                end tell
                """, [title, movie.lastPathComponent])
            return try #require(Double(output.replacingOccurrences(of: ",", with: ".")))
        }
        let before = try playbackTime()
        try await check()
        let after = try playbackTime()
        #expect(before > 0 && abs(after - before) > 0.5, "QuickTime playback did not advance during browsing.")
        print("QuickTime playback position: \(before) s → \(after) s")
    }

    private static func withOpenPhoto(_ photo: URL, check: () async throws -> Void) async throws {
        let appID = "com.apple.Preview"
        func photoWindow() -> AXUIElement? {
            window(of: appID, named: photo.deletingPathExtension().lastPathComponent)
                ?? window(of: appID, named: photo.lastPathComponent)
        }
        defer {
            if let testWindow = photoWindow() {
                let buttons = attribute(testWindow, kAXChildrenAttribute) as? [AXUIElement] ?? []
                let close = buttons.first { attribute($0, kAXSubroleAttribute) as? String == kAXCloseButtonSubrole }
                if close.map({ AXUIElementPerformAction($0, kAXPressAction as CFString) }) != .success {
                    Issue.record("Could not close the test photo.")
                }
            }
        }
        try command("/usr/bin/open", ["-g", "-b", appID, photo.path])
        let deadline = DispatchTime.now() + .seconds(8)
        while photoWindow() == nil && DispatchTime.now() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try #require(photoWindow() != nil, "Preview did not open the test photo.")
        try await check()
        #expect(photoWindow() != nil, "Preview closed the test photo during browsing.")
    }

    @discardableResult
    private static func appleScript(_ body: String, _ arguments: [String]) throws -> String {
        let source = "on run argv\nwith timeout of 6 seconds\n\(body)\nend timeout\nend run"
        return try command("/usr/bin/osascript", ["-e", source] + arguments)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private static func command(_ path: String, _ arguments: [String], timeout: TimeInterval = 8) throws -> String {
        String(decoding: try Tool.run(path, arguments, queryTimeout: timeout), as: UTF8.self)
    }
}
