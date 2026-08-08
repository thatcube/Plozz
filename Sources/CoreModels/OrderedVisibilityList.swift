import Foundation

/// Pure ordering/enablement logic for **any** "one ordered list split by a Disabled
/// divider" preference: items above the divider are on (in priority/display order),
/// items below it are off.
///
/// Factored out of the metadata-providers screen so the exact same model — and the
/// exact same interaction — backs every reorder-and-hide surface in the app
/// (metadata providers, navigation libraries, …). Generic over the element so a
/// caller only has to supply a `Hashable` identity; SwiftUI-free so it stays
/// unit-testable without a running view hierarchy.
///
/// The divider is a real member of the flattened list (see ``ListItem``) rather
/// than an implicit boundary: that is what lets a single drag (iOS) or a single
/// d-pad step (tvOS) *cross* it and thereby change enablement, instead of needing a
/// separate toggle control.
public enum OrderedVisibilityList {
    /// The two sections the UI shows: ``enabled`` above the divider (in order),
    /// ``disabled`` below it.
    public struct Sections<Element: Hashable>: Equatable {
        public var enabled: [Element]
        public var disabled: [Element]

        public init(enabled: [Element], disabled: [Element]) {
            self.enabled = enabled
            self.disabled = disabled
        }

        /// Every element, enabled first then disabled — the flattened order the
        /// tvOS lift-and-step interaction reasons about.
        public var combined: [Element] { enabled + disabled }
    }

    /// The flattened representation used by the native iOS `List` reorder
    /// affordance. The divider stays in the collection so dragging an element
    /// across it changes enablement; the placeholder is appended after the divider
    /// when nothing is disabled yet, giving a visible drop target.
    public enum ListItem<Element: Hashable>: Hashable {
        case element(Element)
        case divider
        case disabledPlaceholder

        /// The wrapped element, or `nil` for the divider/placeholder rows.
        public var element: Element? {
            guard case let .element(element) = self else { return nil }
            return element
        }
    }

    public static func listItems<Element: Hashable>(
        for sections: Sections<Element>
    ) -> [ListItem<Element>] {
        sections.enabled.map(ListItem.element)
            + [.divider]
            + (sections.disabled.isEmpty
                ? [.disabledPlaceholder]
                : sections.disabled.map(ListItem.element))
    }

    /// Applies native `List.onMove` offsets to the flattened list, then splits it
    /// back at the divider. The divider itself is immovable; elements dropped
    /// before it are enabled, elements dropped after it are disabled.
    public static func moving<Element: Hashable>(
        fromOffsets offsets: IndexSet,
        toOffset destination: Int,
        in sections: Sections<Element>
    ) -> Sections<Element> {
        var items = listItems(for: sections)
        let movableOffsets = offsets
            .filter { items.indices.contains($0) && items[$0] != .divider && items[$0] != .disabledPlaceholder }
            .sorted()
        guard !movableOffsets.isEmpty else { return sections }

        let moving = movableOffsets.map { items[$0] }
        for index in movableOffsets.reversed() {
            items.remove(at: index)
        }
        let removedBeforeDestination = movableOffsets.filter { $0 < destination }.count
        let insertion = max(0, min(items.count, destination - removedBeforeDestination))
        items.insert(contentsOf: moving, at: insertion)

        guard let divider = items.firstIndex(of: .divider) else { return sections }
        let enabled = items[..<divider].compactMap(\.element)
        let disabled = items[items.index(after: divider)...].compactMap(\.element)
        return Sections(enabled: enabled, disabled: disabled)
    }

    /// `order` with `element` moved by `delta` (clamped: out-of-range is a no-op).
    public static func moved<Element: Hashable>(
        _ element: Element,
        by delta: Int,
        in order: [Element]
    ) -> [Element] {
        var order = order
        guard let index = order.firstIndex(of: element) else { return order }
        let target = index + delta
        guard order.indices.contains(target) else { return order }
        order.swapAt(index, target)
        return order
    }

    /// Moves `element` from the enabled section to the top of the disabled section.
    public static func disabling<Element: Hashable>(
        _ element: Element,
        in sections: Sections<Element>
    ) -> Sections<Element> {
        guard sections.enabled.contains(element) else { return sections }
        var next = sections
        next.enabled.removeAll { $0 == element }
        next.disabled.insert(element, at: 0)
        return next
    }

    /// Moves `element` from the disabled section to the bottom of the enabled
    /// section.
    public static func enabling<Element: Hashable>(
        _ element: Element,
        in sections: Sections<Element>
    ) -> Sections<Element> {
        guard sections.disabled.contains(element) else { return sections }
        var next = sections
        next.disabled.removeAll { $0 == element }
        next.enabled.append(element)
        return next
    }

    /// One step of the lifted-row move, treating the whole thing as a single
    /// ordered list with the divider between `enabled` (above) and `disabled`
    /// (below). Moving up raises priority; crossing the divider upward re-enables
    /// (at the bottom of enabled). Moving down lowers priority; crossing the
    /// divider downward disables (at the top of disabled). At the very top/bottom
    /// it's a no-op.
    public static func stepped<Element: Hashable>(
        _ element: Element,
        up: Bool,
        in sections: Sections<Element>
    ) -> Sections<Element> {
        var next = sections
        if let index = next.enabled.firstIndex(of: element) {
            if up {
                guard index > 0 else { return sections }          // already highest
                next.enabled.swapAt(index, index - 1)
            } else if index < next.enabled.count - 1 {
                next.enabled.swapAt(index, index + 1)
            } else {
                // Crossing the divider downward → disable at the top of disabled.
                next.enabled.remove(at: index)
                next.disabled.insert(element, at: 0)
            }
            return next
        }
        if let index = next.disabled.firstIndex(of: element) {
            if !up {
                guard index < next.disabled.count - 1 else { return sections }  // already lowest
                next.disabled.swapAt(index, index + 1)
            } else if index > 0 {
                next.disabled.swapAt(index, index - 1)
            } else {
                // Crossing the divider upward → re-enable at the bottom of enabled.
                next.disabled.remove(at: index)
                next.enabled.append(element)
            }
            return next
        }
        return sections
    }

    /// Splits `available` into enabled/disabled sections using a persisted order +
    /// hidden set, appending anything the persisted order has never seen so a newly
    /// discovered element shows up (enabled) instead of silently vanishing.
    ///
    /// This is the resolution rule every "reorder + hide a discovered collection"
    /// preference needs: persisted order is advisory, the live collection is
    /// authoritative.
    public static func resolving<Element: Hashable>(
        available: [Element],
        order: [Element],
        hidden: Set<Element>
    ) -> Sections<Element> {
        let availableSet = Set(available)
        var seen: Set<Element> = []
        var ordered: [Element] = []
        for element in order where availableSet.contains(element) && seen.insert(element).inserted {
            ordered.append(element)
        }
        for element in available where seen.insert(element).inserted {
            ordered.append(element)
        }
        return Sections(
            enabled: ordered.filter { !hidden.contains($0) },
            disabled: ordered.filter { hidden.contains($0) }
        )
    }
}
