enum LaunchMode {
    case normal
    case previewWindow(AppModel.Preview)
    case render(path: String, AppModel.Preview, dark: Bool, narrow: Bool)
    case invalid

    static let current = parse(Array(CommandLine.arguments.dropFirst()))

    static func parse(_ arguments: [String]) -> LaunchMode {
        if arguments.contains(where: { $0.hasPrefix("--preview-window=") || $0.hasPrefix("--render-preview=") }) {
            return .invalid
        }
        guard let index = arguments.firstIndex(where: { $0 == "--preview-window" || $0 == "--render-preview" }) else {
            return .normal
        }
        let command = arguments[index]
        let options = Array(arguments.dropFirst(index + 1))
        if command == "--preview-window" {
            guard options.count == 1, let sample = AppModel.Preview(rawValue: options[0]) else { return .invalid }
            return .previewWindow(sample)
        }

        guard let path = options.first, !path.isEmpty, !path.hasPrefix("--") else { return .invalid }
        let sample = options.count > 1 ? AppModel.Preview(rawValue: options[1]) : .ready
        let flags = options.dropFirst(2)
        guard let sample, flags.allSatisfy({ $0 == "dark" || $0 == "narrow" }) else { return .invalid }
        return .render(path: path, sample, dark: flags.contains("dark"), narrow: flags.contains("narrow"))
    }

    var previewWindow: AppModel.Preview? {
        if case .previewWindow(let sample) = self { return sample }
        return nil
    }
}
