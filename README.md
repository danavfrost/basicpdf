# Basic PDF

A small, fast, free PDF viewer and form filler for Android and iOS.
No ads, no accounts, no network access, no tracking.

- View any PDF, including password-protected ones.
- Fill in form fields (text, checkboxes, radio buttons, dropdowns).
- Add, move, resize and delete text boxes and checkboxes.
- Make a quick text PDF with **New**.
- Saves as incremental updates, so the original file content, passwords
  and signatures are kept.

## "No access — open it again from Files"?

Basic PDF never asks for access to all your files. Android instead gives it
permission one file at a time, and how long that lasts depends on how the
file was opened:

- **Opened with the app's own Open button:** permission lasts, so the file
  keeps working from Recent.
- **Tapped in a file manager ("Open with" → Basic PDF):** most file managers
  hand over one-time access that Android cancels when the app closes. The
  file is still there, but its Recent entry shows "No access".

To keep a file in Recent, open it once with Basic PDF's **Open** button.
Long-press a "No access" entry to remove it.

See [SPEC.md](SPEC.md) for the full spec and [PRIVACY.md](PRIVACY.md) for
the privacy policy.

## Build

```sh
flutter test                                   # unit + widget tests
flutter build apk --release --target-platform android-arm64
flutter build ios --release                    # needs signing
```

Device tests live in `integration_test/`; run them with the helpers in
`tool/qa/` (screenshots and logs go to `build/qa/`).

The character-sheet tests need a blank D&D 5e character sheet at
`test/fixtures/character_sheet.pdf` (it's Wizards of the Coast's
copyrighted document, so it isn't included). Without it they're skipped.

## Layout

- `lib/core/` — pure-Dart PDF engine: parser, encryption, AcroForm
  model, appearance streams, incremental writer, new-document generator.
- `lib/ui/`, `lib/services/` — Flutter app (pages render with PDFium via
  `pdfrx`).
- `android/`, `ios/` — platform file access (Storage Access Framework,
  document picker + security-scoped bookmarks).

## License

MIT — see [LICENSE](LICENSE).

Bundled fonts: Liberation Sans/Mono (SIL Open Font License), see
`assets/fonts/LICENSE-Liberation.txt`.
