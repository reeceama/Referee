/**
 * @OnlyCurrentDoc
 *
 * Referee for Google Docs: checks your writing against your reading, as Referee does in Word.
 * The panel (Sidebar.html) reads this document, asks Referee on your Mac to check each sentence,
 * and these functions mark sentences and insert citations in the document itself.
 *
 * @OnlyCurrentDoc limits it to the document it's open in: it can't see your other files.
 * Nothing here talks to the internet; the panel talks only to Referee on your Mac.
 */

var COLOURS = { supports: '#d4f0dc', contradicts: '#fadbd8', warn: '#fdebc8' };
var MARKS = 'refereeMarks';   // the sentences marked, kept with the document, for Remove Marks

function onOpen() {
  DocumentApp.getUi().createMenu('Referee')
    .addItem('Open Referee', 'showPanel')
    .addItem('Remove marks', 'removeMarks')
    .addToUi();
}

function onInstall() { onOpen(); }

function showPanel() {
  var panel = HtmlService.createHtmlOutputFromFile('Sidebar').setTitle('Referee');
  DocumentApp.getUi().showSidebar(panel);
}

/** The document's title and text, for the panel to split into sentences. */
function readDocument() {
  var doc = DocumentApp.getActiveDocument();
  return { title: doc.getName(), id: doc.getId(), text: doc.getBody().getText() };
}

/** The pairing code, kept for this person only. */
function getPairing() { return PropertiesService.getUserProperties().getProperty('pairing') || ''; }
function setPairing(code) { PropertiesService.getUserProperties().setProperty('pairing', (code || '').trim()); }

/** Escapes text for findText, which takes a regular expression. */
function pattern(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\s+/g, '\\s+');
}

/** Finds a sentence in the document: {element, start, end}, or null. */
function locate(sentence) {
  var body = DocumentApp.getActiveDocument().getBody();
  // Long sentences are found by their first part, which is enough to be unique.
  var words = sentence.split(/\s+/);
  var head = words.slice(0, Math.min(words.length, 12)).join(' ');
  var found = body.findText(pattern(head));
  if (!found) return null;
  var element = found.getElement().asText();
  var start = found.getStartOffset();
  var end = Math.min(element.getText().length - 1, start + sentence.length - 1);
  return { element: element, start: start, end: end };
}

/** Marks each sentence in its colour: [{sentence, kind}] with kind supports, contradicts or warn. */
function markSentences(marks) {
  var props = PropertiesService.getDocumentProperties();
  var kept = JSON.parse(props.getProperty(MARKS) || '[]');
  marks.forEach(function (m) {
    var at = locate(m.sentence);
    if (!at || !COLOURS[m.kind]) return;
    at.element.setBackgroundColor(at.start, at.end, COLOURS[m.kind]);
    if (kept.indexOf(m.sentence) < 0) kept.push(m.sentence);
  });
  props.setProperty(MARKS, JSON.stringify(kept.slice(-500)));
  return kept.length;
}

/** Takes every Referee mark out of the document, leaving your own formatting alone. */
function removeMarks() {
  var props = PropertiesService.getDocumentProperties();
  var kept = JSON.parse(props.getProperty(MARKS) || '[]');
  kept.forEach(function (sentence) {
    var at = locate(sentence);
    if (at) at.element.setBackgroundColor(at.start, at.end, null);
  });
  props.deleteProperty(MARKS);
  return kept.length;
}

/** Inserts a citation at the end of a sentence, before its full stop. Returns how it went. */
function insertCitation(sentence, citation) {
  var at = locate(sentence);
  if (!at) return 'not found';
  var text = at.element.getText();
  var end = at.end;
  if (text.substr(end + 1, citation.length + 1).indexOf(citation) >= 0) return 'already cited';
  var stop = /[.!?]/.test(text.charAt(end)) ? end : end + 1;
  at.element.insertText(stop, ' ' + citation);
  return 'ok';
}
