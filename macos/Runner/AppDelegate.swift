import Cocoa
import FlutterMacOS
import dart_smb2
import path_provider_foundation
import sqlite3_flutter_libs

@main
class AppDelegate: FlutterAppDelegate {
  static func main() {
    guard CommandLine.arguments.contains("--headless") else {
      _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
      return
    }

    // NSApplicationMain loads MainMenu.xib and activates a normal application.
    // A CLI process must opt out before either of those can happen.
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let delegate = HeadlessApplicationDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) {
      application.run()
    }
  }

  var flutterResult: FlutterResult?
  var directoryPath: URL!

  override func applicationDidFinishLaunching(_ notification: Notification) {
      let controller: FlutterViewController = mainFlutterWindow?.contentViewController as! FlutterViewController
      let methodChannel = FlutterMethodChannel(name: "venera/method_channel", binaryMessenger: controller.engine.binaryMessenger)

      methodChannel.setMethodCallHandler { (call, result) in
        switch call.method {
        case "getProxy":
            if let proxySettings = CFNetworkCopySystemProxySettings()?.takeUnretainedValue() as NSDictionary? {
                if let httpProxy = proxySettings[kCFNetworkProxiesHTTPProxy] as? String,
                   let httpPort = proxySettings[kCFNetworkProxiesHTTPPort] as? Int {
                    let proxyConfig = "\(httpProxy):\(httpPort)"
                    result(proxyConfig)
                } else if let socksProxy = proxySettings[kCFNetworkProxiesSOCKSProxy] as? String,
                          let socksPort = proxySettings[kCFNetworkProxiesSOCKSPort] as? Int {
                    let proxyConfig = "\(socksProxy):\(socksPort)"
                    result(proxyConfig)
                } else {
                    result("")
                }
            } else {
                result("")
            }
        case "getDirectoryPath":
          self.flutterResult = result
          self.getDirectoryPath()
        case "stopAccessingSecurityScopedResource":
          self.directoryPath?.stopAccessingSecurityScopedResource()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let clipboardChannel = FlutterMethodChannel(name: "venera/clipboard", binaryMessenger: controller.engine.binaryMessenger)

      clipboardChannel.setMethodCallHandler { (call, result) in
        switch call.method {
        case "writeImageToClipboard":
          guard let arguments = call.arguments as? [String: Any],
            let data = arguments["data"] as? FlutterStandardTypedData else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments", details: nil))
            return
          }

          guard let image = NSImage(data: data.data) else {
            result(FlutterError(code: "INVALID_IMAGE", message: "Could not create image from data", details: nil))
            return
          }

          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          pasteboard.writeObjects([image])
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

  func getDirectoryPath() {
      let openPanel = NSOpenPanel()
      openPanel.canChooseDirectories = true
      openPanel.canChooseFiles = false
      openPanel.allowsMultipleSelection = false

      openPanel.begin { (result) in
          if result == .OK {
              self.directoryPath = openPanel.urls.first
              if let directoryPath = self.directoryPath, !directoryPath.startAccessingSecurityScopedResource() {
                  self.flutterResult?(nil)
                  return
              }
              self.flutterResult?(self.directoryPath?.path)
          } else {
              self.flutterResult?(nil)
          }
      }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }
}

/// A windowless engine keeps CLI calls out of the desktop window lifecycle.
/// Only plugins used by CLI operations are registered: UI plugins may require
/// a view/window even when their Dart entry points are never called.
private final class HeadlessApplicationDelegate: FlutterAppDelegate {
  private var engine: FlutterEngine?
  private var platformChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let count = Int(ProcessInfo.processInfo.environment["FLUTTER_ENGINE_SWITCHES"] ?? "0") ?? 0
    if count >= 0 && count < 50 {
      setenv("FLUTTER_ENGINE_SWITCHES", String(count + 1), 1)
      setenv("FLUTTER_ENGINE_SWITCH_\(count + 1)", "disable-vm-service", 1)
    }

    let project = FlutterDartProject()
    project.dartEntrypointArguments = Array(CommandLine.arguments.dropFirst())
    let engine = FlutterEngine(name: "Venera headless", project: project, allowHeadlessExecution: true)
    self.engine = engine
    guard engine.run(withEntrypoint: nil) else {
      let failure = "{\"protocolVersion\":1,\"status\":\"error\",\"code\":\"engine_start_failed\",\"message\":\"Could not start the headless engine.\",\"data\":null}\n"
      FileHandle.standardOutput.write(Data(failure.utf8))
      exit(1)
    }
    PathProviderPlugin.register(with: engine.registrar(forPlugin: "PathProviderPlugin"))
    Sqlite3FlutterLibsPlugin.register(with: engine.registrar(forPlugin: "Sqlite3FlutterLibsPlugin"))
    DartSmb2Plugin.register(with: engine.registrar(forPlugin: "DartSmb2Plugin"))

    let channel = FlutterMethodChannel(name: "venera/method_channel", binaryMessenger: engine.binaryMessenger)
    platformChannel = channel
    channel.setMethodCallHandler { call, result in
      guard call.method == "getProxy" else {
        result(FlutterError(code: "interaction_required", message: "This operation requires the desktop interface.", details: nil))
        return
      }
      guard let settings = CFNetworkCopySystemProxySettings()?.takeUnretainedValue() as? [String: Any] else {
        result("")
        return
      }
      if let host = settings[kCFNetworkProxiesHTTPProxy as String] as? String,
         let port = settings[kCFNetworkProxiesHTTPPort as String] as? Int {
        result("\(host):\(port)")
      } else if let host = settings[kCFNetworkProxiesSOCKSProxy as String] as? String,
                let port = settings[kCFNetworkProxiesSOCKSPort as String] as? Int {
        result("\(host):\(port)")
      } else {
        result("")
      }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }
}
