import AppKit
import EzNTFSCore
import SwiftUI

@MainActor
final class Lifecycle: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if case .normal = LaunchMode.current { AppModel.shared.startMonitoring() }
    }

    func showAboutPanel(language: AppLanguage) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 5
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        var link = body
        link[.link] = URL(string: "https://github.com/ixiehao")
        link[.foregroundColor] = NSColor.linkColor
        link[.underlineStyle] = NSUnderlineStyle.single.rawValue
        let credits = NSMutableAttributedString(string: language.text("about.description") + "\n" +
                                                language.text("about.developer") + " · ", attributes: body)
        credits.append(NSAttributedString(string: "ixiehao", attributes: link))
        credits.append(NSAttributedString(string: "\n\n" + language.text("about.local") + "\n" +
                                         language.text("about.license"), attributes: body))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        sender.setActivationPolicy(.accessory)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if LaunchMode.current.previewWindow != nil { return .terminateNow }
        return AppModel.shared.activity == nil ? .terminateNow : .terminateCancel
    }
}

@main
struct EzNTFSApp: App {
    @NSApplicationDelegateAdaptor(Lifecycle.self) private var lifecycle
    @StateObject private var model = LaunchMode.current.previewWindow.map { AppModel(preview: $0) } ?? .shared
    @Environment(\.openWindow) private var openWindow
    @State private var checkingForUpdates = false
    @State private var availableRelease: URL?

    init() {
        switch LaunchMode.current {
        case .normal, .previewWindow:
            return
        case .invalid:
            FileHandle.standardError.write(Data("ezNTFS: Invalid preview arguments.\n".utf8))
            exit(64)
        case let .render(path, sample, dark, narrow):
            Self.renderPreview(path: path, sample: sample, dark: dark, narrow: narrow)
        }
    }

    private static func renderPreview(path: String, sample: AppModel.Preview, dark: Bool, narrow: Bool) -> Never {
        let scheme: ColorScheme = dark ? .dark : .light
        let width: CGFloat = narrow ? 565 : 660
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        var rendered: Data?
        appearance?.performAsCurrentDrawingAppearance {
            let view = WorkspaceView(model: AppModel(preview: sample))
                .frame(width: width, height: 368)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.cgImage {
                rendered = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }
        }
        do {
            guard let rendered else { exit(1) }
            try rendered.write(to: URL(fileURLWithPath: path))
            exit(0)
        } catch {
            exit(1)
        }
    }

    var body: some Scene {
        Window("ezNTFS", id: "workspace") {
            WorkspaceView(model: model)
                .onAppear { NSApp.setActivationPolicy(.regular) }
        }
        .defaultSize(width: 660, height: 560)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(model.language.text("menu.about")) { lifecycle.showAboutPanel(language: model.language) }
            }
            CommandMenu(model.language.text("settings.language")) {
                Picker(model.language.text("settings.language"), selection: Binding(
                    get: { model.language }, set: model.setLanguage
                )) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(model.language.name(of: option)).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            CommandGroup(replacing: .help) {
                checkUpdatesButton
                Button(model.language.text("menu.dependencies")) {
                    showWorkspace()
                    model.openDependencyHealth()
                }
                viewReleaseButton
            }
        }

        MenuBarExtra {
            Button(model.language.text("menu.open"), action: showWorkspace)
            Divider()
            if model.disks.isEmpty {
                Text(model.language.text("menu.noVolumes"))
            }
            ForEach(model.disks) { disk in
                Menu(model.diskLabel(disk)) {
                    Button(model.language.text("disk.mount")) { model.startMount(diskID: disk.id) }
                        .disabled(!disk.canMountReadWrite || model.activity != nil)
                    Button(model.language.text("disk.eject")) { model.eject(diskID: disk.id) }
                        .disabled(model.activity != nil)
                }
            }
            Divider()
            checkUpdatesButton
            viewReleaseButton
            Button(model.language.text("menu.about")) { lifecycle.showAboutPanel(language: model.language) }
            Button(model.language.text("menu.quit")) { NSApp.terminate(nil) }
                .disabled(model.activity != nil)
        } label: {
            Image("menu-drive-mark", bundle: .main)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 19, height: 15)
                .accessibilityLabel("ezNTFS")
        }
        .menuBarExtraStyle(.menu)
    }

    private func showWorkspace() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "workspace")
        NSApp.activate(ignoringOtherApps: true)
    }

    private var checkUpdatesButton: some View {
        Button(model.language.text("update.check"), action: checkForUpdates)
            .disabled(checkingForUpdates)
    }

    @ViewBuilder private var viewReleaseButton: some View {
        if let availableRelease {
            Button(model.language.text("update.releasePage")) { NSWorkspace.shared.open(availableRelease) }
        }
    }

    private func checkForUpdates() {
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        Task { @MainActor in
            defer { checkingForUpdates = false }
            let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let result = await ReleaseCheck.latest(installedVersion: installedVersion)
            await presentUpdateResult(result, installedVersion: installedVersion)
        }
    }

    private func presentUpdateResult(_ result: ReleaseCheck, installedVersion: String) async {
        let language = model.language
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = language.text("update.title")
        let page: URL?
        switch result {
        case .updateAvailable(let version, let url):
            availableRelease = url
            alert.informativeText = language.text("update.available", version, installedVersion)
            alert.addButton(withTitle: language.text("update.releasePage"))
            alert.addButton(withTitle: language.text("update.later"))
            page = url
        case .upToDate:
            availableRelease = nil
            alert.informativeText = language.text("update.current", installedVersion)
            page = nil
        case .noPublicRelease:
            availableRelease = nil
            alert.informativeText = language.text("update.noRelease")
            page = nil
        case .rateLimited:
            alert.informativeText = language.text("update.rateLimited")
            page = nil
        case .offline:
            alert.informativeText = language.text("update.offline")
            page = nil
        case .unavailable:
            alert.informativeText = language.text("update.failed")
            page = nil
        }
        if page == nil { alert.addButton(withTitle: language.text("button.ok")) }
        let response: NSApplication.ModalResponse
        if let window = NSApp.mainWindow, window.isVisible, window.attachedSheet == nil {
            response = await alert.beginSheetModal(for: window)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            response = alert.runModal()
        }
        if response == .alertFirstButtonReturn, let page { NSWorkspace.shared.open(page) }
    }
}
