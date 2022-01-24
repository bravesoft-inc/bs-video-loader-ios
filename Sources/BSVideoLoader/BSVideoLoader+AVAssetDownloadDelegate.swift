//
//  BSVideoLoader+AVAssetDownloadDelegate.swift
//  
//
//  Created by 斉藤　尚也 on 2022/01/24.
//

import AVFoundation

@available(iOS 13.0, *)
extension BSVideoLoader: AVAssetDownloadDelegate {
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            downloadPublisher.send(completion: .failure(error))
            return
        }

        downloadPublisher.send(completion: .finished)
    }

    public func urlSession(_ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask, willDownloadTo location: URL) {
        downloadPublisher.send(location)
    }

    public func urlSession(_ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask, didCompleteFor mediaSelection: AVMediaSelection) {
        aggregateAssetDownloadTask.resume()
    }

    public func urlSession(_ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange, for mediaSelection: AVMediaSelection) {
        var percentComplete = 0.0
        for value in loadedTimeRanges {
            let loadedTimeRange: CMTimeRange = value.timeRangeValue
            percentComplete += loadedTimeRange.duration.seconds / timeRangeExpectedToLoad.duration.seconds
        }

        percentPublihser.send(percentComplete)
    }
}
