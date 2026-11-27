import AppKit
import EzNTFSCore
import SwiftUI

@MainActor
class Lifecycle: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if case .normal = LaunchMode.current { AppModel.shared.startMonitoring() }
        if LaunchMode.current.isSetup { AppModel.shared.startSetup() }
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
        let credits = NSMutableAttributedString(string: language.text("about.description") + "\n" +
                                                language.text("about.developer") + " · ", attributes: body)
        func appendLink(_ title: String, to url: URL) {
            var link = body
            link[.link] = url
            link[.foregroundColor] = NSColor.linkColor
            link[.underlineStyle] = NSUnderlineStyle.single.rawValue
            credits.append(NSAttributedString(string: title, attributes: link))
        }
        let site = URL(string: "https://ixiehao.github.io/ezNTFS/")!
        let website: URL = switch language.locale.identifier {
        case "zh-Hans": site.appendingPathComponent("zh", isDirectory: true)
        case "ja": site.appendingPathComponent("ja", isDirectory: true)
        default: site
        }
        let project = ReleaseCheck.projectPage
        appendLink("ixiehao", to: project.deletingLastPathComponent())
        credits.append(NSAttributedString(string: "\n\n" + language.text("about.local") + "\n", attributes: body))
        appendLink(language.text("about.license"), to: project.appendingPathComponent("blob/main/LICENSE"))
        credits.append(NSAttributedString(string: "\n\n", attributes: body))
        appendLink(language.text("about.website"), to: website)
        credits.append(NSAttributedString(string: "  ·  ", attributes: body))
        appendLink(language.text("about.source"), to: project)
        credits.append(NSAttributedString(string: "  ·  ", attributes: body))
        appendLink(language.text("about.feedback"), to: project.appendingPathComponent("issues"))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if LaunchMode.current.isSetup { return true }
        sender.setActivationPolicy(.accessory)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if LaunchMode.current.previewWindow != nil { return .terminateNow }
        return AppModel.shared.activity == nil ? .terminateNow : .terminateCancel
    }
}

@main
@MainActor
enum AppEntry {
    static func main() {
        #if !EZNTFS_MONTEREY_PREVIEW && !EZNTFS_MONTEREY
        if #available(macOS 13.0, *) {
            EzNTFSApp.main()
            return
        }
        #endif
        LegacyApplication.run()
    }
}

@available(macOS 13.0, *)
struct EzNTFSApp: App {
    @NSApplicationDelegateAdaptor(Lifecycle.self) private var lifecycle
    @StateObject private var model = LaunchMode.current.previewWindow.map { AppModel(preview: $0) } ?? .shared
    @Environment(\.openWindow) private var openWindow
    @StateObject private var updates = AppUpdates()

    init() {
        switch LaunchMode.current {
        case .normal, .previewWindow, .setup:
            return
        case .invalid:
            FileHandle.standardError.write(Data("ezNTFS: Invalid preview arguments.\n".utf8))
            exit(64)
        case let .render(path, sample, dark, narrow):
            Self.renderPreview(path: path, sample: sample, dark: dark, narrow: narrow)
        }
    }

    static func renderPreview(path: String, sample: AppModel.Preview, dark: Bool, narrow: Bool) -> Never {
        let scheme: ColorScheme = dark ? .dark : .light
        let width: CGFloat = narrow ? 565 : 660
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        var rendered: Data?
        appearance?.performAsCurrentDrawingAppearance {
            let view = WorkspaceView(model: AppModel(preview: sample))
                .frame(width: width, height: 368)
                .environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white)
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
        workspace
        statusMenu
    }

    private var workspace: some Scene {
        Window(model.setup ? model.language.text("setup.title") : "ezNTFS", id: "workspace") {
            if model.setup {
                DependencyHealthView(model: model)
            } else {
                WorkspaceView(model: model)
                    .onAppear { NSApp.setActivationPolicy(.regular) }
            }
        }
        .defaultSize(width: model.setup ? 510 : 660, height: model.setup ? 365 : 560)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(model.language.text("menu.about")) { lifecycle.showAboutPanel(language: model.language) }
            }
            CommandMenu(model.language.text("settings.language")) {
                Picker(model.language.text("settings.language"), selection: Binding(
                    get: { model.language }, set: { model.setLanguage($0) }
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
                .disabled(model.setup)
                viewReleaseButton
            }
        }
    }

    private var statusMenu: some Scene {
        MenuBarExtra(isInserted: .constant(!model.setup)) {
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
        Button(model.language.text("update.check")) {
            Task { await updates.check(language: model.language) }
        }
        .disabled(updates.checking)
    }

    @ViewBuilder private var viewReleaseButton: some View {
        if let availableRelease = updates.availableRelease {
            Button(model.language.text("update.releasePage")) { NSWorkspace.shared.open(availableRelease) }
        }
    }

}

@MainActor
final class AppUpdates: ObservableObject {
    @Published private(set) var checking = false
    @Published private(set) var availableRelease: URL?

    func check(language: AppLanguage) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let result = await ReleaseCheck.latest(installedVersion: installedVersion)
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
