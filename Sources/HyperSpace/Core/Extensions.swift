import Foundation

extension String {
    /// nil for the empty string.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension URL {
    /// The path as shown to the user and kept in the preferences: `~` for the home folder.
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }

    /// The file a symbolic link stands for, even when that file is not there yet (a dotfiles
    /// folder not cloned): where to write, since an atomic write to a link replaces the link
    /// with a regular file. The URL itself when it is no link.
    var linkTarget: URL {
        var url = self
        // A chain of links is followed; a loop of them ends after a few steps.
        for _ in 0..<8 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { break }
            url = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        }
        return url
    }
}

/// An enum of the config whose cases are written by their lowercase raw value.
protocol ConfigNamed: RawRepresentable where RawValue == String {}

extension ConfigNamed {
    /// A name as written in the config, in any case.
    init?(configText text: String) { self.init(rawValue: text.lowercased()) }
}

extension Comparable {
    /// `self` limited to `range`.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
