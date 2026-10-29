import AppKit
import PDFKit

/// "Save a copy with your highlights": a saved PDF, with the passages you highlighted while
/// reading written into it as real highlight annotations, so they show in Preview or any other
/// PDF app. The original isn't changed.
@MainActor
enum PDFHighlights {

    /// Returns how many highlights were found in the PDF and written, or nil if cancelled.
    static func saveCopy(of url: URL, highlights: [String]) -> Int? {
        guard let document = PDFDocument(url: url) else { return 0 }
        var written = 0
        for text in highlights {
            for selection in find(text, in: document) {
                for line in selection.selectionsByLine() {
                    guard let page = line.pages.first else { continue }
                    let mark = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                    mark.color = NSColor.systemYellow.withAlphaComponent(0.45)
                    mark.contents = "Highlighted while reading, kept by Referee"
                    page.addAnnotation(mark)
                }
                written += 1
            }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " (highlighted).pdf"
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let target = panel.url else { return nil }
        document.write(to: target)
        return written
    }

    /// Where a highlight is in the PDF: the whole passage if it's found as written, otherwise its
    /// opening words (a highlight often runs across lines, which PDFs break differently).
    private static func find(_ text: String, in document: PDFDocument) -> [PDFSelection] {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let whole = document.findString(flat, withOptions: [.caseInsensitive])
        if !whole.isEmpty { return Array(whole.prefix(1)) }
        let words = flat.split(separator: " ")
        guard words.count >= 6 else { return [] }
        return Array(document.findString(words.prefix(8).joined(separator: " "), withOptions: [.caseInsensitive]).prefix(1))
    }
}
