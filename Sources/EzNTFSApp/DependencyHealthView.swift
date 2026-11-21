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
                .disabled(model.checkingDependencies)
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
                if !report.canMountReadWrite && !model.checkingDependencies {
                    Label {
                        Text(language.text("health.blocked"))
                    } icon: {
                        TablerIcon.error.view(size: 15).foregroundStyle(.red)
                    }
                    .font(.callout)
                }
                if report.macFUSE == .missing && !model.checkingDependencies {
                    Button(language.text("health.fuseWebsite")) { openURL(Dependencies.macFUSEWebsite) }
                }
                if report.service == .missing {
                    Text(language.text("health.missingService"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let reason = report.driverUsage.repairBlockMessage, model.dependencyInstallError == nil {
                    Label {
                        Text(language.resolve(reason))
                    } icon: {
                        TablerIcon.information.view(size: 15).foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
                HStack {
                    if report.macFUSE.path != nil && report.service != .missing {
                        Button(report.ntfs3g.path == nil ? language.text("health.install") : language.text("health.reinstall"),
                               action: model.installDependency)
                            .buttonStyle(.borderedProminent)
                            .disabled(model.activity != nil || model.checkingDependencies || report.driverUsage != .idle)
                    }
                    if report.service.path == nil && report.service != .missing {
                        Button(language.text("health.serviceSettings"), action: model.openServiceSettings)
                    }
                    Button(language.text("health.diskPermissions"), action: model.openDiskPermission)
                }
            }
            if let error = model.dependencyInstallError {
                ScrollView {
                    Text(language.resolve(error)).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout).frame(maxHeight: 95)
            }
            HStack {
                Spacer()
                Button(language.text("button.done")) { dismiss() }.keyboardShortcut(.defaultAction)
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
                    Text(service ? language.text("health.connected") : language.text("health.readyVersion", version))
                        .font(.callout).foregroundStyle(.secondary)
                case .missing:
                    Text(language.text("health.missing")).font(.callout).foregroundStyle(.secondary)
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
