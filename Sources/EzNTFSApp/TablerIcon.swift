import AppKit
import SwiftUI

@MainActor
enum IconTemplate {
    private static let bitmaps = Dictionary(uniqueKeysWithValues:
        (Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: "IconTemplates") ?? [])
            .compactMap { url -> (String, NSImage)? in
                guard let image = NSImage(contentsOf: url) else { return nil }
                image.size = NSSize(width: image.size.width / 2, height: image.size.height / 2)
                image.isTemplate = true
                return (url.deletingPathExtension().lastPathComponent, image)
            })

    static func image(named name: String) -> NSImage? {
        bitmaps[name] ?? NSImage(named: NSImage.Name(name))
    }

    static func view(named name: String, width: CGFloat, height: CGFloat) -> some View {
        let image = image(named: name).map { Image(nsImage: $0) } ?? Image(name, bundle: .main)
        return image.renderingMode(.template).resizable().scaledToFit().frame(width: width, height: height)
    }
}

enum TablerIcon: String {
    case refresh, copy, settings
    case mount = "plug-connected"
    case folder = "folder-open"
    case eject = "player-eject"
    case checked = "circle-check"
    case pending = "circle-dashed"
    case information = "info-circle"
    case error = "exclamation-circle"

    @MainActor func view(size: CGFloat = 17) -> some View {
        IconTemplate.view(named: rawValue, width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct DriveMark: View {
    var size: CGFloat

    var body: some View {
        IconTemplate.view(named: "drive-mark", width: size, height: size)
    }
}
