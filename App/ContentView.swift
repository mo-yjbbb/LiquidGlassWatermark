import SwiftUI
import Photos
import PhotosUI
import UniformTypeIdentifiers

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
                AssetPicker { selection in
                    showingPicker = false
                    guard let selection else { return }
                    Task { await model.process(selection: selection) }
                }
            }
        }
    }
}

private struct AssetPicker: UIViewControllerRepresentable {
    let completion: (PickedPhoto?) -> Void

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
        let completion: (PickedPhoto?) -> Void
        init(completion: @escaping (PickedPhoto?) -> Void) { self.completion = completion }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let result = results.first else {
                completion(nil)
                return
            }
            let provider = result.itemProvider
            let librarySaysLive = result.assetIdentifier.flatMap {
                PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject
            }?.mediaSubtypes.contains(.photoLive) == true
            let isLive = librarySaysLive
                || provider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier)
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] url, _ in
                guard let self else { return }
                guard let url else {
                    self.loadImageData(provider: provider, result: result, isLive: isLive)
                    return
                }
                let ext = url.pathExtension.isEmpty ? "heic" : url.pathExtension
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    let selection = PickedPhoto(localIdentifier: result.assetIdentifier,
                                                imageURL: copy, isLivePhoto: isLive)
                    DispatchQueue.main.async { self.completion(selection) }
                } catch {
                    self.loadImageData(provider: provider, result: result, isLive: isLive)
                }
            }
        }

        private func loadImageData(provider: NSItemProvider, result: PHPickerResult, isLive: Bool) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [completion] data, _ in
                guard let data, !data.isEmpty else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("img")
                do {
                    try data.write(to: copy, options: .atomic)
                    let selection = PickedPhoto(localIdentifier: result.assetIdentifier,
                                                imageURL: copy, isLivePhoto: isLive)
                    DispatchQueue.main.async { completion(selection) }
                } catch {
                    DispatchQueue.main.async { completion(nil) }
                }
            }
        }
    }
}

