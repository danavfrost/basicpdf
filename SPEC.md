# Basic PDF — Spec

A slim, free PDF viewer/editor for Android and iOS. No ads, no accounts, no
network access, no nag dialogs. Three jobs: **view** a PDF, **edit** its fields,
**save** it. Plus a fast "New" for typing a quick text PDF.

Stack: Flutter (one Dart codebase). PDFium (via `pdfrx`) renders pages and
handles opening. A pure-Dart PDF core (`lib/core/`) reads and writes form
fields, handles encryption, and creates new documents.

---

## 1. Screens

### 1.1 Viewer (main screen)
- Pages render in a vertical, continuously scrolling list; pinch to zoom.
- **Top bar**: document title, an **Edit** button (pencil), and an overflow
  menu (⋮).
- **Auto-hide**: while the user is actively scrolling, the top bar slides
  out of the way. When scrolling stops (~350 ms idle), or the user scrolls
  up, or taps the page, it slides back in with the Edit button. (Same feel
  as Google Drive's "+" button, but in the top bar.)
- **Overflow menu**: New, Open, Save, Save As, Dark mode, About.
  Nothing else.
- **Dark mode** is a toggle in the menu. First launch follows the
  system; once toggled, the choice is remembered. It changes only the
  app around the pages; PDF pages always show as printed (white paper).
  There is no Exit: phones close apps themselves (iOS forbids apps
  quitting; on Android the back gesture leaves the app).
- Unsaved changes show a dot next to the title.
- With no document open, the viewer shows the **Home** state: the Recent
  list with New and Open buttons. The app starts here unless it was
  launched by opening a PDF from another app.

### 1.2 Edit mode
Tapping **Edit** switches the top bar to edit mode: a **✓ (Done)** button,
a **Fields** button (layout tool), and the title. What you can edit depends
on the PDF:

| PDF type | Edit lets you |
|---|---|
| Has form fields (D&D sheet, government form, or a PDF made by our New) | Fill in the fields only. The rest of the page can't be changed. |
| No form fields (plain text/scanned PDF) | Nothing to fill; the app shows an inline hint: "No fillable fields — tap Fields to add text boxes." |

- Fill controls appear on top of each field's position on the page:
  text (single and multi-line), checkbox, radio group, dropdown/list.
  Signature fields are shown but not editable in v1.
- Read-only fields stay read-only.
- **✓ Done** applies the edits: the core writes them into the PDF bytes in
  memory and the viewer reloads, so what you see is exactly what will be
  saved. Nothing is written to disk until Save.

### 1.3 Fields tool (adding/arranging edit boxes)
Inside edit mode, **Fields** switches to layout:
- **+ Text box**: drag a rectangle on a page to create a text field.
  A toggle on the selected field switches single-line / multi-line.
- **+ Checkbox**: tap to place a checkbox.
- Tap any existing field (ours or the original PDF's) to select it: drag
  to move, corner handles to resize, trash icon to delete.
- Field names are generated automatically (`Text1`, `Text2`, `Check1`…).
- Back to fill mode via the Fields button; ✓ applies everything.

### 1.4 New
New opens a blank white page sheet. Tap **Edit**, type, tap **✓**. That's
it — the app turns the text into a PDF:
- Letter size (612×792 pt), 1-inch (72 pt) margins, Helvetica 12 pt.
- Each page is **one big multi-line text field** covering the area inside
  the margins, holding that page's text. Text that overflows one page
  flows to the next page's field (`Body1`, `Body2`, …).
- The first Save asks for a filename (Save As).
- Once saved it is a normal PDF. Re-opening it and tapping Edit lets you
  change the text **inside** those page fields. You can't add pages or new
  content beyond what fits — it's a PDF now.
- Before the first ✓ (still a draft), Edit returns to the free-typing
  sheet so the draft can still grow.

### 1.5 Open dialog
A full-screen sheet with three tabs:
1. **Recent** — the last 15 files opened, newest first, with name, folder
   and date.
2. **History** — every file ever opened in the app, with a search box,
   sorted by last opened. Long-press → "Remove from history". Entries whose
   file is gone are shown greyed out ("Missing").
3. **Browse** — browse the phone's files:
   - **Android**: opens the system document picker
     (`ACTION_OPEN_DOCUMENT`, PDFs only) starting in **Downloads**. It
     already covers Documents, internal storage, SD cards and Drive. The
     app keeps a persistable read/write grant for every file it opens, so
     Recent/History can reopen it and Save writes back in place. No storage
     permissions are requested (store-safe: Google Play does not allow
     "All files access" for PDF apps).
   - **iOS**: the in-app browser starts in the app's own Documents folder
     ("On My iPhone ▸ PDFEdit", visible in the Files app). A
     "Browse Files…" button opens the iOS Files picker (iCloud Drive, On
     My iPhone, other providers). Picked files are opened **in place**
     and remembered with security-scoped bookmarks, so Recent/History can
     reopen them and Save writes back to them.

### 1.6 Save / Save As / About
- **Save** writes back to the file it came from. If that isn't possible
  (draft never saved, read-only location, opened from another app without
  write access) it behaves as Save As.
- **Save As**: Android uses the system "create document" screen
  (filename + folder, starting in Documents). iOS asks for a filename and
  saves to the app Documents folder, with "Choose folder…" for the
  system folder picker.
- Saves of opened PDFs are **incremental updates**: the original bytes
  are kept unchanged and our changes are appended. This keeps existing
  digital signatures intact and is fast.
- **Leaving a document**: on Android, back from a document returns to
  Home (with the unsaved-changes dialog if needed); back from Home leaves
  the app normally. The app never quits itself.
- The same unsaved-changes dialog appears before New/Open (or Android back) would
  discard edits.
- **About**: app name, version, "Free. No ads. No tracking. No network.",
  and open-source licenses (Flutter `showLicensePage`).

### 1.7 Locked / password PDFs
- **User password** (can't open without it): a password dialog appears;
  wrong password shakes and asks again; Cancel returns to where you were.
- **Owner password / permission restrictions** (opens fine, but editing
  is restricted): the document views normally. The Edit button shows a
  small lock; tapping it explains in one line and offers to enter the
  owner password to unlock editing.
- Saving keeps the original encryption and password (the incremental
  update encrypts new objects with the document's key).
- Supported: Standard security handler RC4 40/128-bit, AES-128, AES-256
  (R2–R6). Other security handlers (certificate/DRM) open view-only if
  PDFium can, otherwise show an inline "can't open this kind of protected
  PDF" message.

### 1.8 Opening from other apps
- Android: registered for `application/pdf` VIEW intents ("Open with").
- iOS: registered as a PDF viewer (`CFBundleDocumentTypes`,
  `LSSupportsOpeningDocumentsInPlace`, `UIFileSharingEnabled`).

---

## 2. Non-goals (v1)
Annotations/markup, drawing, signing, page add/delete/reorder, OCR,
editing the printed text of a PDF, rich text, images, cloud accounts,
settings screens, themes beyond the light/dark toggle.

## 3. Non-functional
- Cold start to Home < 1 s on a mid-range phone; first page of a 50-page
  PDF visible < 1 s. Pages render lazily.
- No `INTERNET` permission and no storage permissions on Android. No analytics, no crash reporting.
- Text fields use Helvetica with WinAnsi encoding in v1. Characters outside
  Latin-1 are replaced with `?` in the saved appearance and the field shows
  an inline note.
- Android APK is built to `BasicPDF.apk` in the project root.

---

## 3a. App store readiness
The app is intended for free distribution on Google Play and the App
Store, so every feature must pass store review:
- Android: Storage Access Framework only (no `MANAGE_EXTERNAL_STORAGE`),
  current target SDK, release signing with a keystore the owner keeps.
- iOS: no programmatic exit; files via the app Documents folder and the
  system document picker; `ITSAppUsesNonExemptEncryption = false` (PDF
  decryption with standard algorithms only — owner to confirm).
- A one-page privacy policy ("collects nothing") is needed for both
  store listings; Play's Data safety form = no data collected.
- All dependencies are permissively licensed (BSD/MIT/Apache); About lists
  them.
- Before publishing, owner decides: company part of the app/bundle id
  (currently `com.halworks.basicpdf`; company part TBD), icon, developer accounts.

## 4. Architecture

```
lib/
  main.dart                 app entry, theme, routes
  core/                     pure Dart, no Flutter imports — unit-testable
    pdf_core.dart           PUBLIC CONTRACT (see §5) — the only import UI uses
    ...                     parser, xref/object streams, filters, security
                            handler, AcroForm model, appearance streams,
                            incremental writer, new-document generator
  ui/
    viewer/                 page list (pdfrx), auto-hiding top bar, menu
    edit/                   field overlays, fields layout tool
    new_doc/                draft typing sheet
    open/                   Open dialog: Recent, History, Browse
    dialogs/                password, unsaved changes, save-as, about
  services/
    file_service.dart       platform file access (read/write/bookmarks)
    history_store.dart      recent + history JSON in app support dir
ios/Runner/                 Swift: document picker, security-scoped bookmarks
android/                    manifest: permissions, VIEW intent filter
test/                       core unit tests + fixtures
```

Document state in the app is just **bytes + password + source location +
dirty flag**. Every ✓ produces new bytes via the core; the viewer reopens
from memory with `pdfrx`. Save writes those bytes.

## 5. Core contract
`lib/core/pdf_core.dart` defines the API between core and UI. Both sides
code against it; changes to it must be agreed (keep it backwards
compatible, add rather than rename).
