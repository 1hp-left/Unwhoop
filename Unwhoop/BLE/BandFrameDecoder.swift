import WhoopProtocol

/// Independent GATT channels may interleave fragments. Mixing their buffers
/// can lose otherwise-valid R-R frames even while notifications remain active.
final class BandFrameDecoder {
    private var readers: [String: Reassembler] = [:]
    func feed(_ bytes: [UInt8], channel: String) -> [[UInt8]] {
        let reader = readers[channel] ?? Reassembler(family: .whoop5)
        readers[channel] = reader
        return reader.feed(bytes)
    }
    func reset() { readers.removeAll() }
}
