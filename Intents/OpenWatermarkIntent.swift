import AppIntents

struct OpenWatermarkIntent: AppIntent {
    static let title: LocalizedStringResource = "添加液态玻璃水印"
    static let description = IntentDescription("打开本地处理页面，选择普通照片或实况照片。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "LGWOpenPhotoPicker")
        return .result()
    }
}

