import Foundation

/// "(3) Song name - YouTube" → "Song name". Used when a browser won't run page scripts, so the tab title is all we get.
public func cleanMediaTabTitle(_ title: String) -> String {
    var text = title.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
    for suffix in [" - YouTube Music", " - YouTube", " | Free Listening on SoundCloud"] where text.hasSuffix(suffix) {
        text.removeLast(suffix.count)
    }
    return text
}
