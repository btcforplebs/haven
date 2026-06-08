// Negentropy.swift
// Pure-Swift NIP-77 Negentropy set reconciliation engine.
// Ported from: go-nostr/nip77/negentropy/ (types, encoding, hex, accumulator, vector, negentropy)

import Foundation
import CryptoKit

// MARK: - Constants

private let protocolVersion: UInt8 = 0x61
private let maxTimestamp: Int64 = Int64.max
private let negentropyBuckets = 16
let negentropyFingerprintSize = 16
let negentropyFrameSizeLimit = 1_048_576

// MARK: - Mode

enum NegentropyMode: Int {
    case skip = 0
    case fingerprint = 1
    case idList = 2
}

// MARK: - Item & Bound

struct NegentropyItem: Comparable {
    let timestamp: Int64
    let id: String

    static func < (lhs: NegentropyItem, rhs: NegentropyItem) -> Bool {
        if lhs.timestamp == rhs.timestamp {
            return lhs.id < rhs.id
        }
        return lhs.timestamp < rhs.timestamp
    }
}

struct NegentropyBound {
    let item: NegentropyItem

    static let infinite = NegentropyBound(item: NegentropyItem(timestamp: maxTimestamp, id: ""))
}

// MARK: - Hex Reader

final class NegentropyHexReader {
    private let source: String
    private var idx: Int = 0

    init(_ source: String) {
        self.source = source
    }

    var remaining: Int { source.count - idx }

    func readHexBytes(_ count: Int) throws -> [UInt8] {
        let hexCount = count * 2
        let end = idx + hexCount
        guard end <= source.count else { throw NegentropyError.unexpectedEOF }
        let start = source.index(source.startIndex, offsetBy: idx)
        let stop = source.index(source.startIndex, offsetBy: end)
        let hex = String(source[start..<stop])
        idx = end
        return try hexToBytes(hex)
    }

    func readHexByte() throws -> UInt8 {
        let bytes = try readHexBytes(1)
        return bytes[0]
    }

    func readString(_ count: Int) throws -> String {
        let end = idx + count
        guard end <= source.count else { throw NegentropyError.unexpectedEOF }
        let start = source.index(source.startIndex, offsetBy: idx)
        let stop = source.index(source.startIndex, offsetBy: end)
        let result = String(source[start..<stop])
        idx = end
        return result
    }
}

// MARK: - Hex Writer

final class NegentropyHexWriter {
    private var buf: String

    init(capacity: Int = 256) {
        buf = ""
        buf.reserveCapacity(capacity)
    }

    var count: Int { buf.count }

    var hex: String { buf }

    func reset() { buf = "" }

    func writeHex(_ hexString: String) {
        buf.append(hexString)
    }

    func writeByte(_ b: UInt8) {
        buf.append(bytesToHex([b]))
    }

    func writeBytes(_ bytes: [UInt8]) {
        buf.append(bytesToHex(bytes))
    }
}

// MARK: - Accumulator

struct NegentropyAccumulator {
    private var buf = [UInt8](repeating: 0, count: 32)

    mutating func reset() {
        for i in 0..<32 { buf[i] = 0 }
    }

    mutating func addBytes(_ other: [UInt8]) {
        var currCarry: UInt32 = 0
        var nextCarry: UInt32 = 0

        for i in 0..<8 {
            let offset = i * 4
            let orig = readLE32(buf, offset)
            let otherV = readLE32(other, offset)

            let next = orig &+ currCarry &+ otherV
            if next < orig || next < otherV {
                nextCarry = 1
            }

            buf[offset]   = UInt8(next & 0xFF)
            buf[offset+1] = UInt8((next >> 8) & 0xFF)
            buf[offset+2] = UInt8((next >> 16) & 0xFF)
            buf[offset+3] = UInt8((next >> 24) & 0xFF)
            currCarry = nextCarry
            nextCarry = 0
        }
    }

    func getFingerprint(_ n: Int) -> String {
        var input = buf
        input.append(contentsOf: encodeVarInt(n))
        let hash = SHA256.hash(data: input)
        let bytes = Array(hash.prefix(negentropyFingerprintSize))
        return bytesToHex(bytes)
    }

    private func readLE32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        return UInt32(data[offset])
             | (UInt32(data[offset+1]) << 8)
             | (UInt32(data[offset+2]) << 16)
             | (UInt32(data[offset+3]) << 24)
    }

}

// MARK: - Vector

final class NegentropyVector {
    private var items: [NegentropyItem] = []
    private var sealed = false
    private var acc = NegentropyAccumulator()

    func insert(timestamp: Int64, id: String) {
        precondition(id.count == 64, "bad id size: expected 64 hex chars, got \(id.count)")
        items.append(NegentropyItem(timestamp: timestamp, id: id))
    }

    var size: Int { items.count }

    func seal() {
        precondition(!sealed, "trying to seal an already sealed vector")
        sealed = true
        items.sort()
    }

    func getBound(_ idx: Int) -> NegentropyBound {
        if idx < items.count {
            return NegentropyBound(item: items[idx])
        }
        return .infinite
    }

    func rangeItems(_ begin: Int, _ end: Int) -> ArraySlice<NegentropyItem> {
        return items[begin..<end]
    }

    func findLowerBound(_ begin: Int, _ end: Int, _ bound: NegentropyBound) -> Int {
        // Binary search for the first element >= bound.item
        var lo = begin
        var hi = end
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if items[mid] < bound.item {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    func fingerprint(_ begin: Int, _ end: Int) -> String {
        acc.reset()

        var tmp = [UInt8](repeating: 0, count: 32)
        for i in begin..<end {
            let id = items[i].id
            tmp = try! hexToBytes(id)
            acc.addBytes(tmp)
        }

        return acc.getFingerprint(end - begin)
    }
}

// MARK: - Encoding Helpers

func readVarInt(_ reader: NegentropyHexReader) throws -> Int {
    var res = 0
    while true {
        let b = try reader.readHexByte()
        res = (res << 7) | (Int(b) & 127)
        if (b & 128) == 0 { break }
    }
    return res
}

func writeVarInt(_ w: NegentropyHexWriter, _ n: Int) {
    if n == 0 {
        w.writeByte(0)
        return
    }
    w.writeBytes(encodeVarInt(n))
}

func encodeVarInt(_ n: Int) -> [UInt8] {
    if n == 0 { return [0] }

    var result = [UInt8](repeating: 0, count: 8)
    var idx = 7
    var val = n

    while val != 0 {
        result[idx] = UInt8(val & 0x7F)
        val >>= 7
        idx -= 1
    }

    result = Array(result[(idx+1)...])
    for i in 0..<(result.count - 1) {
        result[i] |= 0x80
    }
    return result
}

func getMinimalBound(prev: NegentropyItem, curr: NegentropyItem) -> NegentropyBound {
    if curr.timestamp != prev.timestamp {
        return NegentropyBound(item: NegentropyItem(timestamp: curr.timestamp, id: ""))
    }

    // Match Go reference: check first 16 bytes (32 hex chars) only
    var sharedPrefixBytes = 0
    let prevChars = Array(prev.id)
    let currChars = Array(curr.id)

    var i = 0
    while i < 32 {
        if prevChars[i] == currChars[i] && prevChars[i+1] == currChars[i+1] {
            sharedPrefixBytes += 1
            i += 2
        } else {
            break
        }
    }

    let endIdx = curr.id.index(curr.id.startIndex, offsetBy: (sharedPrefixBytes + 1) * 2)
    let partialId = String(curr.id[curr.id.startIndex..<endIdx])
    return NegentropyBound(item: NegentropyItem(timestamp: curr.timestamp, id: partialId))
}

// MARK: - Negentropy Engine

enum NegentropyError: Error {
    case unexpectedEOF
    case unsupportedProtocolVersion(UInt8)
    case unexpectedMode(Int)
    case decodeFailed(String)
}

final class Negentropy {
    private let storage: NegentropyVector
    private var initialized = false
    let frameSizeLimit: Int
    private var isClient = false
    private var lastTimestampIn: Int64 = 0
    private var lastTimestampOut: Int64 = 0

    init(storage: NegentropyVector, frameSizeLimit: Int = negentropyFrameSizeLimit) {
        if frameSizeLimit != 0 && frameSizeLimit < 4096 {
            preconditionFailure("frameSizeLimit can't be smaller than 4096, was \(frameSizeLimit)")
        }
        self.storage = storage
        self.frameSizeLimit = frameSizeLimit == 0 ? Int.max : frameSizeLimit
    }

    // MARK: Client API

    func start() -> String {
        initialized = true
        isClient = true

        let output = NegentropyHexWriter(capacity: 2 + storage.size * 64)
        output.writeByte(protocolVersion)
        splitRange(0, storage.size, .infinite, output)

        return output.hex
    }

    struct ReconcileResult {
        let nextMessage: String?
        let haveNots: [String]
        let haves: [String]
    }

    func reconcile(_ msg: String) throws -> ReconcileResult {
        initialized = true
        let reader = NegentropyHexReader(msg)

        var haveNots: [String] = []
        var haves: [String] = []

        let output = try reconcileAux(reader, haveNots: &haveNots, haves: &haves)

        // output length of 2 hex chars = just the protocol version byte, meaning reconciliation is complete
        if output.count == 2 && isClient {
            return ReconcileResult(nextMessage: nil, haveNots: haveNots, haves: haves)
        }

        return ReconcileResult(nextMessage: output, haveNots: haveNots, haves: haves)
    }

    // MARK: Encoding (instance methods, use delta-compressed timestamps)

    private func readTimestamp(_ reader: NegentropyHexReader) throws -> Int64 {
        let delta = try readVarInt(reader)

        if delta == 0 {
            lastTimestampIn = maxTimestamp
            return maxTimestamp
        }

        let timestamp = lastTimestampIn + Int64(delta - 1)
        lastTimestampIn = timestamp
        return timestamp
    }

    private func readBound(_ reader: NegentropyHexReader) throws -> NegentropyBound {
        let timestamp = try readTimestamp(reader)
        let length = try readVarInt(reader)
        let id = try reader.readString(length * 2)
        return NegentropyBound(item: NegentropyItem(timestamp: timestamp, id: id))
    }

    private func writeTimestamp(_ w: NegentropyHexWriter, _ timestamp: Int64) {
        if timestamp == maxTimestamp {
            lastTimestampOut = maxTimestamp
            writeVarInt(w, 0)
            return
        }

        let delta = timestamp - lastTimestampOut
        lastTimestampOut = timestamp
        writeVarInt(w, Int(delta + 1))
    }

    private func writeBound(_ w: NegentropyHexWriter, _ bound: NegentropyBound) {
        writeTimestamp(w, bound.item.timestamp)
        writeVarInt(w, bound.item.id.count / 2)
        w.writeHex(bound.item.id)
    }

    // MARK: Core Reconciliation

    private func reconcileAux(_ reader: NegentropyHexReader, haveNots: inout [String], haves: inout [String]) throws -> String {
        lastTimestampIn = 0
        lastTimestampOut = 0

        let fullOutput = NegentropyHexWriter(capacity: 5000)
        fullOutput.writeByte(protocolVersion)

        let pv = try reader.readHexByte()
        if pv != protocolVersion {
            if isClient {
                throw NegentropyError.unsupportedProtocolVersion(pv)
            }
            return fullOutput.hex
        }

        var prevBound = NegentropyBound(item: NegentropyItem(timestamp: 0, id: ""))
        var prevIndex = 0
        var skipping = false

        let partialOutput = NegentropyHexWriter(capacity: 100)

        while reader.remaining > 0 {
            partialOutput.reset()

            let currBound = try readBound(reader)
            let modeVal = try readVarInt(reader)
            guard let mode = NegentropyMode(rawValue: modeVal) else {
                throw NegentropyError.unexpectedMode(modeVal)
            }

            let lower = prevIndex
            var upper = storage.findLowerBound(prevIndex, storage.size, currBound)

            func finishSkip() {
                if skipping {
                    skipping = false
                    writeBound(partialOutput, prevBound)
                    partialOutput.writeByte(UInt8(NegentropyMode.skip.rawValue))
                }
            }

            switch mode {
            case .skip:
                skipping = true

            case .fingerprint:
                let theirFingerprint = try reader.readString(negentropyFingerprintSize * 2)
                let ourFingerprint = storage.fingerprint(lower, upper)

                if theirFingerprint == ourFingerprint {
                    skipping = true
                } else {
                    finishSkip()
                    splitRange(lower, upper, currBound, partialOutput)
                }

            case .idList:
                let numIds = try readVarInt(reader)

                var theirItems = Set<String>()
                theirItems.reserveCapacity(numIds)
                for _ in 0..<numIds {
                    let id = try reader.readString(64)
                    theirItems.insert(id)
                }

                for item in storage.rangeItems(lower, upper) {
                    if theirItems.contains(item.id) {
                        theirItems.remove(item.id)
                    } else {
                        if isClient {
                            haves.append(item.id)
                        }
                    }
                }

                if isClient {
                    for id in theirItems {
                        haveNots.append(id)
                    }
                    skipping = true
                } else {
                    finishSkip()

                    var responseIds = ""
                    responseIds.reserveCapacity(64 * 100)
                    var responses = 0

                    var endBound = currBound

                    for i in lower..<upper {
                        let item = storage.rangeItems(i, i + 1).first!
                        if frameSizeLimit - 200 < fullOutput.count / 2 + responseIds.count / 2 {
                            endBound = NegentropyBound(item: item)
                            upper = i
                            break
                        }
                        responseIds.append(item.id)
                        responses += 1
                    }

                    writeBound(partialOutput, endBound)
                    partialOutput.writeByte(UInt8(NegentropyMode.idList.rawValue))
                    writeVarInt(partialOutput, responses)
                    partialOutput.writeHex(responseIds)

                    fullOutput.writeHex(partialOutput.hex)
                    partialOutput.reset()
                }
            }

            if frameSizeLimit - 200 < fullOutput.count / 2 + partialOutput.count / 2 {
                let remainingFingerprint = storage.fingerprint(upper, storage.size)
                writeBound(fullOutput, .infinite)
                fullOutput.writeByte(UInt8(NegentropyMode.fingerprint.rawValue))
                fullOutput.writeHex(remainingFingerprint)
                break
            } else {
                fullOutput.writeHex(partialOutput.hex)
            }

            prevIndex = upper
            prevBound = currBound
        }

        return fullOutput.hex
    }

    func splitRange(_ lower: Int, _ upper: Int, _ upperBound: NegentropyBound, _ output: NegentropyHexWriter) {
        let numElems = upper - lower

        if numElems < negentropyBuckets * 2 {
            writeBound(output, upperBound)
            output.writeByte(UInt8(NegentropyMode.idList.rawValue))
            writeVarInt(output, numElems)

            for item in storage.rangeItems(lower, upper) {
                output.writeHex(item.id)
            }
        } else {
            let itemsPerBucket = numElems / negentropyBuckets
            let bucketsWithExtra = numElems % negentropyBuckets
            var curr = lower

            for i in 0..<negentropyBuckets {
                var bucketSize = itemsPerBucket
                if i < bucketsWithExtra {
                    bucketSize += 1
                }
                let ourFingerprint = storage.fingerprint(curr, curr + bucketSize)
                curr += bucketSize

                let nextBound: NegentropyBound
                if curr == upper {
                    nextBound = upperBound
                } else {
                    let prevItem = storage.rangeItems(curr - 1, curr).first!
                    let currItem = storage.rangeItems(curr, curr + 1).first!
                    nextBound = getMinimalBound(prev: prevItem, curr: currItem)
                }

                writeBound(output, nextBound)
                output.writeByte(UInt8(NegentropyMode.fingerprint.rawValue))
                output.writeHex(ourFingerprint)
            }
        }
    }
}

// MARK: - Hex Utilities

private func hexToBytes(_ hex: String) throws -> [UInt8] {
    let chars = Array(hex)
    guard chars.count % 2 == 0 else { throw NegentropyError.decodeFailed("odd length hex") }
    var bytes = [UInt8]()
    bytes.reserveCapacity(chars.count / 2)
    var i = 0
    while i < chars.count {
        guard let hi = hexVal(chars[i]), let lo = hexVal(chars[i+1]) else {
            throw NegentropyError.decodeFailed("invalid hex char")
        }
        bytes.append((hi << 4) | lo)
        i += 2
    }
    return bytes
}

private func bytesToHex(_ bytes: [UInt8]) -> String {
    let hexChars: [Character] = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"]
    var result = ""
    result.reserveCapacity(bytes.count * 2)
    for b in bytes {
        result.append(hexChars[Int(b >> 4)])
        result.append(hexChars[Int(b & 0x0F)])
    }
    return result
}

private func hexVal(_ c: Character) -> UInt8? {
    switch c {
    case "0"..."9": return UInt8(c.asciiValue! - Character("0").asciiValue!)
    case "a"..."f": return UInt8(c.asciiValue! - Character("a").asciiValue! + 10)
    case "A"..."F": return UInt8(c.asciiValue! - Character("A").asciiValue! + 10)
    default: return nil
    }
}
