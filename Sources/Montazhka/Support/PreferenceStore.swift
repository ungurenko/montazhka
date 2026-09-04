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

extension PreferenceStoring {
    /// Настройка-перечисление по ключу. Записи нет или её больше не разобрать —
    /// значит настройки нет, и вызывающий берёт своё значение по умолчанию.
    func value<Value: RawRepresentable>(forKey key: String) -> Value?
    where Value.RawValue == String {
        string(forKey: key).flatMap(Value.init(rawValue:))
    }
}

/// Настройка-перечисление, которая живёт в хранилище одной строкой. Тип
/// называет только ключ и значение по умолчанию — пара «сохранить/восстановить»
/// на все такие настройки одна.
protocol StoredPreference: RawRepresentable where RawValue == String {
    static var key: String { get }
    static var fallback: Self { get }
}

extension StoredPreference {
    static func saved(
        in store: any PreferenceStoring = UserDefaultsPreferenceStore.standard
    ) -> Self {
        store.value(forKey: key) ?? fallback
    }

    func save(in store: any PreferenceStoring = UserDefaultsPreferenceStore.standard) {
        store.set(rawValue, forKey: Self.key)
    }
}
