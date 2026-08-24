import SwiftUI
import Photos
import PhotosUI

struct ContentView: View {
    @StateObject private var model = WatermarkModel()
    @State private var showingPicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "camera.filters")
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 112, height: 112)
                    .glassEffect(.regular, in: .rect(cornerRadius: 32))

                Text("液态玻璃水印")
                    .font(.largeTitle.bold())
                Text("照片和 Live Photo 均在本机处理。\nLive Photo 会先复制，再对副本逐帧添加水印。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if model.isWorking {
                    ProgressView(value: model.progress) {
                        Text(model.status)
                    }
                    .progressViewStyle(.linear)
                    .padding(.horizontal)
                } else {
                    Button {
                        showingPicker = true
                    } label: {
                        Label("选择照片或实况照片", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .padding(.horizontal)
                }

                if let result = model.resultMessage {
                    Label(result, systemImage: model.didSucceed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.didSucceed ? .green : .orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("本地处理")
            .sheet(isPresented: $showingPicker) {
                AssetPicker { identifier in
                    showingPicker = false
                    guard let identifier else { return }
                    Task { await model.process(localIdentifier: identifier) }
                }
            }
        }
    }
}

private struct AssetPicker: UIViewControllerRepresentable {
    let completion: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = 1
        configuration.filter = .any(of: [.images, .livePhotos])
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: (String?) -> Void
        init(completion: @escaping (String?) -> Void) { self.completion = completion }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            completion(results.first?.assetIdentifier)
        }
    }
}

