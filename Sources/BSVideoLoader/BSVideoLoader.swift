import Combine
import AVFoundation

@available(iOS 13.0, *)
public class BSVideoLoader: NSObject {
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
    
    private let fileManager = FileManager.default
    
    private var exportSession: AVAssetExportSession?

    private var activeDownloadsMap: [AVAggregateAssetDownloadTask: AVURLAsset] = [:]
    private var timerCancellable: AnyCancellable?
    
    private var downloadTask: URLSessionDataTask?
    private var observation: NSKeyValueObservation?
    
    public override init() {
        super.init()
    }
    
    // 外部からダウンロードする時に利用する
    public func downloadVideo(url: URL, outputURL: URL, headers: [String: String]? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) -> Void in
            var request = URLRequest(url: url)
            request.allHTTPHeaderFields = headers
            
            downloadTask = URLSession.shared.dataTask(with: request) { (data, response, error) in
                if let error = error {
                    if let nsError = error as NSError? {
                        if nsError.code == NSURLErrorCancelled {
                            return continuation.resume(throwing: BSVideoLoaderError.downloadCancel)
                        } else if nsError.code == NSURLErrorNotConnectedToInternet || nsError.code == NSURLErrorDataNotAllowed {
                            return continuation.resume(throwing: BSVideoLoaderError.connectionLost)
                        }
                    }
                    
                    return continuation.resume(throwing: BSVideoLoaderError.downlaodFailed(error: error))
                }
                
                guard let data = data, !data.isEmpty else {
                    return continuation.resume(throwing: BSVideoLoaderError.downlaodFailed())
                }
                
                do {
                    try data.write(to: outputURL)

                    return continuation.resume()
                } catch {                    
                    return continuation.resume(throwing: BSVideoLoaderError.downlaodFailed(error: error))
                }
            }
            
            observation = downloadTask?.progress.observe(\.fractionCompleted, changeHandler: { [weak self] progress, _ in
                guard let self = self else { return }
                
                if progress.isFinished {
                    self.observation = nil
                    self.percentPublihser.send(completion: .finished)
                } else {
                    self.percentPublihser.send(progress.fractionCompleted)
                }
            })
            
            downloadTask?.resume()
        }
    }
    
    public func downloadCancel() {
        downloadTask?.cancel()
    }
    
    // AVAssetをローカルに保存する時に利用(リモートファイルをダウンロードするのは非推奨 => downloadVideoを使用すること)
    public func exportVideo(_ asset: AVAsset, outputURL: URL, fileType: AVFileType = .mp4, presetName: String = AVAssetExportPresetHighestQuality) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            guard asset.isExportable else {
                return continuation.resume(throwing: BSVideoLoaderError.isNotExportable)
            }

            let composition = AVMutableComposition()

            if
                let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: CMPersistentTrackID(kCMPersistentTrackID_Invalid)),
                let sourceVideoTrack = asset.tracks(withMediaType: .video).first
            {
                compositionVideoTrack.preferredTransform = sourceVideoTrack.preferredTransform
                
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
            
            self.exportSession = AVAssetExportSession(asset: composition, presetName: presetName)
            guard exportSession != nil else {
                return continuation.resume(throwing: BSVideoLoaderError.failedToCreateExportSession)
            }
            
            timerCancellable = Timer.publish(every: 0.1, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self = self, let exportSession = self.exportSession else { return }

                    if exportSession.progress == 1 {
                        self.timerCancellable?.cancel()
                        self.percentPublihser.send(completion: .finished)
                    } else {
                        let progress = Double(exportSession.progress)
                        self.percentPublihser.send(progress)
                    }
                }
            
            if fileManager.fileExists(atPath: outputURL.path) {
                do {
                    try fileManager.removeItem(at: outputURL)
                } catch {
                    return continuation.resume(throwing: BSVideoLoaderError.failedRemoveFile)
                }
            }

            exportSession?.outputURL = outputURL
            exportSession?.outputFileType = fileType
            exportSession?.exportAsynchronously {
                switch self.exportSession?.status {
                case .waiting, .exporting:
                    break

                case .failed:
                    guard let error = self.exportSession?.error else {
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

    // AVURLAssetをローカルに保存する時に利用(リモートファイルをダウンロードするのは非推奨 => downloadVideoを使用すること)
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
            
            self.exportSession = AVAssetExportSession(asset: composition, presetName: presetName)
            guard exportSession != nil else {
                return continuation.resume(throwing: BSVideoLoaderError.failedToCreateExportSession)
            }
            
            timerCancellable = Timer.publish(every: 0.1, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self = self, let exportSession = self.exportSession else { return }

                    if exportSession.progress == 1 {
                        self.timerCancellable?.cancel()
                        self.percentPublihser.send(completion: .finished)
                    } else {
                        let progress = Double(exportSession.progress)
                        self.percentPublihser.send(progress)
                    }
                }
            
            if fileManager.fileExists(atPath: outputURL.path) {
                do {
                    try fileManager.removeItem(at: outputURL)
                } catch {
                    return continuation.resume(throwing: BSVideoLoaderError.failedRemoveFile)
                }
            }

            exportSession?.outputURL = outputURL
            exportSession?.outputFileType = fileType
            exportSession?.metadata = []
            exportSession?.exportAsynchronously {
                switch self.exportSession?.status {
                case .waiting, .exporting:
                    break

                case .failed:
                    guard let error = self.exportSession?.error else {
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
    
    public func exportCancel() {
        exportSession?.cancelExport()
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

