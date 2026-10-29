# Referee for Google Docs

Referee's add-on for Google Docs: it marks each sentence by how your reading backs it (green
backed, amber needs a source or check the wording, red contradicted), suggests citations in your
style with an Insert button, adds them automatically if you choose, and removes its marks when
you ask. It's the same checking as in Word, using Referee on your Mac.

It can only see the document it's open in (`documents.currentonly`), and it sends sentences only
to Referee on your Mac, which must be open.

## Setting it up (once)

1. In any Google Doc, choose **Extensions → Apps Script**.
2. Replace the contents of `Code.gs` with this folder's `Code.gs`.
3. Add an HTML file named **Sidebar** (the + next to Files, then HTML) and paste in `Sidebar.html`.
4. Open **Project Settings** (the cog), tick **Show "appsscript.json" manifest file in editor**, and replace that file's contents with this folder's `appsscript.json`.
5. Save, close the Apps Script tab, and reload the document. A **Referee** menu appears.
6. Choose **Referee → Open Referee**. Google asks for permission: choose your account, then
   **Advanced → Go to Referee (unsafe)** (it says this because the add-on isn't published in
   Google's store), then **Allow**.
7. Paste the pairing code from Referee on your Mac (**Settings → Writing → Google Docs → Copy Pairing Code**).

The add-on then appears in the Referee menu of every Google Doc you open.

## Pairing

The panel runs on Google's script pages, which any Apps Script can use, so Referee only answers
them with your pairing code. **New Code** in Settings makes a fresh one; paste it into the panel
again.
