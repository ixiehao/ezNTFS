import AppKit
import EzNTFSCore
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var settingsPresented = false
    @State private var errorDetailsPresented = false

    private var language: AppLanguage { model.language }

    static let tint = Color(red: 0.035, green: 0.36, blue: 0.80)

    private var showsError: Bool { model.isError && model.message != nil }

    var body: some View {
        VStack(spacing: 0) {
            if showsError, let message = model.message.map(language.resolve) {
                errorBanner(message)
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.disks.isEmpty {
                        volumeCard
                    } else {
                        ForEach(model.disks) { disk in
                            diskRow(disk)
                        }
                    }
                    if model.activity == .copying { copyProgress }
                    if let receipt = model.visibleReceipt { receiptRow(receipt) }
                    if !showsError, let message = model.message.map(language.resolve),
                       model.activity != .copying || (model.progress != nil && model.cancellationRequested) {
                        notice(message)
                    }
                }
                .padding([.horizontal, .bottom], 22)
                .padding(.top, showsError ? 12 : 22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 565, idealWidth: 660, maxWidth: .infinity,
               minHeight: 368, maxHeight: .infinity, alignment: .topLeading)
        .background(scheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white)
        .tint(Self.tint)
        .environment(\.locale, language.locale)
        .sheet(isPresented: $model.dependencySheetPresented) { DependencyHealthView(model: model) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    settingsPresented.toggle()
                } label: {
                    TablerIcon.settings.view()
                }
                .accessibilityLabel(language.text("settings.title"))
                .accessibilityIdentifier("workspace-settings")
                .help(language.text("settings.title"))
                .popover(isPresented: $settingsPresented, arrowEdge: .top) { settings }
            }
        }
    }

    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: 13) }

    private var cardFill: Color {
        Self.tint.opacity(scheme == .dark ? 0.085 : 0.025)
    }

    private var diskMark: some View {
        DriveMark(size: 26)
            .accessibilityHidden(true)
            .foregroundStyle(scheme == .dark ? Color(red: 0.48, green: 0.70, blue: 1) : Self.tint)
            .frame(width: 42, height: 42)
            .background(Self.tint.opacity(scheme == .dark ? 0.18 : 0.085),
                        in: RoundedRectangle(cornerRadius: 10))
    }

    private func diskRow(_ disk: ExternalVolume) -> some View {
        let busy = model.activity != nil
        let name = model.diskLabel(disk)
        let restriction = model.automaticMountRestriction(for: disk)
        let totalBytes = Int64(clamping: disk.fingerprint.partitionBytes)
        let capacity = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                diskMark
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .help(name)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 8) {
                        Text("\(disk.transport) · NTFS · \(capacity) · \(disk.partition)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        statusBadge(diskState(disk))
                    }
                }
                Spacer(minLength: 10)
                Toggle(language.text("disk.autoMount"), isOn: automaticMountBinding(for: disk))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.callout)
                    .fixedSize()
                    .accessibilityLabel(language.text("disk.autoMountLabel", name))
                    .accessibilityIdentifier("auto-mount-\(disk.partition)")
                    .help(restriction ?? language.text("disk.autoMountHelp"))
                    .disabled(busy || restriction != nil)
            }

            if let available = disk.mount?.availableCapacity, available >= 0,
               totalBytes > 0, available <= totalBytes {
                capacityUsage(total: totalBytes, available: available)
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { diskActions(disk, busy: busy, horizontal: true) }
                VStack(alignment: .leading, spacing: 8) { diskActions(disk, busy: busy, horizontal: false) }
            }
            if model.activity == .copying, model.selection == disk.id {
                action(language.text("copy.cancel"), identifier: "copy-cancel", method: model.cancelCopy)
                    .disabled(model.cancellationRequested)
            }
        }
        .padding(14)
        .background(cardFill, in: cardShape)
        .overlay { cardShape.strokeBorder(.primary.opacity(0.08)).allowsHitTesting(false) }
        .contentShape(cardShape)
        .onTapGesture { model.select(disk.id) }
    }

    @ViewBuilder
    private func diskActions(_ disk: ExternalVolume, busy: Bool, horizontal: Bool) -> some View {
        if !disk.isWritable {
            action(language.text("disk.mount"), icon: .mount, prominent: true,
                   identifier: "mount-\(disk.partition)", minLabelWidth: 98) {
                model.startMount(diskID: disk.id)
            }.disabled(busy || !disk.canMountReadWrite)
        }
        action(language.text("disk.finder"), icon: .folder, prominent: disk.isWritable,
               identifier: "finder-\(disk.partition)", minLabelWidth: disk.isWritable ? 98 : nil) {
            model.select(disk.id); model.showVolume()
        }.disabled(busy || disk.mount == nil)
        if disk.isWritable {
            action(language.text("copy.action"), icon: .copy, identifier: "copy-\(disk.partition)") {
                model.select(disk.id); model.chooseCopy()
            }
            .help(language.text("copy.help"))
            .disabled(busy)
        }
        if horizontal { Spacer(minLength: 8) }
        action(language.text("disk.eject"), icon: .eject, identifier: "eject-\(disk.partition)") {
            model.eject(diskID: disk.id)
        }.disabled(busy).help(language.text("disk.ejectHelp"))
    }

    private func capacityUsage(total: Int64, available: Int64) -> some View {
        let used = total - available
        let usedText = ByteCountFormatter.string(fromByteCount: used, countStyle: .file)
        let availableText = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(language.text("disk.used", usedText))
                Spacer(minLength: 8)
                Text(language.text("disk.available", availableText))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            ProgressView(value: Double(used), total: Double(total))
                .progressViewStyle(ConsoleProgressStyle())
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private func statusBadge(_ status: (label: String, color: Color)) -> some View {
        HStack(spacing: 4) {
            Circle()
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(status.label).font(.caption.weight(.medium))
        }
        .lineLimit(1)
        .foregroundStyle(status.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(status.color.opacity(scheme == .dark ? 0.14 : 0.085), in: Capsule())
        .fixedSize()
    }

    private func diskState(_ disk: ExternalVolume) -> (label: String, color: Color) {
        if model.activityVolume == disk.id, model.activity == .mounting { return (language.text("disk.mounting"), .secondary) }
        if model.activityVolume == disk.id, model.activity == .ejecting { return (language.text("disk.ejecting"), .secondary) }
        if disk.isWritable { return (language.text("disk.writable"), readyColor) }
        guard let mount = disk.mount else { return (language.text("disk.unmounted"), .secondary) }
        let caution = scheme == .dark ? Color.yellow : Color(red: 0.56, green: 0.32, blue: 0.04)
        return (mount.readOnly ? language.text("disk.readOnly") : language.text("disk.otherDriver"), caution)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            TablerIcon.error.view(size: 19)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                if model.needsDiskPermission {
                    Text(language.text("error.permissionTitle"))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(model.needsDiskPermission ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("console-message")
                HStack(spacing: 8) {
                    if model.needsDiskPermission {
                        Button(language.text("error.openPermissions"), action: model.openDiskPermission)
                            .buttonStyle(.borderedProminent)
                        Button(language.text("error.copyServicePath"), action: model.copyMountHelperPath)
                            .buttonStyle(.bordered)
                    }
                    if let diagnostic = model.diagnostic {
                        Button(language.text("error.technical")) { errorDetailsPresented.toggle() }
                            .buttonStyle(.borderless)
                            .popover(isPresented: $errorDetailsPresented) {
                                ScrollView {
                                    Text(diagnostic)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(width: 355, height: 115)
                                .padding(12)
                            }
                    }
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(scheme == .dark ? 0.11 : 0.07), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11).strokeBorder(Color.orange.opacity(0.26))
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("error-banner")
    }

    private func notice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            TablerIcon.information.view(size: 17)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("console-message")
                if let diagnostic = model.diagnostic {
                    DisclosureGroup(language.text("error.technical")) {
                        ScrollView {
                            Text(diagnostic)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 84)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private var volumeCard: some View {
        HStack(spacing: 12) {
            diskMark
            VStack(alignment: .leading, spacing: 4) {
                Text(model.waitingToDisconnect ? language.text("disk.ejected") : language.text("disk.connect"))
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("volume-status")
                if model.waitingToDisconnect {
                    Text(language.text("disk.disconnect")).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(cardFill, in: cardShape)
        .overlay { cardShape.strokeBorder(.primary.opacity(0.08)).allowsHitTesting(false) }
    }

    private var copyProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.progress?.stage == .checking ? language.text("copy.checking") : language.text("copy.copying"))
                    .font(.system(size: 19, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if let progress = model.progress {
                    Text(language.text(
                        "copy.fileCount",
                        min(progress.filesCompleted + 1, progress.fileCount).formatted(.number.locale(language.locale)),
                        progress.fileCount.formatted(.number.locale(language.locale))
                    ))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let progress = model.progress {
                Text(progress.name).lineLimit(1).help(progress.name)
                    .font(.callout).foregroundStyle(.secondary)
                ProgressView(value: Double(progress.bytesDone), total: Double(max(1, progress.fileBytes)))
                    .progressViewStyle(ConsoleProgressStyle())
                    .accessibilityLabel(progress.stage == .checking ? language.text("copy.verifyProgress") : language.text("copy.writeProgress"))
            } else {
                Text(model.message.map(language.resolve) ?? language.text("copy.scanning")).font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("copy-progress")
    }

    private func receiptRow(_ receipt: CopyReceipt) -> some View {
        HStack {
            Label { Text(language.text("copy.verified", receipt.files.formatted(.number.locale(language.locale)))) } icon: {
                TablerIcon.checked.view(size: 19).foregroundStyle(readyColor)
            }
            .font(.callout.weight(.medium))
            Spacer()
            action(language.text("copy.reveal"), identifier: "copy-reveal", method: model.revealReceipt)
        }
        .accessibilityIdentifier("copy-receipt")
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 11) {
                settingToggle(
                    language.text("settings.autoMount"), detail: language.text("settings.autoMountHint"), identifier: "auto-mount-global",
                    isOn: Binding(get: { model.autoMount }, set: { model.setAutomatic($0) })
                )
                .disabled(model.activity != nil)
                settingToggle(language.text("settings.login"), detail: model.loginStatus == .requiresApproval
                              ? language.text("settings.loginHint") : nil,
                              identifier: "login-open", isOn: Binding(
                                get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
                                set: { model.setLogin($0) }
                              ))
                if let disk = model.selected {
                    Divider()
                    let restriction = model.automaticMountRestriction(for: disk)
                    settingToggle(language.text("settings.diskAutoMount"), detail: restriction ?? disk.name,
                                  identifier: "disk-auto-mount", isOn: automaticMountBinding(for: disk))
                        .disabled(model.activity != nil || restriction != nil)
                }
            }
            Divider()
            Picker(language.text("settings.language"), selection: Binding(
                get: { model.language }, set: { model.setLanguage($0) }
            )) {
                ForEach(AppLanguage.allCases) { option in
                    Text(language.name(of: option)).tag(option)
                }
            }
            .accessibilityIdentifier("interface-language")
            Divider()
            HStack(spacing: 8) {
                action(language.text("health.title"), icon: .information, identifier: "dependency-health", fillsWidth: true) {
                    settingsPresented = false
                    model.openDependencyHealth()
                }
                action(language.text("settings.refresh"), icon: .refresh, identifier: "disk-refresh", fillsWidth: true) {
                    Task { await model.refresh() }
                }
                .disabled(model.activity != nil)
            }
        }
        .padding(16)
        .frame(width: 328, alignment: .leading)
    }

    private func automaticMountBinding(for disk: ExternalVolume) -> Binding<Bool> {
        Binding(get: { model.remembered.contains(disk.fingerprint) },
                set: { model.setRemembered($0, diskID: disk.id) })
    }

    private func settingToggle(_ title: String, detail: String?, identifier: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityHidden(true)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityHint(detail ?? "")
                .accessibilityIdentifier(identifier)
        }
    }

    private func action(_ title: String, icon: TablerIcon? = nil, prominent: Bool = false,
                        identifier: String, fillsWidth: Bool = false, minLabelWidth: CGFloat? = nil,
                        method: @escaping () -> Void) -> some View {
        Button(action: method) {
            HStack(spacing: 6) {
                if let icon { icon.view(size: 16) }
                Text(title).fixedSize(horizontal: true, vertical: false)
            }
            .frame(minWidth: minLabelWidth, maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(ConsoleButtonStyle(prominent: prominent))
        .accessibilityIdentifier(identifier)
    }

    private var readyColor: Color {
        scheme == .dark ? Color(red: 0.47, green: 0.83, blue: 0.63) : Color(red: 0.13, green: 0.42, blue: 0.28)
    }

}

private struct ConsoleProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            Capsule().fill(.primary.opacity(0.09))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(WorkspaceView.tint)
                        .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
                }
        }
        .frame(height: 6)
    }
}

private struct ConsoleButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 11)
            .frame(minHeight: 34)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? WorkspaceView.tint : Color.primary.opacity(scheme == .dark ? 0.06 : 0.018), in: shape)
            .overlay {
                if !prominent { shape.strokeBorder(.primary.opacity(0.16)).allowsHitTesting(false) }
            }
            .contentShape(shape)
            .opacity(enabled ? (configuration.isPressed ? 0.70 : 1) : 0.40)
    }
}
