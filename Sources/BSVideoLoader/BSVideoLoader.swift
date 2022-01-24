import Combine
import AVFoundation

@available(iOS 13.0, *)
public class BSVideoLoader: NSObject {
    public static let shared = BSVideoLoader()

    public let downloadPublisher = PassthroughSubject<URL, Error>()
    public let percentPublihser = PassthroughSubject<Double, Never>()

    private lazy var downloadURLSession: AVAssetDownloadURLSession? = {
        .init(
            configuration: configuration,
            assetDownloadDelegate: self,
            delegateQueue: OperationQueue.main
        )
    }()

    private var configuration: URLSessionConfiguration {
        .background(withIdentifier: String(describing: Self.self))
    }

    private var activeDownloadsMap: [AVAggregateAssetDownloadTask: AVURLAsset] = [:]
    private var timerCancellable: AnyCancellable?

    override private init() {
        super.init()
    }

    public func exportVideo(_ asset: AVURLAsset, outputURL: URL, fileType: AVFileType = .mp4, presetName: String = AVAssetExportPresetHighestQuality) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            guard asset.isExportable else {
                return continuation.resume(throwing: BSVideoLoaderError.isNotExportable)
            }

            let composition = AVMutableComposition()

            if
                let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: CMPersistentTrackID(kCMPersistentTrackID_Invalid)),
                let sourceVideoTrack = asset.tracks(withMediaType: .video).first
            {
                do {
                    try compositionVideoTrack.insertTimeRange(CMTimeRangeMake(start: .zero, duration: asset.duration), of: sourceVideoTrack, at: .zero)
                } catch {
                    return continuation.resume(throwing: BSVideoLoaderError.failedToCreateVideoTrack(msg: error.localizedDescription))
                }
            }

            if
                let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: CMPersistentTrackID(kCMPersistentTrackID_Invalid)),
                let sourceAudioTrack = asset.tracks(withMediaType: .audio).first
            {
                do {
                    try compositionAudioTrack.insertTimeRange(CMTimeRangeMake(start: .zero, duration: asset.duration), of: sourceAudioTrack, at: .zero)
                } catch {
                    return continuation.resume(throwing: BSVideoLoaderError.failedToCreateAudioTrack(msg: error.localizedDescription))
                }
            }

            guard let exportSession = AVAssetExportSession(asset: composition, presetName: presetName) else {
                return continuation.resume(throwing: BSVideoLoaderError.failedToCreateExportSession)
            }

            timerCancellable = Timer.publish(every: 0.1, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self = self else { return }

                    if exportSession.progress == 1 {
                        self.timerCancellable?.cancel()
                        self.percentPublihser.send(completion: .finished)
                    } else {
                        let progress = Double(exportSession.progress)
                        self.percentPublihser.send(progress)
                    }
                }

            exportSession.outputURL = outputURL
            exportSession.outputFileType = fileType
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .waiting, .exporting:
                    break

                case .failed:
                    guard let error = exportSession.error else {
                        return continuation.resume(throwing: BSVideoLoaderError.exportError)
                    }

                    self.timerCancellable?.cancel()
                    return continuation.resume(throwing: error)

                case .cancelled:

                    self.timerCancellable?.cancel()
                    return continuation.resume(throwing: BSVideoLoaderError.exportCancel)

                case .completed:

                    self.timerCancellable?.cancel()
                    return continuation.resume(returning: true)

                default:

                    self.timerCancellable?.cancel()
                    return continuation.resume(throwing: BSVideoLoaderError.exportUnknownError)
                }
            }
        }
    }

    public func downloadStream(urlAsset: AVURLAsset, name: String) {
        let preferredMediaSelection = urlAsset.preferredMediaSelection

        guard let task = downloadURLSession?.aggregateAssetDownloadTask(
            with: urlAsset,
            mediaSelections: [preferredMediaSelection],
            assetTitle: name,
            assetArtworkData: nil,
            options: [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 5_000_000]
        ) else { return }

        activeDownloadsMap[task] = urlAsset

        task.taskDescription = name
        task.resume()
    }

    private func displayNamesForSelectedMediaOptions(_ mediaSelection: AVMediaSelection) -> String {
        var displayNames = ""

        guard let asset = mediaSelection.asset else { return displayNames }

        for mediaCharacteristic in asset.availableMediaCharacteristicsWithMediaSelectionOptions {
            guard let mediaSelectionGroup =
                    asset.mediaSelectionGroup(forMediaCharacteristic: mediaCharacteristic),
                  let option = mediaSelection.selectedMediaOption(in: mediaSelectionGroup) else { continue }

            if displayNames.isEmpty {
                displayNames += " " + option.displayName
            } else {
                displayNames += ", " + option.displayName
            }
        }

        return displayNames
    }
}

