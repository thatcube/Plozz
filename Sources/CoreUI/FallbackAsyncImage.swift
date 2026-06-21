#if canImport(SwiftUI)
import SwiftUI

/// Loads the first artwork URL that succeeds from an ordered list of candidates,
/// advancing to the next whenever one fails (or is missing). When every
/// candidate is exhausted it renders the supplied placeholder.
///
/// Used by cards so an episode with no thumbnail can transparently fall back to
/// its series artwork, then to a neutral placeholder, with a single declaration.
struct FallbackAsyncImage<Placeholder: View>: View {
    private let urls: [URL]
    private let placeholder: () -> Placeholder

    @State private var index = 0

    init(urls: [URL], @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.urls = urls
        self.placeholder = placeholder
    }

    var body: some View {
        if index < urls.count {
            AsyncImage(url: urls[index]) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .empty:
                    Color.primary.opacity(0.06)
                case .failure:
                    Color.clear.onAppear(perform: advance)
                @unknown default:
                    Color.clear.onAppear(perform: advance)
                }
            }
            .id(index)
        } else {
            placeholder()
        }
    }

    private func advance() {
        if index < urls.count { index += 1 }
    }
}
#endif
