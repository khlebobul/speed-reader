import Foundation

/// Abstraction over searchable preview backends (WKWebView, PDFView, words[]).
/// `SearchBarView` drives any conforming target via this protocol.
@MainActor
protocol SearchTarget: AnyObject {
    /// Finds all matches for `query` and activates the first one.
    /// - Returns: total number of matches.
    func find(query: String) async -> Int

    /// Activates the next match (wraps around).
    /// - Returns: new active match index, or -1 if no matches.
    func next() async -> Int

    /// Activates the previous match (wraps around).
    /// - Returns: new active match index, or -1 if no matches.
    func prev() async -> Int

    /// Clears all highlights and resets state.
    func clear()

    /// RSVP word index of the currently active match — used by "Read from here".
    /// - Returns: word index in `RSVPEngine.words`, or -1 if unavailable.
    func activeWordIndex() async -> Int
}
