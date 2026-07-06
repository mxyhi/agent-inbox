import AppKit
import AgentInboxCore
import Foundation
import Sparkle

/// Sparkle 自动更新门面。仅在打包版 Info.plist 写入 feed 与公钥后启动，避免本地裸二进制误报配置错误。
@MainActor
final class AppUpdateController: ObservableObject {
    private var updaterController: SPUStandardUpdaterController?

    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }

    init() {
        NetworkProxySessionBridge.install()
    }

    func start(proxyConfig: NetworkProxyConfig) {
        applyProxyConfig(proxyConfig)

        guard Self.hasRequiredConfiguration else {
            NSLog("Agent Inbox updater disabled: missing SUFeedURL or SUPublicEDKey")
            updaterController = nil
            return
        }
        guard updaterController == nil else { return }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        NSLog("Agent Inbox updater started")
    }

    func applyProxyConfig(_ config: NetworkProxyConfig) {
        NetworkProxySessionBridge.update(config)
        NSLog("Agent Inbox update proxy applied: urlSet=\(!config.isEmpty), usable=\(config.isUsable)")
    }

    func checkForUpdates() {
        guard let updaterController else {
            NSLog("Agent Inbox update check skipped: updater is not configured")
            return
        }

        updaterController.checkForUpdates(nil)
    }

    private static var hasRequiredConfiguration: Bool {
        guard
            let feedURLString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            URL(string: feedURLString) != nil,
            let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return false
        }

        return !feedURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
