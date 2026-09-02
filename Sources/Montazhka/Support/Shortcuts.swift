import SwiftUI

/// Горячие клавиши монтажного стола — один источник для меню и подсказок.
///
/// Раньше клавиша называлась дважды: в меню «Монтаж» и вручную в подсказке
/// на кнопке (`"Разрезать в позиции ползунка (S)"`). Расходились они молча.
enum Shortcut: CaseIterable {
    case playPause
    case frameBack
    case frameForward
    case secondBack
    case secondForward
    case split
    case markIn
    case markOut
    case cutSelection
    case deleteClip

    /// Короткое название — для пункта меню.
    var title: String {
        switch self {
        case .playPause: return "Плей/пауза"
        case .frameBack: return "Кадр назад"
        case .frameForward: return "Кадр вперёд"
        case .secondBack: return "Секунда назад"
        case .secondForward: return "Секунда вперёд"
        case .split: return "Разрезать"
        case .markIn: return "Начало выделения"
        case .markOut: return "Конец выделения"
        case .cutSelection: return "Вырезать выделение"
        case .deleteClip: return "Удалить выбранный клип"
        }
    }

    /// Развёрнутое объяснение — для подсказки при наведении на кнопку,
    /// где место есть и полезно сказать точнее.
    var explanation: String {
        switch self {
        case .split: return "Разрезать в позиции ползунка"
        default: return title
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .playPause: return .space
        case .frameBack, .secondBack: return .leftArrow
        case .frameForward, .secondForward: return .rightArrow
        case .split: return "s"
        case .markIn: return "i"
        case .markOut: return "o"
        case .cutSelection: return "x"
        case .deleteClip: return .delete
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .secondBack, .secondForward: return .shift
        default: return []
        }
    }

    /// Как клавиша читается в подсказке.
    var keyLabel: String {
        switch self {
        case .playPause: return "пробел"
        case .frameBack: return "←"
        case .frameForward: return "→"
        case .secondBack: return "⇧←"
        case .secondForward: return "⇧→"
        case .split: return "S"
        case .markIn: return "I"
        case .markOut: return "O"
        case .cutSelection: return "X"
        case .deleteClip: return "Delete"
        }
    }

    /// Готовая подсказка для кнопки: что делает и чем вызывается.
    var hint: String { "\(explanation) (\(keyLabel))" }
}

extension View {
    /// Вешает клавишу из общего списка.
    func keyboardShortcut(_ shortcut: Shortcut) -> some View {
        keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
    }
}
