import AgentInboxCore
import Foundation
import ObjectiveC

/// 进程内 URLSession 代理桥。Sparkle 2.9.4 没有公开 sessionConfiguration delegate,
/// 因此在应用进程里替换默认 URLSessionConfiguration,让 appcast 与更新包请求都能读取代理配置。
final class NetworkProxySessionBridge: @unchecked Sendable {
    static let shared = NetworkProxySessionBridge()

    private let lock = NSLock()
    private var isInstalled = false
    private var config = NetworkProxyConfig()

    private init() {}

    static func install() {
        shared.installOnce()
    }

    static func update(_ config: NetworkProxyConfig) {
        shared.update(config)
    }

    fileprivate static func currentProxyDictionary() -> [AnyHashable: Any]? {
        shared.currentProxyDictionary()
    }

    private func installOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !isInstalled else { return }

        guard
            let original = class_getClassMethod(
                URLSessionConfiguration.self,
                #selector(getter: URLSessionConfiguration.default)
            ),
            let replacement = class_getClassMethod(
                URLSessionConfiguration.self,
                #selector(URLSessionConfiguration.agentInbox_defaultSessionConfiguration)
            )
        else {
            NSLog("Agent Inbox update proxy bridge failed: URLSessionConfiguration.default selector missing")
            return
        }

        method_exchangeImplementations(original, replacement)
        isInstalled = true
        NSLog("Agent Inbox update proxy bridge installed")
    }

    private func update(_ nextConfig: NetworkProxyConfig) {
        lock.lock()
        config = nextConfig.normalized
        lock.unlock()
    }

    private func currentProxyDictionary() -> [AnyHashable: Any]? {
        lock.lock()
        let current = config
        lock.unlock()

        guard current.isUsable else {
            return nil
        }

        guard let proxyURL = current.parsedURL,
              let scheme = proxyURL.scheme,
              let host = proxyURL.host,
              let portValue = proxyURL.port else {
            return nil
        }

        let port = NSNumber(value: portValue)
        var dictionary: [AnyHashable: Any]
        if scheme == "http" || scheme == "https" {
            dictionary = [
                kCFNetworkProxiesHTTPEnable as String: NSNumber(value: true),
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: NSNumber(value: true),
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port
            ]
        } else {
            dictionary = [
                kCFNetworkProxiesSOCKSEnable as String: NSNumber(value: true),
                kCFNetworkProxiesSOCKSProxy as String: host,
                kCFNetworkProxiesSOCKSPort as String: port
            ]
        }

        if let user = proxyURL.user, !user.isEmpty {
            dictionary[kCFProxyUsernameKey as String] = user
        }
        if let password = proxyURL.password, !password.isEmpty {
            dictionary[kCFProxyPasswordKey as String] = password
        }
        return dictionary
    }
}

private extension URLSessionConfiguration {
    /// 被 method swizzling 调用:交换后这里先调用原始 default,再补代理字典。
    @objc class func agentInbox_defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.agentInbox_defaultSessionConfiguration()
        if let proxyDictionary = NetworkProxySessionBridge.currentProxyDictionary() {
            configuration.connectionProxyDictionary = proxyDictionary
        }
        return configuration
    }
}
