import SwiftUI

enum TablerIcon: String {
    case refresh, copy, settings
    case mount = "plug-connected"
    case folder = "folder-open"
    case eject = "player-eject"
    case checked = "circle-check"
    case pending = "circle-dashed"
    case information = "info-circle"
    case error = "exclamation-circle"

    func view(size: CGFloat = 17) -> some View {
        Image(rawValue, bundle: .main)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct DriveMark: View {
    var size: CGFloat

    var body: some View {
        Image("drive-mark", bundle: .main)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}
