import XCTest

/// iOS QA for system UI that Flutter integration tests can't reach:
/// the Files document picker, the folder picker (Save As ▸ Choose folder…)
/// and "Open in Basic PDF" from the Files app.
///
/// Expects On My iPhone ▸ QA ▸ external_form.pdf to exist (the QA runner
/// copies it into the simulator's File Provider Storage).
final class RunnerUITests: XCTestCase {
  let app = XCUIApplication(bundleIdentifier: "com.halworks.basicpdf")

  override func setUp() {
    continueAfterFailure = false
  }

  private func shot(_ name: String) {
    let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    a.name = name
    a.lifetime = .keepAlways
    add(a)
  }

  private func dump(_ el: XCUIElement, _ label: String) {
    print("[UIQA] \(label):\n\(el.debugDescription)")
  }

  /// Taps the match nearest the top of the screen (our app bar, not the keyboard).
  private func tapTopmost(_ q: XCUIElementQuery) {
    let el = q.allElementsBoundByIndex.min(by: { $0.frame.minY < $1.frame.minY })!
    el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
  }

  /// Taps the first element whose label contains [text].
  @discardableResult
  private func tapLabel(_ root: XCUIElement, _ text: String, timeout: TimeInterval = 10) -> Bool {
    let q = root.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
    let el = q.firstMatch
    guard el.waitForExistence(timeout: timeout) else { return false }
    el.tap()
    return true
  }

  /// Navigates a document/folder picker (remote view) to On My iPhone ▸ QA.
  private func pickerToQA(_ root: XCUIApplication) -> XCUIElement {
    let picker = root.descendants(matching: .any)["Browse View (Picker)"]
    XCTAssertTrue(picker.waitForExistence(timeout: 10), "picker not shown")
    sleep(2)
    let title = picker.navigationBars.staticTexts["On My iPhone"]
    if !title.exists {
      // Go up to Browse root, then into On My iPhone.
      for _ in 0..<4 where !picker.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "On My iPhone")).firstMatch.exists {
        let back = picker.navigationBars.buttons["BackButton"]
        if back.exists { back.tap(); sleep(1) } else { break }
      }
      picker.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "On My iPhone")).firstMatch.tap()
      sleep(2)
    }
    let qa = picker.cells["QA, Folder"]
    XCTAssertTrue(qa.waitForExistence(timeout: 5), "QA folder")
    qa.tap()
    sleep(2)
    return picker
  }

  private func pickInDocumentPicker(_ file: String) {
    let picker = pickerToQA(app)
    shot("picker-qa")
    dump(picker, "picker in QA")
    let name = (file as NSString).deletingPathExtension
    let cell = picker.cells.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    XCTAssertTrue(cell.waitForExistence(timeout: 5), "\(file) not found")
    cell.tap()
    sleep(1)
    if picker.buttons["Open"].exists { picker.buttons["Open"].tap() }
  }

  /// Home ▸ Open ▸ Browse ▸ Browse Files… ▸ On My iPhone ▸ QA ▸ external_form.pdf
  func testA_PickExternalFile() {
    app.launch()
    sleep(4)
    shot("home")
    XCTAssertTrue(tapLabel(app, "Open"), "Open button")
    sleep(1)
    XCTAssertTrue(tapLabel(app, "Browse"), "Browse tab")
    sleep(1)
    XCTAssertTrue(tapLabel(app, "Browse Files"), "Browse Files… button")
    pickInDocumentPicker("external_form.pdf")
    sleep(4)
    shot("opened-external")
    editNameAndSave("Picked edit", current: "Alice")
  }

  /// Edit ▸ first text field ▸ type ▸ ✓ ▸ More ▸ Save.
  private func editNameAndSave(_ text: String, current: String) {
    XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 10), "Edit button")
    app.buttons["Edit"].tap()
    sleep(2)
    XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), "text field")
    // The topmost text field on page 1 is "name".
    let all = app.textFields.allElementsBoundByIndex
    let tf = all.min(by: { $0.frame.minY < $1.frame.minY })!
    print("[UIQA] name field frame \(tf.frame) value \(String(describing: tf.value)) expected \(current)")
    tf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    sleep(1)
    // Delete existing value then type (into whatever has focus).
    app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30))
    app.typeText(text)
    sleep(1)
    shot("typed")
    tapTopmost(app.buttons.matching(NSPredicate(format: "label == %@", "Done")))
    sleep(3)
    shot("after-done")
    XCTAssertTrue(tapLabel(app, "More"), "overflow")
    sleep(1)
    shot("menu")
    let save = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Save")).firstMatch
    XCTAssertTrue(save.waitForExistence(timeout: 3))
    save.tap()
    sleep(3)
    shot("after-save")
    dump(app, "after save")
  }

  /// Relaunch ▸ Recent ▸ external_form.pdf (security-scoped bookmark) ▸ edit ▸ Save.
  func testA2_RelaunchRecentBookmark() {
    app.terminate()
    app.launch()
    sleep(4)
    shot("relaunch-home")
    let recent = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "external_form.pdf")).firstMatch
    XCTAssertTrue(recent.waitForExistence(timeout: 5), "Recent entry")
    print("[UIQA] recent entry label: \(recent.label)")
    recent.tap()
    sleep(4)
    shot("recent-opened")
    editNameAndSave("Bookmark edit", current: "Picked edit")
  }

  /// Save As ▸ Choose folder… ▸ On My iPhone ▸ QA ▸ Open → Save.
  /// The app must have a document open (run after testA).
  func testB_SaveAsChooseFolder() {
    app.launch()
    sleep(4)
    let recent = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "external_form.pdf")).firstMatch
    XCTAssertTrue(recent.waitForExistence(timeout: 5), "Recent entry")
    recent.tap()
    sleep(4)
    shot("before-saveas")
    XCTAssertTrue(tapLabel(app, "More"), "overflow menu")
    sleep(1)
    let saveAs = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Save As")).firstMatch
    XCTAssertTrue(saveAs.waitForExistence(timeout: 3), "Save As")
    saveAs.tap()
    sleep(1)
    XCTAssertTrue(tapLabel(app, "Choose folder"), "Choose folder")
    sleep(3)
    shot("folder-picker")
    let picker = pickerToQA(app)
    shot("folder-picker-qa")
    dump(picker, "folder picker in QA")
    if picker.buttons["Open"].exists { picker.buttons["Open"].tap() } else if picker.buttons["Done"].exists { picker.buttons["Done"].tap() }
    sleep(2)
    shot("saveas-folder-chosen")
    dump(app, "save as dialog")
    // Name field: replace with a unique name.
    let tf = app.textFields.firstMatch
    if tf.waitForExistence(timeout: 3) {
      tf.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
      sleep(1)
      app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
      app.typeText("saved_to_qa")
    }
    sleep(1)
    shot("saveas-named")
    let save = app.buttons.matching(NSPredicate(format: "label == %@", "Save"))
    tapTopmost(save)
    sleep(3)
    shot("saveas-done")
    dump(app, "after save as")
  }

  /// Relaunch ▸ Recent ▸ saved_to_qa.pdf (bookmark made by writeInFolder) ▸ edit ▸ Save.
  func testB2_ResaveFolderSavedFile() {
    app.terminate()
    app.launch()
    sleep(4)
    let recent = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "saved_to_qa.pdf")).firstMatch
    XCTAssertTrue(recent.waitForExistence(timeout: 5), "Recent entry")
    recent.tap()
    sleep(4)
    shot("saved-to-qa-opened")
    editNameAndSave("Folder resave", current: "Bookmark edit")
  }

  /// Files app: long-press the PDF ▸ Share ▸ Basic PDF.
  func testC_OpenInFromFiles() {
    let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
    files.launch()
    sleep(3)
    if files.buttons["Browse"].waitForExistence(timeout: 5) { files.buttons["Browse"].tap(); sleep(1) }
    for _ in 0..<3 {
      if files.cells.containing(NSPredicate(format: "label CONTAINS %@", "On My iPhone")).firstMatch.exists { break }
      if files.navigationBars.buttons.firstMatch.exists { files.navigationBars.buttons.firstMatch.tap(); sleep(1) }
    }
    XCTAssertTrue(tapLabel(files, "On My iPhone"))
    sleep(2)
    XCTAssertTrue(tapLabel(files, "QA"))
    sleep(2)
    shot("files-qa")
    let item = files.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "external_form")).firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 5))
    item.press(forDuration: 1.5)
    sleep(2)
    shot("files-context-menu")
    dump(files, "context menu")
    XCTAssertTrue(tapLabel(files, "Share"), "Share")
    sleep(3)
    shot("share-sheet")
    dump(files, "share sheet")
    let opened = tapLabel(files, "Basic PDF", timeout: 5)
    if !opened {
      // Maybe under "More" in the app row.
      tapLabel(files, "More", timeout: 3)
      sleep(2)
      shot("share-more")
      dump(files, "share more")
      XCTAssertTrue(tapLabel(files, "Basic PDF", timeout: 5), "Basic PDF in share sheet")
    }
    sleep(5)
    shot("opened-in-basicpdf")
    dump(app, "basic pdf after open-in")
  }

  /// Files app: long-press ▸ Open With ▸ Basic PDF (open in place).
  func testC2_OpenWithFromFiles() {
    let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
    files.launch()
    sleep(3)
    let item = files.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "external_form")).firstMatch
    if !item.waitForExistence(timeout: 5) {
      XCTAssertTrue(tapLabel(files, "On My iPhone"))
      sleep(2)
      XCTAssertTrue(tapLabel(files, "QA"))
      sleep(2)
    }
    XCTAssertTrue(item.waitForExistence(timeout: 5))
    item.press(forDuration: 1.5)
    sleep(2)
    XCTAssertTrue(tapLabel(files, "Open With"), "Open With")
    sleep(2)
    shot("open-with-menu")
    XCTAssertTrue(tapLabel(files, "Basic PDF"), "Basic PDF in Open With")
    sleep(2)
    shot("open-with-2s")
    sleep(4)
    shot("open-with-6s")
    print("[UIQA] basicpdf state: \(app.state.rawValue) title present: \(app.staticTexts["external_form.pdf"].exists)")
  }

  /// Same as C2 but Basic PDF is already running (scene:openURLContexts:), then edit + Save in place.
  func testC3_OpenWithWhileRunning() {
    app.launch()
    sleep(3)
    testC2_OpenWithFromFiles()
    editNameAndSave("OpenWith edit", current: "Bookmark edit")
  }
}
