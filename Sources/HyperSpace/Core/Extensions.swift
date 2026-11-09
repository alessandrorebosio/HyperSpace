import Foundation

extension String {
    /// nil for the empty string.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Comparable {
    /// `self` limited to `range`.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
