/// The intended rendering target for an artwork request.
///
/// Poster/landscape wall variants are downsampled before decode so low-power Apple
/// TV hardware doesn't spend CPU/memory decoding huge originals for small cards.
public enum ArtworkImageVariant: String, Sendable {
    case original
    case posterCard
    case landscapeCard
    case heroBackdrop

    var maxPixelSize: Int? {
        switch self {
        case .original: return nil
        // 420pt poster card at 2x, plus focused lift headroom.
        case .posterCard: return 960
        // 480pt landscape card at 2x, plus focused lift headroom.
        case .landscapeCard: return 1_200
        // Large hero/logo consumers still need high fidelity, but not full 4K.
        case .heroBackdrop: return 2_000
        }
    }
}
