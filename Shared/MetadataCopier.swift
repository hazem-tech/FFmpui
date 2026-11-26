//
//  MetadataCopier.swift
//  shrk
//
//  Copies the original video's metadata boxes, byte for byte, into a file
//  just encoded from it (by AVFoundation, or ffmpeg on the Mac):
//
//    • QuickTime dates: movie (mvhd), track (tkhd) and media (mdhd)
//      creation / modification times
//    • moov/udta: UserData (©mak ©mod ©xyz ©swr …), XMP (XMP_), iTunes tags,
//      GoPro (GPMF, FIRM, CAME …), DJI, Sony and other maker blocks
//    • moov/meta when it holds Apple Keys (mdta: creation date with time
//      zone, GPS, make / model / software, lens, focal length, Live Photo ID …)
//    • moov-level uuid boxes (e.g. Canon's CNCV / CNTH EXIF blocks)
//    • per track: udta / meta of the matching source track
//    • top-level uuid / meta boxes (MP4 XMP, Sony USMT / PROF …)
//
//  It also fits each video track's rotation offset to the track's size:
//  after scaling, an encoder may keep the original's offset (e.g. "turn 90°,
//  then shift by 720 pixels" on a frame that is now 360 pixels tall), which
//  shifts the picture in some players.
//
//  Only the moov box (and what follows it) is rewritten, and only when it
//  comes after all media data, which is how AVAssetWriter lays files out, so
//  no sample offsets move. Foundation only: it builds on macOS, iOS and Linux.
//  Used by both apps (on the Mac for every mode).
//

import Foundation

nonisolated enum MetadataCopier {
    enum Failure: LocalizedError {
        case malformed(String)
        case unsupportedLayout(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let what): "Unexpected file structure (\(what))"
            case .unsupportedLayout(let what): "Unsupported file layout (\(what))"
            }
        }
    }

    /// Largest single box that is copied; anything bigger is left out.
    static let maxCopiedBoxSize = 16 << 20
    /// Largest moov box that is read into memory.
    static let maxMoovSize = 256 << 20

    /// Copies the metadata of `source` into `output` (changed in place).
    /// Returns short notes about what was copied, for the log. Throws, leaving
    /// `output` untouched, when either file can't be handled.
    @discardableResult
    static func copy(from source: URL, to output: URL) throws -> [String] {
        var notes: [String] = []

        let sourceHandle = try FileHandle(forReadingFrom: source)
        defer { try? sourceHandle.close() }
        let sourceTop = try topLevelBoxes(sourceHandle)
        guard let sourceMoovBox = sourceTop.first(where: { $0.type == "moov" }) else {
            throw Failure.malformed("original has no moov box")
        }
        let sourceMoov = try read(sourceMoovBox, from: sourceHandle, limit: maxMoovSize)

        let outputHandle = try FileHandle(forUpdating: output)
        defer { try? outputHandle.close() }
        let outputTop = try topLevelBoxes(outputHandle)
        guard let moovIndex = outputTop.firstIndex(where: { $0.type == "moov" }) else {
            throw Failure.malformed("new file has no moov box")
        }
        let outputMoovBox = outputTop[moovIndex]
        let trailing = outputTop[(moovIndex + 1)...]
        if outputTop[..<moovIndex].contains(where: { $0.type == "moov" })
            || trailing.contains(where: { $0.type == "mdat" || $0.type == "moov" }) {
            throw Failure.unsupportedLayout("movie header is not after the media data")
        }
        let outputMoov = try read(outputMoovBox, from: outputHandle, limit: maxMoovSize)

        let newMoov = try rebuildMoov(output: outputMoov, source: sourceMoov, notes: &notes)

        // Boxes that followed moov in the new file (kept, minus padding).
        var tail: [UInt8] = []
        for box in trailing where box.type != "free" && box.type != "skip" {
            tail += try read(box, from: outputHandle, limit: maxCopiedBoxSize)
        }

        // Top-level metadata boxes of the original.
        var copiedTop = 0
        for box in sourceTop where box.type == "uuid" || box.type == "meta" {
            guard box.size <= maxCopiedBoxSize else {
                notes.append("left out a \(formatSize(box.size)) top-level \(box.type) box")
                continue
            }
            tail += try read(box, from: sourceHandle, limit: maxCopiedBoxSize)
            copiedTop += 1
        }
        if copiedTop > 0 { notes.append("\(copiedTop) top-level uuid/meta box\(copiedTop == 1 ? "" : "es")") }

        try outputHandle.seek(toOffset: UInt64(outputMoovBox.offset))
        try outputHandle.write(contentsOf: Data(newMoov))
        try outputHandle.write(contentsOf: Data(tail))
        try outputHandle.truncate(atOffset: UInt64(outputMoovBox.offset + newMoov.count + tail.count))
        try outputHandle.synchronize()

        return notes
    }

    // MARK: - moov / trak

    private static func rebuildMoov(output: [UInt8], source: [UInt8], notes: inout [String]) throws -> [UInt8] {
        let sourceKids = try children(of: source, box: try rootBox(source))
        let outputKids = try children(of: output, box: try rootBox(output))

        let sourceUdta = sourceKids.first { $0.type == "udta" }
        let sourceKeysMeta = sourceKids.first { $0.type == "meta" && metaHandler(in: source, meta: $0) == "mdta" }
        let sourceUUIDs = sourceKids.filter { $0.type == "uuid" }

        // Match tracks by handler type and order.
        var sourceTracksByHandler: [String: [Box]] = [:]
        for track in sourceKids where track.type == "trak" {
            sourceTracksByHandler[trackHandler(in: source, trak: track) ?? "?", default: []].append(track)
        }
        var usedPerHandler: [String: Int] = [:]
        var matchedTracks = 0

        var payload: [UInt8] = []
        for kid in outputKids {
            switch kid.type {
            case "mvhd":
                var bytes = slice(output, kid)
                if let sourceMvhd = sourceKids.first(where: { $0.type == "mvhd" }),
                   let dates = readDates(source, sourceMvhd) {
                    writeDates(&bytes, Box(type: kid.type, offset: 0, headerSize: kid.headerSize, size: kid.size), dates)
                    notes.append("movie dates")
                }
                payload += bytes
            case "trak":
                let handler = trackHandler(in: output, trak: kid) ?? "?"
                let index = usedPerHandler[handler, default: 0]
                usedPerHandler[handler] = index + 1
                if let candidates = sourceTracksByHandler[handler], index < candidates.count {
                    payload += try rebuildTrak(output: output, trak: kid, source: source, sourceTrak: candidates[index],
                                               isVideo: handler == "vide", notes: &notes)
                    matchedTracks += 1
                } else {
                    payload += slice(output, kid)
                }
            case "udta" where sourceUdta != nil:
                continue  // replaced by the original's below
            case "meta" where sourceKeysMeta != nil:
                continue  // replaced by the original's below
            default:
                payload += slice(output, kid)
            }
        }
        if matchedTracks > 0 { notes.append("\(matchedTracks) track\(matchedTracks == 1 ? "" : "s") (dates, udta/meta)") }

        if let sourceUdta {
            if sourceUdta.size <= maxCopiedBoxSize {
                payload += slice(source, sourceUdta)
                notes.append("user data \(formatSize(sourceUdta.size))")
            } else {
                notes.append("left out \(formatSize(sourceUdta.size)) of user data")
            }
        }
        if let sourceKeysMeta, sourceKeysMeta.size <= maxCopiedBoxSize {
            payload += slice(source, sourceKeysMeta)
            notes.append("Apple Keys")
        }
        for uuid in sourceUUIDs where uuid.size <= maxCopiedBoxSize {
            payload += slice(source, uuid)
        }
        if !sourceUUIDs.isEmpty { notes.append("\(sourceUUIDs.count) movie uuid box\(sourceUUIDs.count == 1 ? "" : "es")") }

        return makeBox("moov", payload)
    }

    private static func rebuildTrak(output: [UInt8], trak: Box, source: [UInt8], sourceTrak: Box,
                                    isVideo: Bool, notes: inout [String]) throws -> [UInt8] {
        let outputKids = try children(of: output, box: trak)
        let sourceKids = try children(of: source, box: sourceTrak)
        let sourceUdta = sourceKids.first { $0.type == "udta" }
        let sourceMeta = sourceKids.first { $0.type == "meta" }

        var payload: [UInt8] = []
        for kid in outputKids {
            switch kid.type {
            case "tkhd":
                var bytes = slice(output, kid)
                let local = Box(type: kid.type, offset: 0, headerSize: kid.headerSize, size: kid.size)
                if let sourceTkhd = sourceKids.first(where: { $0.type == "tkhd" }),
                   let dates = readDates(source, sourceTkhd) {
                    writeDates(&bytes, local, dates)
                }
                if isVideo, fitRotationOffset(&bytes, local) {
                    notes.append("rotation offset fitted to the new size")
                }
                payload += bytes
            case "mdia":
                // mdhd is patched in place, so mdia keeps its size.
                var bytes = slice(output, kid)
                if let outputMdhd = try children(of: output, box: kid).first(where: { $0.type == "mdhd" }),
                   let sourceMdia = sourceKids.first(where: { $0.type == "mdia" }),
                   let sourceMdhd = try children(of: source, box: sourceMdia).first(where: { $0.type == "mdhd" }),
                   let dates = readDates(source, sourceMdhd) {
                    let local = Box(type: "mdhd", offset: outputMdhd.offset - kid.offset,
                                    headerSize: outputMdhd.headerSize, size: outputMdhd.size)
                    writeDates(&bytes, local, dates)
                }
                payload += bytes
            case "udta" where sourceUdta != nil, "meta" where sourceMeta != nil:
                continue
            default:
                payload += slice(output, kid)
            }
        }
        if let sourceUdta, sourceUdta.size <= maxCopiedBoxSize { payload += slice(source, sourceUdta) }
        if let sourceMeta, sourceMeta.size <= maxCopiedBoxSize { payload += slice(source, sourceMeta) }
        return makeBox("trak", payload)
    }

    /// Handler type of a track (trak/mdia/hdlr), e.g. "vide", "soun", "tmcd", "meta".
    private static func trackHandler(in bytes: [UInt8], trak: Box) -> String? {
        guard let mdia = (try? children(of: bytes, box: trak))?.first(where: { $0.type == "mdia" }),
              let hdlr = (try? children(of: bytes, box: mdia))?.first(where: { $0.type == "hdlr" })
        else { return nil }
        return handlerType(in: bytes, hdlr: hdlr)
    }

    /// Handler type of a meta box, e.g. "mdta" (Apple Keys) or "mdir" (iTunes).
    private static func metaHandler(in bytes: [UInt8], meta: Box) -> String? {
        guard let hdlr = (try? children(of: bytes, box: meta))?.first(where: { $0.type == "hdlr" }) else { return nil }
        return handlerType(in: bytes, hdlr: hdlr)
    }

    /// hdlr: version/flags (4), pre_defined / component type (4), handler type (4).
    private static func handlerType(in bytes: [UInt8], hdlr: Box) -> String? {
        let start = hdlr.payloadStart + 8
        guard start + 4 <= hdlr.end else { return nil }
        return fourCC(bytes, start)
    }

    // MARK: - Rotation

    /// tkhd after version/flags and the dates: track ID, reserved, duration,
    /// reserved (8), layer, alternate group, volume, reserved (2 each), then
    /// the 3×3 matrix (a b u / c d v / x y w; a b c d x y in 16.16 fixed
    /// point) and the width and height (16.16).
    /// The matrix maps (px, py) to (a·px + c·py + x, b·px + d·py + y); the
    /// right offset puts the turned frame's corner back at (0, 0), e.g.
    /// x = height for a 90° turn, as cameras write it. Returns true when it
    /// changed something.
    private static func fitRotationOffset(_ bytes: inout [UInt8], _ tkhd: Box) -> Bool {
        let start = tkhd.payloadStart
        guard start + 4 <= tkhd.end else { return false }
        let matrix = start + (bytes[start] == 1 ? 36 : 24) + 16
        guard matrix + 44 <= tkhd.end else { return false }
        func fixed(_ at: Int) -> Double { Double(Int32(bitPattern: be32(bytes, at))) / 65536 }
        let a = fixed(matrix), b = fixed(matrix + 4), c = fixed(matrix + 12), d = fixed(matrix + 16)
        let width = Double(be32(bytes, matrix + 36)) / 65536
        let height = Double(be32(bytes, matrix + 40)) / 65536
        guard width > 0, height > 0 else { return false }
        let corners = [(0.0, 0.0), (width, 0.0), (0.0, height), (width, height)]
        let x = -(corners.map { a * $0.0 + c * $0.1 }.min() ?? 0)
        let y = -(corners.map { b * $0.0 + d * $0.1 }.min() ?? 0)
        let newX = Int32((x * 65536).rounded()), newY = Int32((y * 65536).rounded())
        let oldX = Int32(bitPattern: be32(bytes, matrix + 24)), oldY = Int32(bitPattern: be32(bytes, matrix + 28))
        guard newX != oldX || newY != oldY else { return false }
        putBE32(&bytes, matrix + 24, UInt32(bitPattern: newX))
        putBE32(&bytes, matrix + 28, UInt32(bitPattern: newY))
        return true
    }

    // MARK: - Dates

    private struct Dates {
        var created: UInt64
        var modified: UInt64
    }

    /// mvhd / tkhd / mdhd all start with version (1), flags (3), then the
    /// creation and modification times: 32-bit in version 0, 64-bit in version 1.
    private static func readDates(_ bytes: [UInt8], _ box: Box) -> Dates? {
        let start = box.payloadStart
        guard start + 4 <= box.end else { return nil }
        if bytes[start] == 1 {
            guard start + 20 <= box.end else { return nil }
            return Dates(created: be64(bytes, start + 4), modified: be64(bytes, start + 12))
        }
        guard start + 12 <= box.end else { return nil }
        return Dates(created: UInt64(be32(bytes, start + 4)), modified: UInt64(be32(bytes, start + 8)))
    }

    private static func writeDates(_ bytes: inout [UInt8], _ box: Box, _ dates: Dates) {
        let start = box.payloadStart
        guard start + 4 <= box.end else { return }
        if bytes[start] == 1 {
            guard start + 20 <= box.end else { return }
            putBE64(&bytes, start + 4, dates.created)
            putBE64(&bytes, start + 12, dates.modified)
        } else {
            guard start + 12 <= box.end else { return }
            putBE32(&bytes, start + 4, UInt32(clamping: dates.created))
            putBE32(&bytes, start + 8, UInt32(clamping: dates.modified))
        }
    }

    // MARK: - Boxes

    struct Box {
        var type: String
        var offset: Int
        var headerSize: Int
        var size: Int
        var payloadStart: Int { offset + headerSize }
        var end: Int { offset + size }
    }

    /// The top-level boxes of a file, read header by header.
    static func topLevelBoxes(_ handle: FileHandle) throws -> [Box] {
        let fileSize = Int(try handle.seekToEnd())
        var boxes: [Box] = []
        var offset = 0
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: UInt64(offset))
            let header = [UInt8](try handle.read(upToCount: 16) ?? Data())
            guard header.count >= 8 else { break }
            var size = Int(be32(header, 0))
            var headerSize = 8
            if size == 1 {
                guard header.count >= 16 else { throw Failure.malformed("truncated box header") }
                size = Int(clamping: be64(header, 8))
                headerSize = 16
            } else if size == 0 {
                size = fileSize - offset
            }
            guard size >= headerSize, offset + size <= fileSize else {
                throw Failure.malformed("box '\(fourCC(header, 4))' runs past the end of the file")
            }
            boxes.append(Box(type: fourCC(header, 4), offset: offset, headerSize: headerSize, size: size))
            offset += size
        }
        return boxes
    }

    private static func read(_ box: Box, from handle: FileHandle, limit: Int) throws -> [UInt8] {
        guard box.size <= limit else { throw Failure.unsupportedLayout("\(box.type) box is \(formatSize(box.size))") }
        try handle.seek(toOffset: UInt64(box.offset))
        let data = try handle.read(upToCount: box.size) ?? Data()
        guard data.count == box.size else { throw Failure.malformed("short read of \(box.type)") }
        return [UInt8](data)
    }

    /// A whole box held in its own byte array (offset 0).
    private static func rootBox(_ bytes: [UInt8]) throws -> Box {
        guard let box = try parseBoxes(bytes, in: 0..<bytes.count).first, box.size == bytes.count else {
            throw Failure.malformed("bad box")
        }
        return box
    }

    /// Child boxes of a container. A QuickTime `meta` has no version/flags,
    /// an ISO `meta` has 4 zero bytes of them before the children (a child
    /// box can't start with a zero size there).
    private static func children(of bytes: [UInt8], box: Box) throws -> [Box] {
        var start = box.payloadStart
        if box.type == "meta", start + 8 <= box.end, be32(bytes, start) == 0 {
            start += 4
        }
        return try parseBoxes(bytes, in: start..<box.end)
    }

    private static func parseBoxes(_ bytes: [UInt8], in range: Range<Int>) throws -> [Box] {
        var boxes: [Box] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = Int(be32(bytes, offset))
            var headerSize = 8
            if size == 1 {
                guard offset + 16 <= range.upperBound else { throw Failure.malformed("truncated box header") }
                size = Int(clamping: be64(bytes, offset + 8))
                headerSize = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= headerSize, offset + size <= range.upperBound else {
                throw Failure.malformed("box '\(fourCC(bytes, offset + 4))' is too big for its parent")
            }
            boxes.append(Box(type: fourCC(bytes, offset + 4), offset: offset, headerSize: headerSize, size: size))
            offset += size
        }
        return boxes
    }

    private static func makeBox(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let typeBytes = Array(type.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
        var box: [UInt8] = []
        if payload.count + 8 <= Int(UInt32.max) {
            box.reserveCapacity(payload.count + 8)
            appendBE32(&box, UInt32(payload.count + 8))
            box += typeBytes
        } else {
            appendBE32(&box, 1)
            box += typeBytes
            appendBE64(&box, UInt64(payload.count + 16))
        }
        box += payload
        return box
    }

    private static func slice(_ bytes: [UInt8], _ box: Box) -> [UInt8] {
        Array(bytes[box.offset..<box.end])
    }

    // MARK: - Bytes

    private static func fourCC(_ bytes: [UInt8], _ at: Int) -> String {
        guard at + 4 <= bytes.count else { return "????" }
        // Latin-1, so "©mak" (0xA9 'm' 'a' 'k') reads as expected.
        return String(bytes[at..<at + 4].map { Character(Unicode.Scalar($0)) })
    }

    private static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func be64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        bytes[at..<at + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func putBE32(_ bytes: inout [UInt8], _ at: Int, _ value: UInt32) {
        for index in 0..<4 { bytes[at + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index)) }
    }

    private static func putBE64(_ bytes: inout [UInt8], _ at: Int, _ value: UInt64) {
        for index in 0..<8 { bytes[at + index] = UInt8(truncatingIfNeeded: value >> (56 - 8 * index)) }
    }

    private static func appendBE32(_ bytes: inout [UInt8], _ value: UInt32) {
        for index in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: value >> (24 - 8 * index))) }
    }

    private static func appendBE64(_ bytes: inout [UInt8], _ value: UInt64) {
        for index in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: value >> (56 - 8 * index))) }
    }

    private static func formatSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
