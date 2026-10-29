import AppKit
import PDFKit

// referee-pagecrop <pdf> <page> <passage file> <out.png>
// Finds the passage on that page of the PDF (by its first and last words, ignoring spacing, since
// the PDF's own text and the saved passage are spaced differently) and saves that part of the page
// as a picture: matrices and column vectors as printed, which text can't keep.

let args = CommandLine.arguments
guard args.count == 5, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])), let number = Int(args[2]),
      number >= 1, number <= doc.pageCount, let page = doc.page(at: number - 1),
      let passage = try? String(contentsOfFile: args[3], encoding: .utf8), let text = page.string else { exit(1) }

/// The page's letters and digits only, lowercased, and where each sits in the page's own text:
/// spacing, punctuation and dots differ between the PDF's text and the saved passage.
func keep(_ c: Character) -> Bool { c.isLetter || c.isNumber }
var squeezed: [Character] = []
var position: [Int] = []
let utf16 = Array(text.utf16)
var offset = 0
for c in text {
    if keep(c) {
        squeezed.append(Character(c.lowercased()))
        position.append(offset)
    }
    offset += String(c).utf16.count
}
let wanted: [Character] = passage.filter(keep).map { Character($0.lowercased()) }
guard wanted.count >= 8, squeezed.count >= 8 else { exit(2) }

// The start: of every place the passage's opening appears, the one that goes on to match it for longest.
// A passage can begin partway through an expression ("…,am ∈ Rn"), so if its first letters aren't on
// the page as they are, it's tried from a little further in, then further.
var first = -1, best = 0, skipped = 0
for skip in [0, 3, 6, 12, 24, 48] where first < 0 && skip + 8 <= wanted.count {
    let rest = Array(wanted[skip...])
    let opening = Array(rest.prefix(8))
    var i = 0
    while i + opening.count <= squeezed.count {
        if Array(squeezed[i..<(i + opening.count)]) == opening {
            var n = 0
            while i + n < squeezed.count && n < rest.count && squeezed[i + n] == rest[n] { n += 1 }
            if n > best { best = n; first = i; skipped = skip }
        }
        i += 1
    }
}
guard first >= 0 else { exit(2) }
// The end: the passage's last letters, looked for near where its length says it should end.
// Likewise from a little before the end if its last letters aren't there as they are.
let length = wanted.count - skipped
var last = min(squeezed.count - 1, first + length - 1)
search: for back in [0, 3, 6, 12, 24, 48] where back + 10 <= length {
    let closing = Array(wanted[(wanted.count - back - 10)..<(wanted.count - back)])
    // Of every place they appear, the one nearest where the passage should end: the first one found
    // could be earlier in the passage ("…independent" in part (a) of a theorem whose part (b) ends that way).
    var j = first + max(0, length / 2)
    let limit = min(squeezed.count - closing.count, first + length * 2)
    let expected = first + length - 1
    var nearest: Int?
    while j <= limit {
        if Array(squeezed[j..<(j + closing.count)]) == closing {
            let end = j + closing.count - 1
            if nearest.map({ abs(end - expected) < abs($0 - expected) }) ?? true { nearest = end }
        }
        j += 1
    }
    if let nearest { last = nearest; break search }
}
_ = utf16

// Top from the passage's first letters, bottom from its last: the selection of the whole range can
// reach up the page, since a PDF's text order isn't always its reading order (display maths).
func bounds(_ from: Int, _ to: Int) -> CGRect? {
    let range = NSRange(location: position[from], length: position[to] - position[from] + 1)
    return page.selection(for: range)?.bounds(for: page)
}
guard let top = bounds(first, min(first + 6, last)), let bottom = bounds(max(first, last - 6), last) else { exit(3) }
let found = CGRect(x: 0, y: min(bottom.minY, top.minY), width: 0, height: max(top.maxY, bottom.maxY) - min(bottom.minY, top.minY))

// Room for what's drawn taller than its line (column vectors, matrices, big brackets): up to the
// line of text before the passage and down to the line after it, but no further than 60 points.
var upper = found.maxY + 60, lower = found.minY - 30   // less below: page numbers and footers sit there
// The nearest letters above and below the passage's own lines (skipping the rest of its first line,
// like a "Definition 4.21." label, and of its last).
var k = first - 1
while k >= max(0, first - 600) {
    if let r = bounds(k, k), r.minY > found.maxY - 2 { upper = min(upper, r.minY - 4); break }
    k -= 1
}
k = last + 1
while k < min(position.count, last + 600) {
    if let r = bounds(k, k), r.maxY < found.minY + 2 { lower = max(lower, r.maxY + 3); break }
    k += 1
}
let room = CGRect(x: 0, y: lower, width: 0, height: upper - lower)
let box = page.bounds(for: .cropBox)
// The whole width of the text column, from just above the passage to just below it.
let margin: CGFloat = 6
// Side to side: the page's text column, not its margins, so the words fill the picture.
let column = page.selection(for: NSRange(location: 0, length: utf16.count))?.bounds(for: page) ?? box.insetBy(dx: 40, dy: 0)
let crop = CGRect(x: max(box.minX, column.minX - 4), y: max(box.minY, room.minY),
                  width: min(box.width, column.width + 8), height: min(box.maxY, room.maxY) - max(box.minY, room.minY))

let scale: CGFloat = 3
let width = Int(crop.width * scale), height = Int(crop.height * scale)
guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(4) }
context.setFillColor(NSColor.white.cgColor)
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.scaleBy(x: scale, y: scale)
context.translateBy(x: -crop.minX, y: -crop.minY)
page.draw(with: .cropBox, to: context)
guard let image = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(5) }
try? png.write(to: URL(fileURLWithPath: args[4]))
