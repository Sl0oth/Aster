import SwiftUI

extension Color {
    static let asterPurple = Color(red: 0.48, green: 0.20, blue: 0.96)
    static let asterDeepPurple = Color(red: 0.27, green: 0.07, blue: 0.58)

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}
