import Foundation

/// 设置页展示的应用版本。打包时若手动写入 CFBundleShortVersionString,优先展示该值。
public enum AppVersion {
    public static let fallback = "0.0.1"

    public static func displayValue(shortVersionString: String?) -> String {
        guard let shortVersionString else {
            return fallback
        }

        let trimmed = shortVersionString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
