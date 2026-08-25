import Foundation

/// Абстракция над хранилищем настроек: позволяет тестам подменять
/// UserDefaults in-memory-адаптером, а enum'ам — не знать о UserDefaults.
protocol PreferenceStoring: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
}

/// Обёртка над UserDefaults; потокобезопасность обеспечивает сам UserDefaults.
struct UserDefaultsPreferenceStore: PreferenceStoring, @unchecked Sendable {
    static let standard = UserDefaultsPreferenceStore(defaults: .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func set(_ value: String?, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}
