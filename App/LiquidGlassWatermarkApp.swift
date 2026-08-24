import SwiftUI
import AppIntents

@main
struct LiquidGlassWatermarkApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct WatermarkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenWatermarkIntent(),
            phrases: [
                "用\(.applicationName)添加水印",
                "在\(.applicationName)处理实况照片"
            ],
            shortTitle: "添加液态玻璃水印",
            systemImageName: "camera.filters"
        )
    }
}

