//
//  File.swift
//  
//
//  Created by 斉藤　尚也 on 2022/01/24.
//

import Foundation

public enum BSVideoLoaderError: Error {
    case isNotExportable
    case failedToCreateVideoTrack(msg: String)
    case failedToCreateAudioTrack(msg: String)
    case failedToCreateExportSession
    case failedRemoveFile
    case downlaodFailed(msg: String)
    case downloadCancel
    case exportError
    case exportCancel
    case exportUnknownError
}
