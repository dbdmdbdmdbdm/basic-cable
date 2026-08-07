import TVServices

/// Top Shelf: what's ON NOW across the lineup, one tile per guide channel
/// (favorites first), each deep-linking into the app tuned to that channel.
final class ContentProvider: TVTopShelfContentProvider {

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        Task {
            completionHandler(await content())
        }
    }

    private func content() async -> TVTopShelfContent? {
        guard let urlString = SharedConfig.get("serverURL"), !urlString.isEmpty,
              let client = TunarrClient(baseURLString: urlString) else { return nil }
        let favoriteIds = Set(
            (SharedConfig.get("favoriteChannels") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )

        guard let all = try? await client.fetchChannels(), !all.isEmpty else { return nil }
        let now = Date()
        let guide = (try? await client.fetchGuide(
            from: now.addingTimeInterval(-3600),
            to: now.addingTimeInterval(3 * 3600)
        )) ?? [:]

        // Collapse mix families to their primary (same rule as the app's
        // guide): a non-default groupTitle shared by several channels shows
        // one row, the lowest number.
        var familyCounts: [String: Int] = [:]
        for channel in all {
            if let key = familyKey(channel) { familyCounts[key, default: 0] += 1 }
        }
        var seenFamilies = Set<String>()
        let visible = all.sorted { $0.number < $1.number }.filter { channel in
            guard let key = familyKey(channel), familyCounts[key, default: 0] > 1 else { return true }
            return seenFamilies.insert(key).inserted
        }

        // Favorites lead, both groups in channel order.
        let ordered = visible.filter { favoriteIds.contains($0.id) }
            + visible.filter { !favoriteIds.contains($0.id) }

        let items: [TVTopShelfSectionedItem] = ordered.compactMap { channel in
            let item = TVTopShelfSectionedItem(identifier: channel.id)
            let onAir = (guide[channel.id] ?? []).first { $0.airs(at: now) }
            var title = "\(channel.number) · \(channel.name.uppercased())"
            if let program = onAir?.title, !program.isEmpty {
                title += " — \(program)"
            }
            item.title = title
            item.imageShape = .square
            if let path = channel.icon?.path, let url = URL(string: path) {
                item.setImageURL(url, for: [.screenScale1x, .screenScale2x])
            }
            if let link = URL(string: "basiccable://channel/\(channel.number)") {
                item.displayAction = TVTopShelfAction(url: link)
                item.playAction = TVTopShelfAction(url: link)
            }
            return item
        }
        guard !items.isEmpty else { return nil }

        let section = TVTopShelfItemCollection(items: items)
        section.title = "ON NOW"
        return TVTopShelfSectionedContent(sections: [section])
    }

    private func familyKey(_ channel: Channel) -> String? {
        let group = (channel.groupTitle ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard !group.isEmpty, group != "tunarr" else { return nil }
        return group
    }
}
