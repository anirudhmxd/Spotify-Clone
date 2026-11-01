import Flutter
import UIKit

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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RhythmFiles") {
      backupChannel = FlutterMethodChannel(name: "rhythm/files", binaryMessenger: registrar.messenger())
      backupChannel?.setMethodCallHandler { [weak self] call, result in
        guard call.method == "saveLibraryBackup" else { result(FlutterMethodNotImplemented); return }
        self?.saveBackup(call.arguments, result: result)
      }
    }
  }
  private var backupChannel: FlutterMethodChannel?
  private var backupDelegate: BackupPickerDelegate?
  private func saveBackup(_ arguments: Any?, result: @escaping FlutterResult) {
    guard backupDelegate == nil else { result(FlutterError(code: "BUSY", message: "A file picker is already open.", details: nil)); return }
    guard let map = arguments as? [String: Any], let json = map["json"] as? String else {
      result(FlutterError(code: "INVALID", message: "No backup data.", details: nil)); return
    }
    do {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("rhythm-library.json")
      try Data(json.utf8).write(to: url, options: .atomic)
      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) { picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true) }
      else { picker = UIDocumentPickerViewController(url: url, in: .exportToService) }
      let handler = BackupPickerDelegate(directory: directory) { [weak self] saved in
        self?.backupDelegate = nil
        result(saved)
      }
      backupDelegate = handler
      picker.delegate = handler
      picker.modalPresentationStyle = .fullScreen
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      var presenter = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })?.rootViewController
      while let top = presenter?.presentedViewController { presenter = top }
      guard let presenter = presenter else {
        handler.finish(false); return
      }
      presenter.present(picker, animated: true)
    } catch { result(FlutterError(code: "SAVE_FAILED", message: error.localizedDescription, details: nil)) }
  }

}


private final class BackupPickerDelegate: NSObject, UIDocumentPickerDelegate {
  private let directory: URL
  private var completion: ((Bool) -> Void)?
  init(directory: URL, completion: @escaping (Bool) -> Void) { self.directory = directory; self.completion = completion }
  func finish(_ saved: Bool) {
    let callback = completion; completion = nil
    try? FileManager.default.removeItem(at: directory)
    callback?(saved)
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(!urls.isEmpty) }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
}
