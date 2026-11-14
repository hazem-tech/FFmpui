//
//  PhotoLibrary.swift
//  FFmpui (iOS)
//
//  Photos access: reading a video's original file, saving the compressed
//  copy as a new asset (with the original's date, location, favorite,
//  hidden state and albums) and deleting originals.
//

import CoreLocation
import Photos
import UIKit

nonisolated enum PhotoLibrary {
    enum Failure: LocalizedError {
        case notInLibrary
        case noVideoFile

        var errorDescription: String? {
            switch self {
            case .notInLibrary: "This video is no longer in the Photos library"
            case .noVideoFile: "No video file found for this item"
            }
        }
    }

    struct Original {
        let asset: PHAsset
        let resource: PHAssetResource
        /// The video was edited in Photos (trim, filter, slo-mo ramp …).
        let isEdited: Bool
        /// Size of the original file, if Photos tells us.
        let fileSize: Int64?
        var filename: String { resource.originalFilename }
    }

    static var authorization: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static func asset(id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// The original, unedited video file of an asset.
    static func original(id: String) throws -> Original {
        guard let asset = asset(id: id) else { throw Failure.notInLibrary }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let video = resources.first(where: { $0.type == .video }) else { throw Failure.noVideoFile }
        let size = (video.value(forKey: "fileSize") as? NSNumber)?.int64Value
        return Original(
            asset: asset,
            resource: video,
            isEdited: resources.contains { $0.type == .adjustmentData || $0.type == .fullSizeVideo },
            fileSize: size
        )
    }

    static func filename(id: String) -> String? {
        guard let asset = asset(id: id) else { return nil }
        return PHAssetResource.assetResources(for: asset).first { $0.type == .video }?.originalFilename
    }

    // MARK: - Export

    /// Writes the original file's exact bytes to `url`, downloading it from
    /// iCloud if needed. Cancelling the task cancels the request.
    @concurrent
    static func export(_ original: Original, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value in progress(value) }

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let sink = try ExportSink(url: url)
        let manager = PHAssetResourceManager.default()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let requestID = manager.requestData(for: original.resource, options: options) { data in
                    sink.write(data)
                } completionHandler: { error in
                    let writeError = sink.finish()
                    if let error = error ?? writeError {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
                sink.setRequestID(requestID)
            }
        } onCancel: {
            if let id = sink.requestID { manager.cancelDataRequest(id) }
        }
        try Task.checkCancellation()
    }

    /// Writes the chunks Photos hands us; called on Photos' own queue.
    private final class ExportSink: @unchecked Sendable {
        private let lock = NSLock()
        private let handle: FileHandle
        private var error: Error?
        private var id: PHAssetResourceDataRequestID?

        init(url: URL) throws {
            handle = try FileHandle(forWritingTo: url)
        }

        var requestID: PHAssetResourceDataRequestID? { lock.withLock { id } }
        func setRequestID(_ value: PHAssetResourceDataRequestID) { lock.withLock { id = value } }

        func write(_ data: Data) {
            lock.withLock {
                guard error == nil else { return }
                do { try handle.write(contentsOf: data) } catch { self.error = error }
            }
        }

        func finish() -> Error? {
            lock.withLock {
                try? handle.close()
                return error
            }
        }
    }

    // MARK: - Save / delete

    /// Adds `file` (moved, not copied) as a new video with the original's
    /// creation date, location, favorite / hidden state and albums.
    /// Returns the new asset's identifier.
    @concurrent
    static func save(_ file: URL, filename: String, like original: PHAsset) async throws -> String? {
        let albums = PHAssetCollection.fetchAssetCollectionsContaining(original, with: .album, options: nil)
        var editableAlbums: [PHAssetCollection] = []
        albums.enumerateObjects { album, _, _ in
            if album.canPerform(.addContent) { editableAlbums.append(album) }
        }

        let request = SaveRequest(
            file: file, filename: filename,
            creationDate: original.creationDate, location: original.location,
            isFavorite: original.isFavorite, isHidden: original.isHidden,
            albums: editableAlbums
        )
        try await PHPhotoLibrary.shared().performChanges {
            request.perform()
        }
        return request.newID
    }

    private final class SaveRequest: @unchecked Sendable {
        let file: URL
        let filename: String
        let creationDate: Date?
        let location: CLLocation?
        let isFavorite: Bool
        let isHidden: Bool
        let albums: [PHAssetCollection]
        var newID: String?

        init(file: URL, filename: String, creationDate: Date?, location: CLLocation?,
             isFavorite: Bool, isHidden: Bool, albums: [PHAssetCollection]) {
            self.file = file
            self.filename = filename
            self.creationDate = creationDate
            self.location = location
            self.isFavorite = isFavorite
            self.isHidden = isHidden
            self.albums = albums
        }

        func perform() {
            let creation = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            options.originalFilename = filename
            creation.addResource(with: .video, fileURL: file, options: options)
            creation.creationDate = creationDate
            creation.location = location
            creation.isFavorite = isFavorite
            creation.isHidden = isHidden
            guard let placeholder = creation.placeholderForCreatedAsset else { return }
            newID = placeholder.localIdentifier
            for album in albums {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        }
    }

    /// Moves the given assets to Recently Deleted. iOS asks the user first;
    /// throws if they say no.
    @concurrent
    static func delete(ids: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    // MARK: - Thumbnails

    @concurrent
    static func thumbnail(id: String, side: CGFloat) async -> UIImage? {
        guard let asset = asset(id: id) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let size = CGSize(width: side, height: side)
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill,
                                                  options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
