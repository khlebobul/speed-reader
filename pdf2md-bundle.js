// Standalone pdf-to-markdown conversion for WKWebView
// Extracts PDF text via pdfjs-dist, runs jzillmann transformation pipeline, returns markdown

// Pre-load worker so pdfjs can use it without external file access
const _pdfjsWorker = require('pdfjs-dist/legacy/build/pdf.worker.js');
if (typeof window !== 'undefined') {
    window.pdfjsWorker = _pdfjsWorker;
}
if (typeof globalThis !== 'undefined') {
    globalThis.pdfjsWorker = _pdfjsWorker;
}
const pdfjs = require('pdfjs-dist/legacy/build/pdf.js');
// In WKWebView the fake worker will use window.pdfjsWorker.WorkerMessageHandler
// We don't set workerSrc since the worker is already loaded

// Models from jzillmann/pdf-to-markdown
const TextItem = require('pdf-to-markdown/src/javascript/models/TextItem.jsx').default;
const Page = require('pdf-to-markdown/src/javascript/models/Page.jsx').default;
const ParseResult = require('pdf-to-markdown/src/javascript/models/ParseResult.jsx').default;

// Transformations
const CalculateGlobalStats = require('pdf-to-markdown/src/javascript/models/transformations/textitem/CalculateGlobalStats.jsx').default;
const CompactLines = require('pdf-to-markdown/src/javascript/models/transformations/lineitem/CompactLines.jsx').default;
const RemoveRepetitiveElements = require('pdf-to-markdown/src/javascript/models/transformations/lineitem/RemoveRepetitiveElements.jsx').default;
const VerticalToHorizontal = require('pdf-to-markdown/src/javascript/models/transformations/lineitem/VerticalToHorizontal.jsx').default;
const DetectTOC = require('pdf-to-markdown/src/javascript/models/transformations/lineitem/DetectTOC.jsx').default;
const DetectHeaders = require('pdf-to-markdown/src/javascript/models/transformations/lineitem/DetectHeaders.jsx').default;
const DetectListItems = require('pdf-to-markdown/src/javascript/models/transformations/lineitem/DetectListItems.jsx').default;
const GatherBlocks = require('pdf-to-markdown/src/javascript/models/transformations/textitemblock/GatherBlocks.jsx').default;
const DetectListLevels = require('pdf-to-markdown/src/javascript/models/transformations/textitemblock/DetectListLevels.jsx').default;
const ToTextBlocks = require('pdf-to-markdown/src/javascript/models/transformations/ToTextBlocks.jsx').default;
const ToMarkdown = require('pdf-to-markdown/src/javascript/models/transformations/ToMarkdown.jsx').default;

// Custom post-processing: fix over-aggressive header detection.
// When mostUsedHeight is skewed by many small items (e.g. figure text, keyboard labels),
// DetectHeaders marks normal body text as headers. This step demotes false headers.
class SanitizeHeaders {
    transform(parseResult) {
        const { mostUsedHeight } = parseResult.globals;

        // Count total items and header items across all pages
        let totalItems = 0;
        let headerItems = 0;
        parseResult.pages.forEach(page => {
            page.items.forEach(item => {
                totalItems++;
                if (item.type && item.type.headline) {
                    headerItems++;
                }
            });
        });

        // If more than 40% of items are headers, the detection is wrong
        const headerRatio = totalItems > 0 ? headerItems / totalItems : 0;
        if (headerRatio <= 0.4) {
            return parseResult; // Looks reasonable, no fix needed
        }

        // Count occurrences per height among header items
        const headerHeightCounts = {};
        parseResult.pages.forEach(page => {
            page.items.forEach(item => {
                if (item.type && item.type.headline) {
                    const h = item.height;
                    headerHeightCounts[h] = (headerHeightCounts[h] || 0) + 1;
                }
            });
        });

        // Sort heights by frequency (most common first)
        const heights = Object.entries(headerHeightCounts)
            .map(([h, count]) => ({ height: parseInt(h), count }))
            .sort((a, b) => b.count - a.count);

        if (heights.length === 0) return parseResult;

        // Keep only the top 1-2 rarest heights as real headers (H1, maybe H2).
        // Everything else is false-positive body text.
        // A "real header" height should appear much less frequently than body text.
        const totalHeaderItems = heights.reduce((sum, h) => sum + h.count, 0);
        const demoteHeights = new Set();
        for (const { height, count } of heights) {
            // If this height accounts for more than 10% of all header items,
            // it's likely body text, not a real header
            if (count / totalHeaderItems > 0.1) {
                demoteHeights.add(height);
            }
        }

        // But always keep the tallest height as a real header (likely H1/title)
        const maxHeight = Math.max(...heights.map(h => h.height));
        demoteHeights.delete(maxHeight);

        let demotedCount = 0;
        parseResult.pages.forEach(page => {
            page.items.forEach(item => {
                if (item.type && item.type.headline && demoteHeights.has(item.height)) {
                    item.type = null;
                    item.annotation = null;
                    demotedCount++;
                }
            });
        });

        return new ParseResult({
            ...parseResult,
            messages: [
                `SanitizeHeaders: ${Math.round(headerRatio * 100)}% items were headers (${headerItems}/${totalItems}), demoted ${demotedCount} at heights [${[...demoteHeights]}], kept maxHeight=${maxHeight}`,
            ]
        });
    }

    completeTransform(parseResult) { return parseResult; }
}

async function convertPdfToMarkdown(base64Data) {
    const data = Uint8Array.from(atob(base64Data), c => c.charCodeAt(0));

    const pdfDocument = await pdfjs.getDocument({
        data: data,
        useSystemFonts: true,
        disableFontFace: true,
        isEvalSupported: false,
    }).promise;

    const pages = [];
    const fontIds = new Set();
    const fontMap = new Map();

    for (let j = 1; j <= pdfDocument.numPages; j++) {
        const page = await pdfDocument.getPage(j);
        const viewport = page.getViewport({ scale: 1.0 });
        const textContent = await page.getTextContent();

        const textItems = textContent.items.map(item => {
            const tx = pdfjs.Util.transform(viewport.transform, item.transform);
            const fontHeight = Math.sqrt((tx[2] * tx[2]) + (tx[3] * tx[3]));
            const dividedHeight = item.height / fontHeight;
            return new TextItem({
                x: Math.round(item.transform[4]),
                y: Math.round(item.transform[5]),
                width: Math.round(item.width),
                height: Math.round(dividedHeight <= 1 ? item.height : dividedHeight),
                text: item.str,
                font: item.fontName,
            });
        });

        // Resolve fonts
        for (const item of textContent.items) {
            const fontId = item.fontName;
            if (!fontIds.has(fontId) && fontId.startsWith('g_d0')) {
                try {
                    const font = await new Promise((resolve, reject) => {
                        const timeout = setTimeout(() => reject(new Error('font timeout')), 1000);
                        page.commonObjs.get(fontId, (f) => {
                            clearTimeout(timeout);
                            resolve(f);
                        });
                    });
                    fontMap.set(fontId, font);
                } catch (e) {
                    // Font resolution failed, continue without it
                }
                fontIds.add(fontId);
            }
        }

        pages.push(new Page({ index: j - 1, items: textItems }));
    }

    // Run transformation pipeline
    const transformations = [
        new CalculateGlobalStats(fontMap),
        new CompactLines(),
        new RemoveRepetitiveElements(),
        new VerticalToHorizontal(),
        new DetectTOC(),
        new DetectHeaders(),
        new SanitizeHeaders(),
        new DetectListItems(),
        new GatherBlocks(),
        new DetectListLevels(),
        new ToTextBlocks(),
        new ToMarkdown(),
    ];

    let parseResult = new ParseResult({ pages: pages, globals: {}, messages: [] });
    for (const transformation of transformations) {
        parseResult = transformation.transform(parseResult);
        parseResult = transformation.completeTransform(parseResult);
    }

    // Collect markdown from all pages
    let markdown = '';
    for (const page of parseResult.pages) {
        for (const item of page.items) {
            if (typeof item === 'string') {
                markdown += item;
            } else if (item && item.text) {
                markdown += item.text + '\n';
            }
        }
    }

    return markdown.trim();
}

// Expose globally for WKWebView callAsyncJavaScript
window.convertPdfToMarkdown = convertPdfToMarkdown;
