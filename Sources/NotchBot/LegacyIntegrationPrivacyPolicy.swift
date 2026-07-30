import Foundation

enum LegacyIntegrationPrivacyPolicy {
    static func recognizes(_ data: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == ["version", "assistantExcerptsEnabled"],
            let version = object["version"] as? NSNumber,
            CFGetTypeID(version) != CFBooleanGetTypeID(),
            version.intValue == 1,
            let enabled = object["assistantExcerptsEnabled"] as? NSNumber,
            CFGetTypeID(enabled) == CFBooleanGetTypeID()
        else {
            return false
        }
        return true
    }
}
