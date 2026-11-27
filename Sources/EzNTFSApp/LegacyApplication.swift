import AppKit
import Combine
import EzNTFSCore
import SwiftUI

/// AppKit owns the window and status item on Monterey. The workspace and setup views are shared.
@MainActor
final class LegacyApplication: Lifecycle, NSMenuDelegate, NSToolbarDelegate {
    private let model = LaunchMode.current.previewWindow.map { AppModel(preview: $0) } ?? .shared
    private var window: NSWindow!
    private var statusItem: NSStatusItem?
    private var languageObserver: AnyCancellable?
    private let settingsItem = NSToolbarItem.Identifier("ezNTFS.settings")
    private let settingsPopover = NSPopover()
    private let updates = AppUpdates()
    private var language: AppLanguage { model.language }

    static func run() {
        switch LaunchMode.current {
        case .invalid, .render:
            FileHandle.standardError.write(Data("ezNTFS: Invalid or unavailable preview arguments.\n".utf8))
            exit(64)
        default:
            let application = NSApplication.shared
            let delegate = LegacyApplication()
            application.delegate = delegate
            application.setActivationPolicy(.regular)
            withExtendedLifetime(delegate) { application.run() }
        }
    }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        let setup = model.setup
        let content: AnyView = setup
            ? AnyView(DependencyHealthView(model: model))
            : AnyView(WorkspaceView(model: model, usesNativeToolbar: true))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: setup ? 510 : 660, height: setup ? 390 : 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: setup ? 510 : 565, height: setup ? 390 : 400)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.center()

        if !setup {
            let toolbar = NSToolbar(identifier: "ezNTFS.workspace")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.toolbarStyle = .unifiedCompact
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let image = IconTemplate.image(named: "menu-drive-mark")?.copy() as? NSImage {
                image.size = NSSize(width: 19, height: 15)
                image.isTemplate = true
                item.button?.image = image
            } else {
                item.button?.title = "NTFS"
            }
            item.button?.setAccessibilityLabel("ezNTFS")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }
        updateMainMenu(language)
        languageObserver = model.$language.dropFirst().sink { [weak self] language in
            self?.updateMainMenu(language)
        }
        super.applicationDidFinishLaunching(notification)
        showWorkspace()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, settingsItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == settingsItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = language.text("settings.title")
        let button = NSButton(title: "", target: self, action: #selector(showSettings(_:)))
        button.toolTip = item.label
        button.setAccessibilityLabel(item.label)
        button.setAccessibilityIdentifier("workspace-settings")
        if let image = IconTemplate.image(named: TablerIcon.settings.rawValue)?.copy() as? NSImage {
            image.size = NSSize(width: 17, height: 17)
            image.isTemplate = true
            button.image = image
        } else {
            button.title = item.label
        }
        button.bezelStyle = .texturedRounded
        button.sizeToFit()
        item.view = button
        return item
    }

    @objc private func showSettings(_ sender: NSButton) {
        if settingsPopover.isShown {
            settingsPopover.performClose(nil)
            return
        }
        settingsPopover.behavior = .transient
        settingsPopover.contentViewController = NSHostingController(rootView: WorkspaceSettingsView(model: model) { [weak self] in
            self?.settingsPopover.performClose(nil)
        })
        settingsPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWorkspace() }
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(language.text("menu.open"), #selector(showWorkspace)))
        menu.addItem(.separator())
        if model.disks.isEmpty {
            menu.addItem(NSMenuItem(title: language.text("menu.noVolumes"), action: nil, keyEquivalent: ""))
        }
        for disk in model.disks {
            let diskItem = NSMenuItem(title: model.diskLabel(disk), action: nil, keyEquivalent: "")
            let actions = NSMenu()
            actions.autoenablesItems = false
            let mount = item(language.text("disk.mount"), #selector(mountDisk(_:)))
            mount.representedObject = NSNumber(value: disk.id)
            mount.isEnabled = disk.canMountReadWrite && model.activity == nil
            actions.addItem(mount)
            let eject = item(language.text("disk.eject"), #selector(ejectDisk(_:)))
            eject.representedObject = NSNumber(value: disk.id)
            eject.isEnabled = model.activity == nil
            actions.addItem(eject)
            diskItem.submenu = actions
            menu.addItem(diskItem)
        }
        menu.addItem(.separator())
        menu.addItem(item(language.text("update.check"), #selector(checkForUpdates)))
        if updates.availableRelease != nil { menu.addItem(item(language.text("update.releasePage"), #selector(openRelease))) }
        menu.addItem(item(language.text("menu.about"), #selector(showAbout)))
        menu.addItem(NSMenuItem(title: language.text("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    private func updateMainMenu(_ language: AppLanguage) {
        window.title = model.setup ? language.text("setup.title") : "ezNTFS"
        let menu = NSMenu()
        let application = NSMenu()
        application.addItem(item(language.text("menu.about"), #selector(showAbout)))
        application.addItem(.separator())
        application.addItem(NSMenuItem(title: language.text("menu.quit"), action: #selector(NSApplication.terminate(_:)),
                                      keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = application
        menu.addItem(appItem)

        let edit = NSMenu(title: language.text("menu.edit"))
        for (title, action, key) in [("menu.cut", "cut:", "x"), ("menu.copy", "copy:", "c"),
                                      ("menu.paste", "paste:", "v"), ("menu.selectAll", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: language.text(title), action: NSSelectorFromString(action), keyEquivalent: key))
        }
        let editItem = NSMenuItem()
        editItem.submenu = edit
        menu.addItem(editItem)
        var helpMenu: NSMenu?
        if !model.setup {
            let languages = NSMenu(title: language.text("settings.language"))
            for option in AppLanguage.allCases {
                let choice = item(language.name(of: option), #selector(selectLanguage(_:)))
                choice.representedObject = option.rawValue
                choice.state = language == option ? .on : .off
                languages.addItem(choice)
            }
            let languageItem = NSMenuItem()
            languageItem.submenu = languages
            menu.addItem(languageItem)

            let help = NSMenu(title: language.text("menu.help"))
            help.addItem(item(language.text("update.check"), #selector(checkForUpdates)))
            help.addItem(item(language.text("menu.dependencies"), #selector(showDependencies)))
            if updates.availableRelease != nil { help.addItem(item(language.text("update.releasePage"), #selector(openRelease))) }
            let helpItem = NSMenuItem()
            helpItem.submenu = help
            menu.addItem(helpItem)
            helpMenu = help
            if let toolbarItem = window.toolbar?.items.first(where: { $0.itemIdentifier == settingsItem }) {
                toolbarItem.label = language.text("settings.title")
                toolbarItem.view?.toolTip = toolbarItem.label
                toolbarItem.view?.setAccessibilityLabel(toolbarItem.label)
            }
        }
        NSApp.mainMenu = menu
        NSApp.helpMenu = helpMenu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showWorkspace() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showDependencies() {
        showWorkspace()
        model.openDependencyHealth()
    }

    @objc private func showAbout() { showAboutPanel(language: language) }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = AppLanguage(rawValue: raw) else { return }
        model.setLanguage(language)
    }

    @objc private func checkForUpdates() {
        Task {
            await updates.check(language: model.language)
            updateMainMenu(model.language)
        }
    }

    @objc private func openRelease() {
        if let page = updates.availableRelease { NSWorkspace.shared.open(page) }
    }

    @objc private func mountDisk(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? NSNumber { model.startMount(diskID: id.uint64Value) }
    }

    @objc private func ejectDisk(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? NSNumber { model.eject(diskID: id.uint64Value) }
    }
}
