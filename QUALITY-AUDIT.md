# 🔍 Аудит качества: Монтажка

**Дата:** 2026-08-24
**Что за проект:** нативное macOS-приложение — видеоредактор (Swift 6 + SwiftUI + AVFoundation, ~14 800 строк Swift в Sources+Tests, таргеты MontazhkaCore → MontazhkaKit → тонкий executable). Прямая дистрибуция без App Sandbox — осознанное решение, зафиксированное в `docs/ADR-0001-direct-distribution-without-sandbox.md`.
**Как проверял:** read-only аудит по чек-листу swiftui-macos. Лично прочитаны: `Package.swift`, `project.yml`, `Resources/Info.plist`, оба workflow (CI, release), все релизные скрипты, ADR, `PERFORMANCE-REVIEW.md`, а также целиком `EditorController.swift` (1079 строк), `TimelineView.swift` (857), `CompositionBuilder.swift`, `ProjectStore.swift`, `WaveformStore.swift`, `WaveformAnalysisCoordinator.swift`, `SilenceDetector.swift`, `MediaAccessCoordinator.swift`, `MediaAccessLease`/`MediaReference` в `MontazhkaCore/Models.swift`, ключевые секции `ShortsController.swift`, тесты выборочно. Параллельно 4 скаута прочли остальные зоны (архитектура/состояние, конкурентность, производительность, качество/релиз/антипаттерны). Каждая находка уровня High ниже перепроверена лично по коду; спорная — понижена. Сборки и тесты не запускались (аудит статический); выводы о поведении в рантайме помечены отдельно.

---

## 🚨 Critical

Не найдено. Нарушений мандатных правил с видимыми последствиями (MainActor blocking на горячем пути экрана, data races, сломанный release pipeline) не обнаружено: проект собран в Swift 6 mode со strict concurrency = complete, legacy-Observation отсутствует, релизная цепочка подпись→нотаризация→Gatekeeper целостна.

## ⚠️ High

### 1. Перезапуск экспорта shorts затирает состояние нового экспорта
- **Что найдено:** `startExport(to:)` отменяет старую задачу и создаёт новую (`Sources/Montazhka/Engine/ShortsController.swift:415`, `:423`), но отменённая задача, проснувшись, безусловно выполняет `catch is CancellationError { self.exportState = .idle }` (`:449-450`) и `self.exportTask = nil` (`:454`) — без проверки, что она ещё актуальна.
- **Почему важно:** если пользователь запустит экспорт второй раз (например, выберет другую папку), старая задача сотрёт прогресс и статус новой на `.idle` и обнулит хэндл: кнопка «Отмена» перестанет работать, а экспорт молча продолжится «в никуда». Остальные операции контроллера защищены токенами `LatestOperation`/`Generation` — только у экспорта защиты нет.
- **Как чинить:** по образцу этого же файла — generation-токен: инкремент при старте, `guard generation.isCurrent` перед каждым изменением `exportState` и перед `exportTask = nil`. Альтернатива: захватить локально `let task = Task {...}`, в финале сравнивать identity с `self.exportTask`.

### 2. Синхронный дисковый I/O на главном потоке при подключении исходников
- **Что найдено:** `MediaAccessCoordinator` — `@MainActor`; его `synchronize(_:)` вызывает `makeAccessLease()` синхронно (`Sources/Montazhka/Engine/MediaAccessCoordinator.swift:13-22`). Инициализация lease eagerly резолвит bookmark и дважды делает `FileManager.fileExists` (`Sources/MontazhkaCore/Models.swift:8-14`, `:57-69`). `synchronize` вызывается из `EditorController` при открытии проекта и на каждой правке, меняющей набор исходников (`EditorController.swift:199`, `:478`, `:507`).
- **Почему важно:** на локальном SSD это миллисекунды, но на сетевом/внешнем диске каждый такой вызов подвешивает главный поток — окно замирает. Это уточнённый остаток пункта 6а из `PERFORMANCE-REVIEW.md`: отчёт «файлы пропали» давно вынесен в фон (`MediaAvailabilityMonitor`), а резолв доступа — нет.
- **Как чинить:** вынести создание leases из `synchronize` в async-задачу с generation-токеном (по образцу `MediaAvailabilityMonitor`) либо лениво резолвить URL при первом обращении. Минимальный вариант — обернуть цикл создания leases в `Task.detached` с возвратом готового словаря на главный актор.

### 3. Ядро новых функций без прямых тестов
- **Что найдено:** из ~32 файлов движка ни юнит-тестами, ни селфтестом не покрыты конвейерные акторы: `SmartEditService` (многошаговый анализ: транскрипция → предложения → ревью → границы, `SmartEditService.swift:30+`), `MediaPipeline` как актор (`Tests/MontazhkaTests/MediaPipelineTests.swift` проверяет `CompositionBuilder.buildResult`, не актор), `SpeechTranscriber` (`SpeechTranscriberTests` покрывает только модели `TranscriptWord`/`TranscriptDocument`), а также `ProjectSaveCoordinator`, `OpenRouterKeyManager`, `WaveformAnalysisCoordinator`, `MusicLibrary` (grep по всем 16 тест-файлам — ноль упоминаний) и реальный пайплайн `ShortsCutService.analyze()`.
- **Почему важно:** это самые новые и самые рискованные части (shorts и ИИ-монтаж). Ошибки координации между шагами сейчас ловятся только в рантайме; селфтест покрывает звук/склейку/экспорт, но не логику этих сервисов.
- **Как чинить:** дешёвые юнит-тесты со стабами по уже существующему образцу (`ShortsControllerTests`, `ExportModelTests`): для `SmartEditService` — мок `OpenRouterClient`+`TranscriptStore`; для `SpeechTranscriber` — тест чистой функции `makeWords`; для `MediaPipeline` — подмена voice/music/export-хранилищ. Без сети и реального диска.

### 4. Релиз собирается без dSYM — краши пользователей не разобрать
- **Что найдено:** `scripts/build-app.sh:34-51` собирает `swift build -c release` без генерации dSYM; `scripts/release.sh:26-31` кладёт в архив только `.app`; `.github/workflows/release.yml:72-75` публикует только `*.zip` + `*.sha256`.
- **Почему важно:** при падении у пользователя символы креш-лога не восстановить — останутся голые адреса без имён функций и файлов.
- **Как чинить:** добавить `-Xswiftc -g` в universal-сборку, заархивировать появившийся `Montazhka.dSYM` рядом с `.zip` в `release.sh` и добавить маску `*.dSYM.zip` в публикацию релиза.

## 💡 Improvements

### 1. Поиск пауз нельзя прервать — отработанная задача догоняет до конца
`Task.detached` в `WaveformAnalysisCoordinator.detect` (`WaveformAnalysisCoordinator.swift:50-56`) не сохраняется и не отменяется, а внутри `SilenceDetector.findPauses` (`SilenceDetector.swift:32-62`) нет ни одной проверки `Task.isCancelled`. После повторного запуска поиска старая задача молотит CPU до полного обхода всех клипов — результат потом отбрасывается generation-guard'ом (`:49`, `:57`), страдает только лишняя нагрузка. Чинить: `guard !Task.isCancelled` в цикле по клипам либо хранить detached-задачу и отменять её в `cancel()`.

### 2. Декод волны и будущая семантика Swift 6.2 (условная находка)
Сегодня `maxConcurrentDecodes: 2` работает: `loadOrExtract`/`extract` — nonisolated async и при текущей конфигурации (tools 6.0, без `NonisolatedNonsendingByDefault` — проверено в `Package.swift` и `project.yml`) исполняются на глобальном executor'е, не блокируя актор `WaveformWorkCoordinator` (`WaveformStore.swift:155-169`). Но если проект включит семантику Swift 6.2 («Approachable Concurrency»), тот же код начнёт выполняться на серийном executor'е актора — параллелизм декода исчезнет незаметно. Страховка: пометить `loadOrExtract` атрибутом `@concurrent`, как уже сделано в `VoiceEnhancer.render` и `MusicEQ.render`.

### 3. Локализация — заглушка
`Resources/App/ru.lproj/Localizable.strings` содержит 5 записей вида «ключ = ключ»; String Catalog (`.xcstrings`) отсутствует; `NSLocalizedString` в коде не используется вовсе — при этом ~70 пользовательских строк захардкожены в view'ах и моделях (`StartView.swift:18`, `ExportSheet.swift:38`, `Exporter.swift:14-26`, `OpenRouterClient.swift:16-26` и др.). Для русскоязычного приложения это работает, но инфраструктура создаёт ложное впечатление: `scripts/verify-config.sh` валидирует файл-пустышку. Чинить: либо завести String Catalog и вынести строки в ключи, либо честно удалить пустой `.strings`, зафиксировав одноязычность в README.

### 4. Карточки проектов читают полные файлы проектов
`ProjectStore.listProjects` декодирует целый `Project` ради четырёх полей карточки (`ProjectStore.swift:162-172`) — остаток пункта 6б из `PERFORMANCE-REVIEW.md`. Выполняется в фоне на ioQueue, поэтому заметно станет лишь на сотнях проектов. Чинить: писать компактную мету рядом с проектом при сохранении.

### 5. Блок UI «Ключ OpenRouter» продублирован в двух панелях
Почти идентичные ~55–60 строк: `SmartEditPanel.swift:192-250` и `ShortsView.swift:270-330` (одинаковые подписи, статусы, логика замены ключа). Чинить: общий subview с параметром-контроллером.

### 6. Настройки моделей персистятся в обход DI
Статические `saved`/сохранение через `UserDefaults` прямо в enum'ах: `SmartEditModels.swift:17-25`, `:76-85`; `ShortsModels.swift:31-35`; используется из `EditorController.swift:93-101` и `ShortsController.swift:61`. Работает, но тесты не могут подменить хранилище. Чинить: протокол настроек + инъекция (как уже сделано с `OpenRouterKeyStoring`).

### 7. Зависимость от MontazhkaCore скрыта за фасадом алиасов
`CoreAliases.swift:1-16` — единственный `import MontazhkaCore` в Kit и 14 typealias; реальные зависимости модуля невидимы. Не баг, а вопрос читаемости: убрать фасад или оставить, но осознанно задокументировать.

### 8. Прочее мелкое
- Один UI-тест (`MontazhkaUITests.swift:6-13`); accessibility-идентификаторы уже есть — смоук-тесты редактора и shorts добавятся дёшево.
- CI/release гоняют `macos-15-intel` (`ci.yml:13`, `release.yml:20`) — Intel-образы GitHub сворачивает; кросс-сборка x86_64 с arm64-раннера поддерживается, миграция заранее снимет будущую нестабильность.
- Статический `DateFormatter` в `ProjectStore.swift:185-194` сегодня зовётся только с главного актора (`App.swift:141`) — латентный риск при первом же фоновом вызове; замена на `Date.FormatStyle` снимает вопрос.
- O(n²)-поиски в списках кандидатов (`ShortsView.swift:406`, `SmartEditPanel.swift:435`) — потолок 10 элементов, некритично.

## ✅ Что сделано правильно

- **Наблюдаемость и состояние:** grep legacy-маркеров по Sources чист — `ObservableObject`/`@Published`/`@EnvironmentObject`: 0 вхождений; всё состояние на `@Observable` (AppModel, EditorController, ShortsController, ProjectSaveCoordinator, WaveformAnalysisCoordinator…). Правило №2 соблюдено полностью.
- **Фиксы из PERFORMANCE-REVIEW живы:** №1 параллельная загрузка источников батчами по 4 (`CompositionBuilder.swift:119-137`), №2 коалесинг seek (`EditorController.swift:398-416`), №4 параллельный прогрев волн (`WaveformAnalysisCoordinator.swift:43-48`), №5 параллельные длительности при добавлении (`EditorController.swift:528-582`). Пункт №3 (пересчёт позиций 30 раз/сек) фактически закрыт: однопроходный `TimelineLayout` (`TimelineView.swift:12-24`), курсор изолирован в микро-view `TimelinePlayhead` (`:474-494`) и `TimelinePlaybackFollower` (`:449-472`) — 30 Гц больше не перестраивают ленту.
- **Конкуррентность:** тяжёлая работа вне MainActor — акторы (`ParakeetTranscriber`, `OpenRouterClient`, `ShortsCutService`, `SmartEditService`, `WaveformWorkCoordinator`), `@concurrent`-рендеры, обоснованные `DispatchQueue`/`Task.detached` (AVFoundation-API, watchdog селфтеста, фоновые проверки файлов); отмена двухуровневая — structured (`withTaskCancellationHandler`, `checkCancellation` в `Transcoder`) + generation-токены на контроллерах; `shutdown()` аккуратно гасит задачи и наблюдателей.
- **Архитектура:** `EditorController` (1079 строк) — фасад над 12 узкими коллабораторами, а не god-object; границы `MontazhkaCore ↔ MontazhkaKit` чистые, executable — 5 строк; DI через протоколы и init без контейнерной магии (правила №6, №7).
- **Accessibility:** главные интерактивные элементы размечены (лейблы/hints/actions клипов ленты `TimelineView.swift:648-665`, регулируемая линейка `:198-210`, идентификаторы кнопок в `EditorView`/`ShortsView`/`StartView`) — редкая дисциплина для десктопного SwiftUI.
- **Тестовая дисциплина:** dual-stack разведён правильно — Swift Testing во всех 16 юнит-файлах, XCTest только в UI; CI гоняет линтеры, юниты, UI-тесты, universal ad-hoc сборку и полный селфтест на каждый PR.
- **Release readiness:** цепочка Developer ID → hardened runtime → notarization (`notarytool --wait` + `stapler` + `spctl`) целостна; universal arm64+x86_64 с проверкой архитектур; все 7 секретов объявлены; инструменты пиннуты с SHA256 (`bootstrap-tools.sh`).
- **Антипаттерн-sweep:** ноль реальных попаданий по карте граблей (единственные совпадения — подстроки вроде `highPass`; `print(` только в диагностике селфтеста).

## Статус секций аудита

| # | Секция | Статус |
|---|--------|--------|
| 1 | Mandatory rules (10 правил) | ✅ прочитано |
| 2 | Архитектура и состояние | ✅ прочитано |
| 3 | Конкуррентность | ✅ прочитано |
| 4 | Performance | ✅ прочитано |
| 5 | Качество и тесты | ✅ прочитано |
| 6 | Release readiness + anti-patterns sweep | ✅ прочитано |

Отсутствующие артефакты зафиксированы как находки/факты, а не пропуски: String Catalog отсутствует (💡3), entitlements отсутствуют намеренно (ADR-0001, не применимо), dSYM отсутствует (⚠️4).

---

## 🔧 Исправлено (2026-08-25)

Починено субагентами за два параллельных захода; линт, полный тест-набор (108 тестов / 22
набора) и самопроверка движка — зелёные.

**High:**
- ✅ ⚠️1 Гонка перезапуска экспорта shorts — generation-токен `exportGeneration` в
  `ShortsController.startExport/cancelExport/shutdown`; отменённая задача больше не трогает
  состояние новой.
- ✅ ⚠️2 Дисковый I/O на главном потоке — `MediaAccessCoordinator.synchronize` резолвит
  security-scoped лизы в фоне (`Task.detached` + `sending` + generation), `url(for:)` отдаёт
  путь без дисковых проверок; то же в `ShortsController` (async `sourceAccess`).
- ✅ ⚠️3 Тесты на ядро — добавлено 20 юнит-тестов: `ProjectSaveCoordinatorTests` (6),
  `WaveformAnalysisCoordinatorTests` (4), `MusicLibraryTests` (4), `MediaPipelineActorTests` (2),
  `SpeechWordMappingTests` (4). Без сети и ML-моделей.
- ✅ ⚠️4 dSYM — `build-app.sh` генерирует `Montazhka.dSYM` (`dsymutil`; проверено:
  ~560 тыс. DWARF-записей), `release.sh` кладёт `*-dSYM.zip` + sha256 к релизу.

**Improvements:**
- ✅ 💡1 Поиск пауз прерывается: `isCancelled`-выход в `SilenceDetector.findPauses`, detached-
  задача хранится и отменяется в координаторе.
- ✅ 💡2 Страховка Swift 6.2: `@concurrent` на `WaveformStore.loadOrExtract`.
- ✅ 💡3 Локализация-заглушка удалена честно: `Localizable.strings` (5 identity-ключей) убран,
  `verify-config.sh` обновлён, `CFBundleDevelopmentRegion=ru` сохранён.
- ✅ 💡4 Карточки проектов читают sidecar `<uuid>.meta.json`; полный decode — фолбэк
  (+3 теста в `ProjectStoreTests`); DateFormatter заменён на FormatStyle.
- ✅ 💡5 Блок «Ключ OpenRouter» вынесен в общий `Views/OpenRouterKeyControls.swift`.
- ✅ 💡6 Настройки моделей через протокол `PreferenceStoring` (инъекция в оба контроллера,
  дефолт — UserDefaults; +4 теста).
- ✅ 💡8 Раннеры CI/релиза переведены с `macos-15-intel` на `macos-15`.
- ✅ Пункт №3 из PERFORMANCE-REVIEW признан закрытым (реализован в коде ранее), №6 дозакрыт —
  статусы обновлены в обоих документах.

**Не делалось (осознанно):**
- 💡7 Фасад `CoreAliases` оставлен как есть (вариант «оставить, но осознанно»): чистый churn
  без изменения поведения — правка по запросу.
- O(n²)-поиски в списках кандидатов (n ≤ 10) не тронуты — влияние нулевое.
- UI-смоук-тесты сверх существующего одного не добавлялись.

**Известное окно поведения:** у только что открытого экрана shorts в первый тик источник
адресуется по сохранённому пути до прихода фоновой лизы — для перемещённых файлов prepare может
упасть разово. Проявление маловероятно; если встретится — добавить retry по приходу лизы.

---

*Аудит выполнен в режиме read-only; починка выполнена отдельным шагом 2026-08-25 (см. выше).*

## 🔬 Проход термоядерного ревью (2026-08-25)

Собственный дифф починки прогнан строгим структурным ревью; четыре находки исправлены на месте:
1. Экспорт shorts вместо самодельного `Generation`+ручного хэндла переведён на канонический
   `LatestOperation` (как остальные пять операций контроллера) — минус два поля, минус три места
   bookkeeping'а (`ShortsController.swift`).
2. Из `MediaAccessCoordinator` удалён слой `Pending`-словарей: дедупликация повторных резолвов
   покрывается сравнением reference в `accessBySourceID`, защита устаревших задач — одним
   generation-гвардом.
3. Блок «Ключ OpenRouter» вместо трёх замыканий получил протокол `OpenRouterKeyControlling`
   (4 члена, оба контроллера удовлетворяют без изменений сигнатур); вызовы в панелях сжались
   до трёх аргументов.
4. В `ProjectStore` зафиксирован инвариант «meta на диске = свежая»: неудачная запись sidecar
   удаляет устаревший файл, карточки уходят в полный decode и не показывают ложные данные.

После правок: сборка, линт, 108/108 тестов, ad-hoc сборка приложения и селфтест — зелёные.
