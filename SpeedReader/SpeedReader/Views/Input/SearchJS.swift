import Foundation

/// Shared JS source for the WKWebView ⌘F search functions exposed to
/// `WKWebViewSearchTarget`: `_searchFind / _searchNext / _searchPrev /
/// _searchClear / _searchActiveWordIndex`.
///
/// Each WKWebView-backed preview embeds this in its HTML shell. Differences
/// per view (e.g. paginated book vs scrolling Markdown) are toggled via
/// `Options`.
enum SearchJS {
    struct Options {
        /// Selector for the walk root. `"body"` is fine for scrolling views;
        /// paginated views (BookPreviewView) should pass `"#content"` so
        /// matches don't land in page-nav chrome.
        var rootSelector: String = "body"
        /// If true, `_searchActivate` calls `window._goToWordPage(active)`
        /// when present — used by the paginated book view to flip to the page
        /// containing the active match.
        var useGoToWordPage: Bool = false
    }

    /// Wrap this in `<script>...</script>` in the HTML shell.
    static func source(_ options: Options = Options()) -> String {
        let activateScrollJS: String = options.useGoToWordPage
            ? """
              if (typeof window._goToWordPage === 'function') {
                  try { window._goToWordPage(ms[idx]); } catch (e) { /* ignore */ }
              } else {
                  ms[idx].scrollIntoView({block: 'center', behavior: 'smooth'});
              }
              """
            : "ms[idx].scrollIntoView({block: 'center', behavior: 'smooth'});"

        return """
        // === ⌘F Search support — driven from Swift via WKWebViewSearchTarget ===
        (function() {
            window.__rsvpSearchMatches = [];
            window.__rsvpSearchIdx = -1;

            function _escapeRegex(s) {
                return s.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
            }

            var SEARCH_WORD_RE = /https?:\\/\\/\\S+|["'\\u00AB\\u00BB\\u201E\\u201C\\u201D\\u2018\\u2019\\u201A\\u2039\\u203A]*[$€£¥₹₽¢]?[\\p{L}\\p{N}\\p{Extended_Pictographic}]+(?:[.,]\\d+)*(?:[-'][\\p{L}]+)*[%.,!?;:\\u2026"'\\u00AB\\u00BB\\u201E\\u201C\\u201D\\u2018\\u2019\\u201A\\u2039\\u203A]*/gu;

            function _rsvpSkipped(el) {
                if (!el) return false;
                return !!(el.closest('.katex') ||
                          el.closest('.rsvp-formula-render') ||
                          el.closest('pre') ||
                          el.closest('.sr-only') ||
                          el.closest('.footnote-backref'));
            }

            function _blockHost(node, root) {
                var el = node && node.parentElement;
                if (el && el.closest('mark.rsvp-search')) {
                    el = el.closest('mark.rsvp-search').parentElement;
                }
                while (el && el !== root) {
                    if (el.classList && el.classList.contains('table-cell')) return el;
                    var tag = (el.tagName || '').toUpperCase();
                    if (/^(P|DIV|H[1-6]|LI|TD|TH|PRE|BLOCKQUOTE|FIGCAPTION)$/.test(tag)) return el;
                    var display = '';
                    try { display = window.getComputedStyle(el).display; } catch (e) { display = ''; }
                    if (/^(block|list-item|table-cell|table-row|flex|grid)$/.test(display)) return el;
                    el = el.parentElement;
                }
                return root;
            }

            function _needsTextBoundary(prevNode, node, root) {
                if (!prevNode || !node) return false;
                return _blockHost(prevNode, root) !== _blockHost(node, root);
            }

            function _walkRoot() {
                return document.querySelector('\(options.rootSelector)') || document.body;
            }

            window._searchClear = function() {
                var marks = document.querySelectorAll('mark.rsvp-search');
                for (var i = 0; i < marks.length; i++) {
                    var m = marks[i];
                    var parent = m.parentNode;
                    if (!parent) continue;
                    while (m.firstChild) parent.insertBefore(m.firstChild, m);
                    parent.removeChild(m);
                    parent.normalize();
                }
                window.__rsvpSearchMatches = [];
                window.__rsvpSearchIdx = -1;
            };

            window._searchFind = function(query) {
                window._searchClear();
                if (!query || query.length === 0) return 0;
                var re;
                try { re = new RegExp(_escapeRegex(query), 'gi'); }
                catch (e) { return 0; }

                var root = _walkRoot();
                var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
                    acceptNode: function(n) {
                        if (!n.parentElement) return NodeFilter.FILTER_REJECT;
                        if (n.parentElement.closest('.rsvp-formula-token, .rsvp-image-token, .rsvp-code-token, .rsvp-table-token')) return NodeFilter.FILTER_REJECT;
                        if (n.parentElement.closest('.sr-only')) return NodeFilter.FILTER_REJECT;
                        if (n.parentElement.closest('mark.rsvp-search')) return NodeFilter.FILTER_REJECT;
                        return NodeFilter.FILTER_ACCEPT;
                    }
                });
                var textNodes = [];
                var node;
                while ((node = walker.nextNode())) textNodes.push(node);

                var matches = [];
                for (var ni = 0; ni < textNodes.length; ni++) {
                    var tn = textNodes[ni];
                    var text = tn.textContent;
                    re.lastIndex = 0;
                    var frags = [];
                    var last = 0;
                    var m;
                    while ((m = re.exec(text)) !== null) {
                        if (m[0].length === 0) { re.lastIndex++; continue; }
                        if (m.index > last) frags.push(document.createTextNode(text.slice(last, m.index)));
                        var mk = document.createElement('mark');
                        mk.className = 'rsvp-search';
                        mk.textContent = m[0];
                        frags.push(mk);
                        matches.push(mk);
                        last = m.index + m[0].length;
                    }
                    if (frags.length > 0) {
                        if (last < text.length) frags.push(document.createTextNode(text.slice(last)));
                        var p = tn.parentNode;
                        for (var fi = 0; fi < frags.length; fi++) p.insertBefore(frags[fi], tn);
                        p.removeChild(tn);
                    }
                }

                window.__rsvpSearchMatches = matches;
                window.__rsvpSearchIdx = matches.length > 0 ? 0 : -1;
                if (matches.length > 0) _searchActivate(0);
                return matches.length;
            };

            function _searchActivate(idx) {
                var ms = window.__rsvpSearchMatches;
                for (var i = 0; i < ms.length; i++) {
                    if (i === idx) ms[i].classList.add('rsvp-search-active');
                    else ms[i].classList.remove('rsvp-search-active');
                }
                window.__rsvpSearchIdx = idx;
                if (ms[idx]) {
                    \(activateScrollJS)
                }
            }

            window._searchNext = function() {
                var n = window.__rsvpSearchMatches.length;
                if (n === 0) return -1;
                var nxt = (window.__rsvpSearchIdx + 1) % n;
                _searchActivate(nxt);
                return nxt;
            };

            window._searchPrev = function() {
                var n = window.__rsvpSearchMatches.length;
                if (n === 0) return -1;
                var pr = (window.__rsvpSearchIdx - 1 + n) % n;
                _searchActivate(pr);
                return pr;
            };

            window._searchActiveWordIndex = function() {
                if (window.__rsvpSearchIdx < 0) return -1;
                var active = window.__rsvpSearchMatches[window.__rsvpSearchIdx];
                if (!active) return -1;
                // Splitting a host word into "f" / mark("oob") / "ar" creates fragments
                // that each match WORD_RE on their own — counting per text-node would
                // report 3 words where the engine still sees 1 ("foobar"). Concatenate
                // all RSVP-eligible text into one stream first, record where the
                // active mark starts, then run WORD_RE on the stream. The match whose
                // span covers `activeStart` is the host word.
                var root = _walkRoot();
                var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
                var fullText = '';
                var activeStart = -1;
                var prevTextNode = null;
                var node;
                while ((node = walker.nextNode())) {
                    if (_rsvpSkipped(node.parentElement)) continue;
                    if (_needsTextBoundary(prevTextNode, node, root)) {
                        fullText += '\\n';
                    }
                    if (active.contains(node) && activeStart < 0) {
                        activeStart = fullText.length;
                    }
                    fullText += node.textContent;
                    prevTextNode = node;
                }
                if (activeStart < 0) return -1;
                SEARCH_WORD_RE.lastIndex = 0;
                var idx = 0;
                var m;
                while ((m = SEARCH_WORD_RE.exec(fullText)) !== null) {
                    // Active position falls before this match (likely inside whitespace
                    // or RSVP-skipped territory we missed) — return idx as the next word.
                    if (m.index > activeStart) return idx;
                    // Active position lies within this match's span → this IS the word.
                    if (m.index + m[0].length > activeStart) return idx;
                    idx++;
                }
                return idx;
            };
        })();
        """
    }

    /// CSS for the search highlights. Drop into the existing `<style>` block.
    /// Derived from `HighlightStyle` so it stays in lock-step with every other
    /// backend — the only places that diverge are the fixed yellow/orange palette
    /// (intentionally independent of the user's reading-highlight preset) and
    /// the bold weight on the active match (border alone isn't enough contrast
    /// across the WK/SwiftUI/AppKit triple).
    static var css: String {
        """
        /* ⌘F search highlights */
        mark.rsvp-search { \(HighlightStyle.cssDeclaration(for: .searchMatch)); color: inherit; }
        mark.rsvp-search.rsvp-search-active { \(HighlightStyle.cssDeclaration(for: .searchActive)); color: inherit; }
        """
    }
}
