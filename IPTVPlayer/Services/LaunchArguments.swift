import Foundation

enum LaunchArguments {
    static func value(after flag: String, in args: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }
}
