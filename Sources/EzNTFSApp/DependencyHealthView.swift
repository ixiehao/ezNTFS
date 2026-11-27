import AppKit
import EzNTFSCore
import SwiftUI

struct DependencyHealthView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var language: AppLanguage { model.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(language.text("health.title")).font(.title3.bold())
                Spacer()
                Button {
                    Task { await model.checkDependencies() }
                } label: {
                    Label { Text(language.text("health.refresh")) } icon: { TablerIcon.refresh.view(size: 15) }
                }
                .disabled(model.checkingDependencies || model.preparingDependency || (model.setup && !model.setupArchitectureMatches))
            }

            if model.checkingDependencies {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(language.text("health.checking"))
                        .foregroundStyle(.secondary)
                }
            }
            if let report = model.dependencyReport {
                VStack(alignment: .leading, spacing: 12) {
                    row("macFUSE", status: report.macFUSE)
                    row("NTFS-3G", status: report.ntfs3g)
                    row(language.text("health.service"), status: report.service, service: true)
                }
                if !model.setup && !report.canMountReadWrite && !model.checkingDependencies {
                    Label {
                        Text(language.text("health.blocked"))
                    } icon: {
                        TablerIcon.error.view(size: 15).foregroundStyle(.red)
                    }
                    .font(.callout)
                }
            }
            if let notice = model.dependencyNotice {
                HStack(alignment: .top, spacing: 8) {
                    if model.preparingDependency { ProgressView().controlSize(.small) }
                    Text(language.resolve(notice))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                if notice.key == "health.downloadError" || notice.key == "health.verifyError" {
                    Button(language.text("health.fuseWebsite")) { openURL(MacFUSEInstaller.releasePage) }
                } else if notice.key == "health.mainInstallerMissing" || notice.key == "setup.wrongArchitecture" {
                    Button(language.text("health.releasePage")) { openURL(ReleaseCheck.projectPage.appendingPathComponent("releases")) }
                } else if #unavailable(macOS 13.0), notice.key == "health.awaitingFuse" {
                    Button(language.text("health.securitySettings"), action: model.openExtensionApproval)
                }
            } else if model.dependencyStep == .macFUSE && !model.checkingDependencies {
                Text(language.text("health.fuseHint", MacFUSEInstaller.version))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if !model.setup {
                    Button(language.text("health.diskPermissions"), action: model.openDiskPermission)
                }
                Spacer()
                if !model.setup {
                    Button(language.text("button.done")) { dismiss() }
                }
                if model.dependencyStep != nil {
                    Button(language.text("health.install"), action: model.installDependency)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.checkingDependencies || model.preparingDependency || model.activity != nil)
                        .keyboardShortcut(.defaultAction)
                } else if model.setup && model.dependencyReport != nil {
                    Button(language.text("setup.openApp"), action: model.openInstalledApp)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 510)
    }

    private func row(_ name: String, status: DependencyStatus, service: Bool = false) -> some View {
        let ready = status.path != nil
        return HStack(alignment: .top, spacing: 10) {
            (model.checkingDependencies ? .pending : (ready ? .checked : TablerIcon.error)).view(size: 17)
                .foregroundStyle(model.checkingDependencies ? Color.secondary : (ready ? .green : .red))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.callout.weight(.semibold))
                switch status {
                case .ready(_, let version):
                    Text(service ? language.text(model.setup ? "setup.serviceInstalled" : "health.connected") :
                            language.text("health.readyVersion", version))
                        .font(.callout).foregroundStyle(.secondary)
                case .missing:
                    Text(language.text("health.missing")).font(.callout).foregroundStyle(.secondary)
                case .disabled:
                    Text(language.text("health.disabled")).font(.callout).foregroundStyle(.secondary)
                case .unavailable(let detail):
                    DisclosureGroup(language.text("health.unavailable")) {
                        Text(detail).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                if let path = status.path {
                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

extension DriverUsage {
    var repairBlockMessage: InterfaceMessage? {
        switch self {
        case .idle: nil
        case .inUse: "health.repairBusy"
        case .unavailable: "health.repairUnknown"
        }
    }
}
