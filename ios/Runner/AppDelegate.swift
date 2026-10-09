import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PdfFilesChannel") {
      PdfFilesChannel.shared.attach(messenger: registrar.messenger())
    }
  }
}

/// File access for Basic PDF on iOS: the Files document/folder pickers (open in
/// place, no copies), security-scoped bookmarks so Recent/History can reopen
/// files and Save can write back, and documents opened from other apps.
///
/// File contents never cross the method channel: reads copy the document
/// into a temp file (tmp/xfer) and return its path; writes take the path of a
/// temp file Dart wrote. Whoever consumes a temp file deletes it.
final class PdfFilesChannel: NSObject, UIDocumentPickerDelegate {
  static let shared = PdfFilesChannel()

  private var channel: FlutterMethodChannel?
  private var pendingResult: FlutterResult?
  private var pickingFolder = false
  private var pendingIncoming: URL?
  private var dartReady = false

  private var xferDir: URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("xfer", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
  }

  func attach(messenger: FlutterBinaryMessenger) {
    // Leftovers from a run that died mid-transfer.
    DispatchQueue.global(qos: .utility).async {
      let fm = FileManager.default
      for f in (try? fm.contentsOfDirectory(at: self.xferDir, includingPropertiesForKeys: nil)) ?? [] {
        try? fm.removeItem(at: f)
      }
    }
    let ch = FlutterMethodChannel(name: "com.halworks.basicpdf/files", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    channel = ch
  }

  /// A document handed to us by another app (or the Files app).
  func openIncoming(_ url: URL) {
    if dartReady, let ch = channel {
      DispatchQueue.global(qos: .userInitiated).async {
        let map = try? self.docMap(url)
        DispatchQueue.main.async { if let map = map { ch.invokeMethod("incoming", arguments: map) } }
      }
    } else {
      pendingIncoming = url
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "initialDoc":
      dartReady = true
      guard let url = pendingIncoming else { result(nil); return }
      pendingIncoming = nil
      background(result) { try self.docMap(url) }
    case "pickDocument":
      present(folder: false, result)
    case "pickFolder":
      present(folder: true, result)
    case "read":
      background(result) { try self.read(ref: args["ref"] as? String ?? "") }
    case "write":
      let src = URL(fileURLWithPath: args["path"] as? String ?? "")
      background(result) {
        defer { try? FileManager.default.removeItem(at: src) }
        try self.write(ref: args["ref"] as? String ?? "", from: src)
        return true
      }
    case "exists":
      background(result) { self.status(ref: args["ref"] as? String ?? "") == "ok" }
    case "status":
      background(result) { self.status(ref: args["ref"] as? String ?? "") }
    case "existsInFolder":
      background(result) {
        try self.withFolder(args["ref"] as? String ?? "") { folder in
          FileManager.default.fileExists(atPath: folder.appendingPathComponent(args["name"] as? String ?? "").path)
        }
      }
    case "writeInFolder":
      let src = URL(fileURLWithPath: args["path"] as? String ?? "")
      let name = args["name"] as? String ?? "Untitled.pdf"
      background(result) {
        defer { try? FileManager.default.removeItem(at: src) }
        return try self.withFolder(args["ref"] as? String ?? "") { folder in
          let url = folder.appendingPathComponent(name)
          try self.coordinatedWrite(from: src, to: url)
          return try self.locationMap(url)
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func background(_ result: @escaping FlutterResult, _ work: @escaping () throws -> Any?) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let value = try work()
        DispatchQueue.main.async { result(value) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "io", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  // MARK: pickers

  private func present(folder: Bool, _ result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(FlutterError(code: "busy", message: "A picker is already open", details: nil))
      return
    }
    guard let top = topViewController() else {
      result(FlutterError(code: "ui", message: "No view controller", details: nil))
      return
    }
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: folder ? [.folder] : [.pdf], asCopy: false)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    pendingResult = result
    pickingFolder = folder
    top.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pendingResult, let url = urls.first else { return }
    pendingResult = nil
    let folder = pickingFolder
    background(result) {
      if folder {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bm = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return ["ref": bm.base64EncodedString(), "name": url.lastPathComponent]
      }
      return try self.docMap(url)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingResult?(nil)
    pendingResult = nil
  }

  private func topViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    var vc = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
  }

  // MARK: bookmarks and coordinated IO

  private func resolve(_ ref: String) throws -> (URL, Bool) {
    guard let data = Data(base64Encoded: ref) else {
      throw NSError(domain: "BasicPDF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad bookmark"])
    }
    var stale = false
    let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    return (url, stale)
  }

  private func withFolder<T>(_ ref: String, _ body: (URL) throws -> T) throws -> T {
    let (folder, _) = try resolve(ref)
    let scoped = folder.startAccessingSecurityScopedResource()
    defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
    return try body(folder)
  }

  /// Copies [url] into a new temp file and returns its path.
  private func coordinatedCopy(_ url: URL) throws -> String {
    let dest = xferDir.appendingPathComponent("in-\(UUID().uuidString).pdf")
    var coordError: NSError?
    var failure: Error?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
      do { try FileManager.default.copyItem(at: u, to: dest) } catch { failure = error }
    }
    if let e = coordError ?? failure {
      try? FileManager.default.removeItem(at: dest)
      throw e
    }
    return dest.path
  }

  private func coordinatedWrite(from src: URL, to url: URL) throws {
    // Memory-mapped: the bytes are not loaded into RAM up front.
    let data = try Data(contentsOf: src, options: .alwaysMapped)
    var coordError: NSError?
    var failure: Error?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
      do {
        try data.write(to: u, options: .atomic)
      } catch {
        // Some providers refuse the temp-file swap; write in place instead.
        do { try data.write(to: u) } catch { failure = error }
      }
    }
    if let e = coordError { throw e }
    if let e = failure { throw e }
  }

  private func locationMap(_ url: URL) throws -> [String: Any] {
    let bm = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    return [
      "kind": "bookmark",
      "ref": bm.base64EncodedString(),
      "id": url.standardizedFileURL.path,
      "name": url.lastPathComponent,
      "folder": folderLabel(url),
    ]
  }

  private func folderLabel(_ url: URL) -> String {
    let parent = url.deletingLastPathComponent()
    if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
       parent.standardizedFileURL.path == docs.standardizedFileURL.path {
      return "On My iPhone ▸ Basic PDF"
    }
    if parent.path.contains("Mobile Documents") && parent.lastPathComponent.hasPrefix("com~apple~CloudDocs") {
      return "iCloud Drive"
    }
    return parent.lastPathComponent
  }

  private func docMap(_ url: URL) throws -> [String: Any] {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let path = try coordinatedCopy(url)
    var map = try locationMap(url)
    map["path"] = path
    map["temp"] = true
    map["writable"] = FileManager.default.isWritableFile(atPath: url.path)
    return map
  }

  private func read(ref: String) throws -> [String: Any] {
    let (url, stale) = try resolve(ref)
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let path = try coordinatedCopy(url)
    var newRef = ref
    if stale, let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
      newRef = bm.base64EncodedString()
    }
    return ["path": path, "temp": true, "ref": newRef]
  }

  private func write(ref: String, from src: URL) throws {
    let (url, _) = try resolve(ref)
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    try coordinatedWrite(from: src, to: url)
  }

  /// "ok", "missing" (the file is gone) or "noAccess" (the bookmark no longer
  /// grants access, e.g. it went stale and can't be refreshed).
  private func status(ref: String) -> String {
    let url: URL
    do {
      url = try resolve(ref).0
    } catch {
      let e = error as NSError
      if e.domain == NSCocoaErrorDomain &&
        (e.code == NSFileNoSuchFileError || e.code == NSFileReadNoSuchFileError) {
        return "missing"
      }
      return "noAccess"
    }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let fm = FileManager.default
    if !fm.fileExists(atPath: url.path) { return "missing" }
    return fm.isReadableFile(atPath: url.path) ? "ok" : "noAccess"
  }
}
