import Foundation

extension Bundle {
    static let asterResources: Bundle = {
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Aster_Aster.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Aster_Aster.bundle"),
            executableDirectory.appendingPathComponent("Aster_Aster.bundle")
        ].compactMap { $0 }

        for candidate in candidates {
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return .module
    }()
}
