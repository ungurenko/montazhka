import Foundation
import OSLog

/// Где случилась беда — от этого зависит формулировка.
enum ErrorContext: String, Sendable {
    case project
    case preview
    case clipImport
    case smartEdit
    case shorts
    case export
    case ai

    var logger: Logger {
        switch self {
        case .project, .preview, .clipImport: return .persistence
        case .export, .shorts: return .export
        case .smartEdit, .ai: return .network
        }
    }
}

/// Ошибка в том виде, в котором её можно показать человеку: что случилось
/// и что с этим делать.
///
/// Единственный способ построить её из системной ошибки — `make`, а он всегда
/// пишет оригинал в лог. Поэтому английский текст от AVFoundation физически
/// не может добраться до интерфейса, и при этом не теряется для разбора.
struct UserFacingError: Equatable, Sendable {
    /// Что случилось — обычным языком, без кодов и названий фреймворков.
    let what: String
    /// Что делать дальше. Ошибка без следующего шага оставляет в тупике.
    let hint: String?

    init(_ what: String, hint: String? = nil) {
        self.what = what
        self.hint = hint
    }

    /// Одной строкой — для агентского API и логов.
    var message: String {
        guard let hint else { return what }
        return "\(what) \(hint)"
    }

    /// Переводит любую ошибку в человеческую и записывает оригинал в лог.
    static func make(
        _ error: Error,
        context: ErrorContext,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> UserFacingError {
        context.logger.error(
            "[\(context.rawValue, privacy: .public)] \(String(describing: file), privacy: .public):\(line) \(String(reflecting: error), privacy: .public)"
        )

        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return UserFacingError(description, hint: localized.recoverySuggestion)
        }
        return translate(error as NSError, context: context)
    }

    /// Системные ошибки: домен и код превращаем в понятную фразу.
    private static func translate(_ error: NSError, context: ErrorContext) -> UserFacingError {
        switch error.domain {
        case NSURLErrorDomain:
            return UserFacingError(
                "Нет связи с сервисом.",
                hint: "Проверь интернет и попробуй ещё раз.")
        case AVFoundationErrorDomain:
            return UserFacingError(
                "Система не смогла обработать это видео.",
                hint: "Попробуй другой файл или перезапусти Монтажку.")
        case NSCocoaErrorDomain where error.code == NSFileWriteNoPermissionError,
            NSCocoaErrorDomain where error.code == NSFileWriteVolumeReadOnlyError:
            return UserFacingError(
                "Нет доступа к этой папке.",
                hint: "Выбери другую папку для сохранения.")
        case NSCocoaErrorDomain where error.code == NSFileWriteOutOfSpaceError:
            return UserFacingError(
                "На диске не хватает места.",
                hint: "Освободи место и попробуй ещё раз.")
        case NSCocoaErrorDomain where error.code == NSFileNoSuchFileError:
            return UserFacingError(
                "Файл не найден на прежнем месте.",
                hint: "Возможно, его переименовали или перенесли.")
        default:
            return UserFacingError(fallback(for: context), hint: "Попробуй ещё раз.")
        }
    }

    private static func fallback(for context: ErrorContext) -> String {
        switch context {
        case .project: return "Не получилось открыть проект."
        case .preview: return "Не получилось подготовить просмотр."
        case .clipImport: return "Не получилось добавить видео."
        case .smartEdit: return "Умный монтаж не отработал."
        case .shorts: return "Не получилось нарезать ролики."
        case .export: return "Не получилось сохранить видео."
        case .ai: return "Модель не ответила."
        }
    }
}

/// Импорт AVFoundation нужен только ради имени домена ошибок.
private let AVFoundationErrorDomain = "AVFoundationErrorDomain"
