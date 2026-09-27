import Foundation

/// Почему лента поменялась без действий в окне.
enum ExternalChangeNotice: Equatable {
    /// Агент изменил проект, в окне правок не ждало.
    case agentChanged
    /// Агент изменил проект, пока правка окна ждала записи. Версия окна легла
    /// проектом-копией `copyName`; nil — копию сохранить не вышло.
    case agentChangedDuringEdit(copyName: String?)

    var title: String {
        switch self {
        case .agentChanged: "Агент изменил проект — лента обновлена"
        case .agentChangedDuringEdit: "Агент изменил проект во время вашей правки"
        }
    }

    var hint: String {
        switch self {
        case .agentChanged:
            "Вернуть прежнюю версию можно кнопкой «Вернуть как было» или ⌘Z."
        case .agentChangedDuringEdit(let copyName?):
            "Ваша версия сохранена копией «\(copyName)» в списке проектов. «Вернуть как было» вернёт её и здесь."
        case .agentChangedDuringEdit(nil):
            "Ваша последняя правка не сохранилась. «Вернуть как было» вернёт вашу версию вместе с ней."
        }
    }
}
