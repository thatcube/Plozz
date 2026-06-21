import TVServices

/// Supplies content for the tvOS Top Shelf — the banner shown above the app
/// grid when Plozz is in the top row of the Home screen.
///
/// This runs in a separate, short-lived, memory-constrained process. Rather
/// than re-implement the Jellyfin client (and its Keychain auth) here, it
/// renders the snapshot the main app last published into the shared App Group
/// container. Jellyfin image URLs are token-free and absolute, so the shelf
/// cards load their artwork directly. Each card deep-links back into the app to
/// start playback (`plozz://item/{id}`).
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(
        completionHandler: @escaping (TVTopShelfContent?) -> Void
    ) {
        completionHandler(Self.makeContent())
    }

    private static func makeContent() -> TVTopShelfContent? {
        guard let snapshot = TopShelfStore.load() else { return nil }

        let collections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] =
            snapshot.sections.compactMap { section in
                let items = section.items.map(makeItem)
                guard !items.isEmpty else { return nil }
                let collection = TVTopShelfItemCollection(items: items)
                collection.title = section.title
                return collection
            }

        guard !collections.isEmpty else { return nil }
        return TVTopShelfSectionedContent(sections: collections)
    }

    private static func makeItem(_ item: TopShelfSnapshot.Item) -> TVTopShelfSectionedItem {
        let shelfItem = TVTopShelfSectionedItem(identifier: item.id)
        shelfItem.title = item.title
        shelfItem.imageShape = .hdtv

        if let imageURL = item.imageURL {
            shelfItem.setImageURL(imageURL, for: .screenScale1x)
            shelfItem.setImageURL(imageURL, for: .screenScale2x)
        }

        let deepLink = TopShelf.itemDeepLink(id: item.id)
        let action = TVTopShelfAction(url: deepLink)
        shelfItem.displayAction = action
        shelfItem.playAction = action

        return shelfItem
    }
}
