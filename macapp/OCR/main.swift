import AppKit
import PDFKit
import Vision

// Referee's reader for scanned pages and screenshots, with Apple's Vision, on this Mac.
//   referee-ocr <file.pdf>     each page's text, as a JSON list: a page that has its own text keeps
//                              it; a page without (a scan) is read from its image.
//   referee-ocr <image>        the image's text, as a one-item JSON list.
// Also prints which pages were read from images, so Referee can mark that text as unverified.
// Nothing leaves the Mac.

func recognise(_ image: CGImage) -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-GB", "en-US"]
    try? VNImageRequestHandler(cgImage: image).perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    return lines.joined(separator: "\n")
}

func render(_ page: PDFPage) -> CGImage? {
    let box = page.bounds(for: .mediaBox)
    let scale: CGFloat = 2.5            // about 180 dpi: enough for small print
    let width = Int(box.width * scale), height = Int(box.height * scale)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: context)
    return context.makeImage()
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else { FileHandle.standardError.write("referee-ocr <file>\n".data(using: .utf8)!); exit(1) }
let url = URL(fileURLWithPath: arguments[1])
var pages: [String] = []
var scanned: [Int] = []

if url.pathExtension.lowercased() == "pdf" {
    guard let document = PDFDocument(url: url) else { exit(1) }
    for i in 0..<document.pageCount {
        guard let page = document.page(at: i) else { pages.append(""); continue }
        let own = page.string ?? ""
        // A page with real text keeps it; a scan (none, or only a page number) is read.
        if own.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 {
            pages.append(own)
        } else if let image = render(page) {
            pages.append(recognise(image))
            scanned.append(i + 1)
        } else {
            pages.append(own)
        }
    }
} else {
    guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
    pages = [recognise(image)]
    scanned = [1]
}

let out: [String: Any] = ["pages": pages, "scanned": scanned]
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: out))
