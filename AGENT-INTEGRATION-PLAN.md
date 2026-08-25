# 🤖 План интеграции: агентский монтаж (Монтажка ↔ контент-завод)

**Дата:** 2026-07-06
**Статус:** план утверждён, реализация не начата
**Как продолжить в новой сессии:** «реализуй часть A по AGENT-INTEGRATION-PLAN.md» (или часть B — она делается после A). Выполненные этапы отмечать галочками прямо в этом файле.

---

## 🎯 Цель

Агент (Claude Code / Codex) из контент-завода (`/Users/alex/Documents/content-factory`) самостоятельно монтирует видео через Монтажку: режет паузы, убирает оговорки и неудачные дубли **по смыслу речи**, улучшает голос, добавляет музыку, экспортирует готовый файл.

**Утверждённые решения (не пересматривать):**
1. Управление через CLI-команды Монтажки (не GUI-автоматизация, не MCP-сервер).
2. Умный монтаж с пониманием речи: whisper-транскрипт с таймкодами → агент решает вырезки (оговорки, дубли, «эмм», повторы) → передаёт монтажке диапазоны.
3. Workflow: черновик → отчёт на русском → Александр может открыть проект в GUI и посмотреть → «ок» → экспорт.

## 🗺 Общая схема пайплайна

```
«смонтируй видео из ~/Videos/urok.mov» (content-factory, скилл /video-editing)
  1. montazhka.sh cli new --video …          → projectId
  2. montazhka.sh cli extract-audio …        → audio.wav (16 кГц моно)
  3. whisper-cli -oj …                       → transcript.json (таймкоды)
  4. агент читает транскрипт, решает вырезки → cuts.json (source-координаты + причины)
  5. montazhka.sh cli remove-pauses …        → паузы по тишине
  6. montazhka.sh cli cut --ranges cuts.json → смысловые вырезки
  7. montazhka.sh cli set --voice on …       → голос/музыка
  8. отчёт на русском → Александр (проект открывается в GUI — тот же JSON!)
  9. после «ок»: montazhka.sh cli export     → output/video/YYYY-MM-DD-slug.mp4
```

Ключевой мост: проект, созданный через CLI, лежит в том же `~/Library/Application Support/Montazhka/Projects/<uuid>.json` — открывается в GUI обычным способом, ручная проверка и доводка работают «бесплатно».

---

## 🧠 Ключевые дизайн-решения

### 1. Координаты вырезок — координаты ИСХОДНИКА (source), не таймлайна

- Whisper даёт таймкоды исходного файла — агент берёт вырезки прямо из транскрипта без пересчёта.
- Таймлайн-координаты сдвигаются после каждой вырезки — источник ошибок; source-координаты неизменны: батч из 20 вырезок применяется атомарно, порядконезависимо и **идемпотентно** (повторная отправка того же cuts.json ничего не ломает).
- Модель уже source-ориентирована: `Clip{sourcePath, start, end}`.

Новая чистая функция в `TimelineOps` (существующая `removingRange` в таймлайн-координатах остаётся для GUI):

```swift
/// Вырезает диапазоны, заданные в секундах ИСХОДНИКА, из всех клипов этого исходника.
/// Чистое интервальное вычитание: порядконезависимо, идемпотентно.
static func removingSourceRanges(clips: [Clip], sourcePath: String,
                                 ranges: [(start: Double, end: Double)]) -> [Clip]
```

Исключение: паузы по тишине через агента не гоняются — `cli remove-pauses` детектит и режет внутри Swift за один вызов (конвертация координат остаётся внутри процесса).

### 2. Формат обмена — гибрид

- **Все мутации — через CLI-глаголы** (`cut`, `remove-pauses`, `set`): математику ленты, загрузку длительностей, `updatedAt` делает Swift, не агент.
- **Чтение — свободное:** `cli info` выдаёт полный JSON проекта + карту «таймлайн ↔ исходник»; прямое чтение `<uuid>.json` тоже допустимо.
- **Формат проекта НЕ меняется вообще** (вырезки — это просто список clips) → GUI-совместимость автоматическая, старые проекты не затронуты.

### 3. Набор CLI-команд

Диспетчер в `main.swift`: первый аргумент `cli`, второй — глагол. Без внешних зависимостей (парсинг руками, как в проекте принято).

| Команда | Что делает | stdout (JSON) |
|---|---|---|
| `cli new --video <p> [--video <p2>…] [--name N]` | создать проект | `{ok, projectId, name, clips, duration}` |
| `cli info --project <id\|latest>` | проект + карта таймлайна | полный JSON + `timeline:[{clipIndex, timelineStart, sourcePath, sourceStart, sourceEnd}]` |
| `cli analyze --project <id> [--threshold-db --min-pause --padding-ms]` | отчёт о паузах, без мутаций | `{pauses:[{timelineStart, timelineEnd, sourcePath, sourceStart, sourceEnd, duration}]}` |
| `cli extract-audio --project <id> [--source N \| --input <video>] --out <f.wav>` | WAV 16 кГц моно PCM16 для whisper | `{ok, path, duration}` |
| `cli cut --project <id> --ranges <cuts.json\|->` | вырезать source-диапазоны | `{applied, skipped:[{range,reason}], durationBefore, durationAfter, clipCount}` |
| `cli remove-pauses --project <id> [параметры детекции]` | детект + вырезка пауз за один шаг | `{removed, durationBefore, durationAfter}` |
| `cli set --project <id> [--voice on/off --leveling N --noise N --presence N] [--music on/off --music-track ID --music-file P --music-volume N --music-eq on/off] [--name N]` | настройки | обновлённые настройки |
| `cli tracks` | список встроенных мелодий | `{tracks:[{id,title}]}` |
| `cli export --project <id> --out <f.mp4> [--quality high\|medium\|light] [--timeout сек]` | полный рендер-пайплайн | `{ok, path, duration, quality, elapsed}` |

Формат `cuts.json` (вход `cut`):

```json
{"ranges": [
  {"source": "/path/urok.mov", "start": 74.2, "end": 79.8, "reason": "неудачный дубль, фраза повторена в 80.1"},
  {"source": "/path/urok.mov", "start": 121.0, "end": 121.9, "reason": "«эмм» + оговорка"}
]}
```

`reason` монтажке не нужен, но возвращается эхом в `applied` — единый источник истины для человеческого отчёта агента.

**Контракт вывода:** stdout — ровно один JSON-объект (`{"ok":true,…}` или `{"ok":false,"error":"…"}`); stderr — прогресс и лог (при экспорте `progress 42%` каждые ~2 с — это же heartbeat против таймаутов). Коды выхода: `0` успех, `1` неверные аргументы, `2` ошибка обработки/экспорта, `3` watchdog-таймаут, `4` проект/файл не найден.

### 4. extract-audio — нативно

AVAssetReader с outputSettings [LinearPCM, 16000 Гц, 1 канал, 16 бит] → `AVAudioFile` WAV (~60 строк; паттерн PCM-чтения уже есть в `WaveformStore.extract`). Один инструмент для агента без внешних условий; фолбэк на ffmpeg — на стороне скилла в заводе.

### 5. Переиспользование существующего кода

- **CLIRunner** обобщает `SelfTest.run()` (`Sources/Montazhka/SelfTest/SelfTest.swift:24-39`): `setvbuf` → сторожевой watchdog → `Task.detached` с `exit()` → `RunLoop.main.run()`. Одна обёртка на все команды.
- **`CompositionBuilder.build(clips:enhancedAudio:music:)`** (`Engine/CompositionBuilder.swift:16`) — используется `export` как есть.
- **analyze / remove-pauses** повторяют путь селфтеста: `WaveformStore.ensure` → `SilenceDetector.findPauses` (`SelfTest.swift:130-160`).
- **Экспорт** — по образцу селфтеста (`AVAssetExportSession`, `SelfTest.swift:176-185`) + `ExportQuality.preset` (`Engine/Exporter.swift:26-32`). НЕ через `ExportModel` (он `@MainActor` + NSSavePanel).
- **VoiceEnhanceStore / MusicEQStore / MusicLibrary** — экспорт-пайплайн, как его собирает GUI.
- **`ProjectStore`** получает `init(baseDir: URL = <текущий>)` (дефолтный параметр = обратная совместимость) — селфтесты CLI работают во временной папке, не трогая реальные проекты.

---

## 🔧 ЧАСТЬ A — доработка Монтажки (CLI для агента)

### A1. `TimelineOps.removingSourceRanges` + селфтесты
- [ ] Изменить `Sources/Montazhka/Engine/TimelineOps.swift`: интервальное вычитание source-диапазонов — клэмп к `[clip.start, clip.end]`, слияние пересекающихся диапазонов, допуск 0.02 с на микрообрезки (как в `removingRange`).
- [ ] Тесты в `SelfTest.swift` (`testTimelineMath`): вырезка из середины делит клип; пересечение границы clip.start; два пересекающихся диапазона = один; диапазон вне клипа — no-op; идемпотентность (повторное применение не меняет результат); чужой sourcePath не трогается.
- [ ] Проверка: `swift build && .build/debug/Montazhka --selftest` — новые пункты зелёные, старые не сломаны.

### A2. Инфраструктура CLI
- [ ] Создать `Sources/Montazhka/CLI/CLIOutput.swift`: `emit(Encodable)` → один JSON в stdout (prettyPrinted+sortedKeys, как ProjectStore); `fail(code:message:) -> Never` → `{"ok":false,"error":…}` + exit-код; `progress(String)` → stderr.
- [ ] Создать `Sources/Montazhka/CLI/CLIRunner.swift`: `run(timeout: TimeInterval = 300, _ body: @escaping () async throws -> some Encodable) -> Never` — обобщённый паттерн из SelfTest (RunLoop + watchdog + exit).
- [ ] Создать `Sources/Montazhka/CLI/AgentCLI.swift`: `dispatch(_ args: [String]) -> Never` — разбор глагола и флагов; скрытый флаг `--store-dir <path>` у всех команд (для тестов → `ProjectStore(baseDir:)`).
- [ ] Изменить `Sources/Montazhka/main.swift`: ветка `if arguments.count > 1, arguments[1] == "cli" { AgentCLI.dispatch(…) }` ПЕРЕД существующими; `--selftest`/`--gen-video`/`--open-latest` не трогать.
- [ ] Проверка: `.build/debug/Montazhka cli` без глагола → JSON-ошибка со списком команд, код 1; GUI запускается как раньше.

### A3. Команды `new`, `info`, `set`, `tracks`
- [ ] Создать `Sources/Montazhka/CLI/ProjectCommands.swift`; изменить `Models/ProjectStore.swift` (только `init(baseDir:)` с дефолтом).
- [ ] `new`: проверка существования и читаемости каждого видео (`AVURLAsset.load(.isReadable/.duration)`) с внятной ошибкой про доступ (ранняя диагностика TCC); клип на весь файл; имя по умолчанию из `ProjectStore.defaultProjectName()`.
- [ ] Резолвер `--project`: UUID → файл в Projects/; `latest` → максимальный `updatedAt`; путь к `.json` → напрямую.
- [ ] `set`: валидация `--music-track` через `MusicLibrary.track(id:)`, диапазоны значений 0–100.
- [ ] Проверка руками: демо-видео из `--gen-video` → `cli new` → `cli info --project latest` → `cli set --voice on` → открыть проект в GUI, галочка голоса включена.

### A4. Команды `analyze`, `extract-audio`
- [ ] Создать `Sources/Montazhka/CLI/AnalyzeCommands.swift`: `WaveformStore.ensure` для каждого исходника → `SilenceDetector.findPauses` → вывод в ОБЕИХ системах координат (таймлайн из детектора; source — обратной конвертацией по клипам, хелпер рядом с TimelineOps). Переданные параметры детекции сохранять в `project.detection` (GUI покажет те же паузы).
- [ ] Создать `Sources/Montazhka/CLI/AudioExtractor.swift`: `extractWAV(source: URL, to: URL) async throws` — AVAssetReader [LinearPCM, 16000 Гц, 1 канал, 16 бит] → AVAudioFile WAV. По умолчанию `--source 0`; допускается `--input <видеофайл>` без проекта.
- [ ] Проверка: демо-видео → 2 паузы с теми же границами, что в селфтесте (~3.2–4.8 и ~8.2–9.3); `afinfo out.wav` → 16000 Гц моно; `whisper-cli -f out.wav` не ругается на формат.

### A5. Команды `cut`, `remove-pauses`
- [ ] Создать `Sources/Montazhka/CLI/EditCommands.swift`.
- [ ] `cut`: читает `--ranges <file|->` (`-` = stdin), группирует по `source`, валидирует (start<end, source среди клипов — иначе в `skipped` с причиной), применяет `removingSourceRanges`, сохраняет проект, отчёт `durationBefore/After` + эхо `reason`.
- [ ] `remove-pauses`: analyze-логика → `TimelineOps.removingRange` по каждой паузе в порядке убывания таймлайн-старта (внутри процесса безопасно) → сохранение + отчёт с вырезанным в source-координатах (агент сопоставит с транскриптом).
- [ ] Проверка: демо 12 с → `remove-pauses` → `info` показывает ~8.5 с (число из селфтеста); `cut` с диапазоном в уже вырезанной зоне → в `skipped`, длительность не меняется.

### A6. Команда `export`
- [ ] Создать `Sources/Montazhka/CLI/ExportCommand.swift`. Пайплайн как в GUI: если `voiceEnhance.enabled` → `VoiceEnhanceStore.ensure` по каждому уникальному sourcePath (stderr: `enhance 1/2 …`); если музыка → URL (customPath приоритетнее trackID), при `eqEnabled` → `MusicEQStore.ensure`; `CompositionBuilder.build` → `AVAssetExportSession` с пресетом `ExportQuality(rawValue: --quality)`.
- [ ] Прогресс: цикл `while session.status == .exporting` в отдельной задаче, печать `session.progress` в stderr каждые 2 с. `--timeout` (дефолт 1800 с) переопределяет watchdog. `removeItem` перед записью выходного файла.
- [ ] Проверка: `cli export --project latest --out /tmp/x.mp4 --quality light` на демо-проекте → файл играет, длительность совпадает с `info`, в JSON-ответе `elapsed`.

### A7. Селфтесты CLI + README
- [ ] Создать `Sources/Montazhka/SelfTest/CLISelfTest.swift`, подключить в `SelfTest.runAll`. Ядро каждой команды — async-функция (`exit()` только в обёртке AgentCLI) → тесты in-process, без спавна процессов.
- [ ] Сценарий «полный агентский путь» с временным `ProjectStore(baseDir: tmp)`: сгенерировать демо-видео → new → analyze (2 паузы) → remove-pauses (длительность ~8.5) → cut одного source-диапазона (длительность уменьшилась ровно на него) → cut повторно (идемпотентность) → extract-audio (16 кГц через `AVAudioFile.processingFormat`) → export light (mp4 с видео+звуком, длительность сходится).
- [ ] Негативные тесты: несуществующий проект, битый ranges-json.
- [ ] README: раздел «CLI для агентов» — таблица команд, формат cuts.json, коды выхода.
- [ ] **Гейт всей части A:** `swift build -c release && .build/release/Montazhka --selftest` — всё зелёное; `scripts/build-app.sh` собирается; GUI открывает CLI-созданный проект.

---

## 🏭 ЧАСТЬ B — цех в content-factory

Все пути ниже — относительно `/Users/alex/Documents/content-factory`.

### B1. Скрипты скилла
- [ ] Создать `.claude/skills/video-editing/scripts/montazhka.sh` — обёртка-резолвер бинарника (решает кириллицу/пробелы в пути один раз):

```bash
#!/bin/bash
set -euo pipefail
CANDIDATES=(
  "${MONTAZHKA_BIN:-}"
  "/Applications/Монтажка.app/Contents/MacOS/Montazhka"
  "$HOME/Documents/Вайбкодинг/Программы macos/Монтажка/.build/release/Montazhka"
)
for BIN in "${CANDIDATES[@]}"; do
  [ -n "$BIN" ] && [ -x "$BIN" ] && exec "$BIN" "$@"
done
echo '{"ok":false,"error":"Монтажка не найдена. Соберите: swift build -c release, или scripts/build-app.sh --install"}' >&2
exit 4
```

- [ ] Создать `.claude/skills/video-editing/scripts/transcribe-video.sh <audio.wav> <out-prefix>`: `whisper-cli -m models/whisper/ggml-base.bin -f "$1" -l ru -oj -of "$2"` — обязательно **с** таймкодами (`-oj` даёт JSON с offsets в мс; в `scripts/youtube-transcript-extract.py` стоит `-nt` — там таймкоды выкидываются, здесь они и есть суть). Фолбэк извлечения аудио — ffmpeg, если у монтажки нет `extract-audio`.
- [ ] Проверка: на любом видео extract-audio → transcribe → в JSON есть `offsets.from/to` у сегментов.

### B2. SKILL.md
- [ ] Создать `.claude/skills/video-editing/SKILL.md` + `references/report-template.md`. Один скилл (пайплайн линейный, гейт подтверждения — внутренний шаг, паттерн «превью → подтверждение → действие» уже принят в заводе).
- [ ] Frontmatter: `name: video-editing`, `label: "🎬 Монтаж видео"`, триггеры: «смонтируй видео», «сделай рилс из этого видео», «вырежи паузы из видео», «почисти видео», «убери оговорки», «монтаж», «/video-edit».
- [ ] Пайплайн в SKILL.md:
  1. Вход: путь к видео (одному или нескольким). Рабочая папка `output/video/work/YYYY-MM-DD-<slug>/` (audio.wav, transcript.json, cuts.json, report.md).
  2. `montazhka.sh cli new` → запомнить projectId (дальше работать ТОЛЬКО с явным projectId, не `latest`).
  3. `cli extract-audio` → `transcribe-video.sh`. Видео длиннее ~20 мин — через `run_in_background`.
  4. Анализ транскрипта агентом (ядро скилла): вырезать оговорки, «эмм/ааа», повторы фраз (из двух дублей оставлять ВТОРОЙ — обычно чище), фальстарты, технические реплики («так, сейчас»). Правила безопасности: отступы ±0.15–0.2 с от границ слов (таймкоды whisper приблизительны); при сомнении — НЕ вырезать; границы сверять с паузами из `cli analyze` — резать по тишине, не посреди слова. Результат — cuts.json с `reason` на русском.
  5. `cli remove-pauses`, затем `cli cut --ranges cuts.json` (cut принимает source-координаты — от remove-pauses не зависит).
  6. По запросу: `cli set --voice on`, музыка из `cli tracks` (если пусто — предложить `--music-file`).
  7. Отчёт и СТОП: показать отчёт по шаблону + «Можешь открыть проект „<имя>" в Монтажке и посмотреть. Скажи „ок" — экспортирую». Опционально — быстрый черновик `--quality light` в `output/video/drafts/`.
  8. После «ок»: `cli export --quality medium` (или high по запросу) → `output/video/YYYY-MM-DD-<slug>.mp4`, через `run_in_background`, успех — по финальному JSON. `output/video/*.mp4` — в .gitignore (крупные бинарники в git не тащить).
- [ ] Шаблон отчёта (`references/report-template.md`, простой русский, без простыней таймкодов):

```
Смонтировал «урок про промпты».

Было: 14 мин 20 сек → Стало: 11 мин 05 сек (убрал 3 мин 15 сек)

Паузы: вырезал 27 пауз тишины — 1 мин 50 сек.
Речь: вырезал 6 кусков — 1 мин 25 сек:
  1. 2:14 — оговорка, ты перезаписал фразу заново (34 сек)
  2. 5:02 — «эмм» и долгий поиск слова (8 сек)
  …
Голос: включил улучшение (выравнивание громкости + чистка шума).

Проект «Монтаж 6 июля» открывается в Монтажке — можешь глянуть.
Скажи «ок» — экспортирую в среднем качестве.
```

### B3. Регистрация в заводе
- [ ] `.claude/CLAUDE.md`: строка в таблицу «Маршрутизация запросов»: `| смонтируй видео, вырежи паузы, рилс из видео, монтаж | /video-editing |`.
- [ ] `docs/skills-reference.md`: раздел про скилл по образцу соседних.
- [ ] `docs/project-structure.md`: описать `output/video/` (work/ — рабочие материалы, drafts/ — черновые рендеры, корень — готовые ролики `YYYY-MM-DD-<slug>.mp4`).
- [ ] `knowledge/products.md`: карточка «Монтажка» (свой macOS-видеоредактор, Swift/AVFoundation, автопаузы + голос + музыка, CLI для агентов) по формату существующих карточек.
- [ ] Зеркало `.agents/skills/` НЕ трогать — обновится pre-commit хуком.
- [ ] Проверка: новая сессия Claude Code в content-factory, фраза «вырежи паузы из видео X» → скилл триггерится.

### B4. Сквозная проверка на реальном видео
- [ ] Реальное видео Александра 5–15 мин: полный цикл до отчёта → открыть проект в GUI, глазами проверить вырезки → «ок» → экспорт → файл в `output/video/`.
- [ ] Отдельно кейс «видео на Рабочем столе» (TCC, риск №3).

---

## ⚠️ Риски и грабли

1. **Кириллица и пробелы в путях.** Любой невзятый в кавычки путь ломает bash. Решение: единственная точка входа `montazhka.sh` с `exec "$BIN" "$@"`; в SKILL.md — запрет вызывать бинарник по прямому пути.
2. **AVFoundation в CLI.** Без `RunLoop.main.run()` колбэки AVAssetWriter/ExportSession не приходят — каждая команда обязана идти через CLIRunner (паттерн из SelfTest). Watchdog обязателен: молчаливое зависание → код 3, агент не ждёт вечно.
3. **TCC-доступ к ~/Desktop, ~/Downloads, ~/Documents.** Бинарник не в sandbox, но macOS гейтит по правам родительского процесса (терминала). Симптом коварный: AVAsset тихо отдаёт 0 треков. Митигация: явная проверка читаемости в `cli new` с понятной ошибкой; рекомендация класть исходники в `output/video/work/`.
4. **Длинные рендеры против таймаута Bash-тула (10 мин).** whisper и `export` для длинных видео — только `run_in_background`; прогресс в stderr; критерий успеха — финальный JSON, а не отсутствие вывода.
5. **Точность whisper-таймкодов (ggml-base, русский).** Возможны ошибки распознавания → неверные вырезки. Митигации: «сомневаешься — не режь», отступы ±0.15–0.2 с, резка в тишине (сверка с analyze), обязательный человеческий гейт перед экспортом. Апгрейд до `ggml-small`/`large-v3-turbo` потом — интерфейс не меняется.
6. **GUI и CLI одновременно.** Файловый JSON без локов, last-write-wins. Правило: открывать проект в GUI после того, как агент закончил; не держать открытым во время монтажа. Workflow последовательный по дизайну — этого достаточно.
7. **Обратная совместимость формата.** Схема проекта не меняется вовсе; `ProjectStore.init(baseDir:)` — с дефолтным значением; селфтест декодирования старых JSON остаётся гейтом.
8. **Ресурсы raw-бинарника.** Фолбэк `MusicLibrary` на `Resources/Music` зависит от `#filePath` (путь машины сборки). Музыка гарантируется у `.app`-варианта; `cli tracks` честно вернёт пустой список — скилл предложит `--music-file`.
9. **`latest` — гонка имён.** Если параллельно создан проект в GUI, `latest` укажет не туда. После `new` всегда работать с явным projectId; `latest` — только для ручной отладки.

---

## 💡 Будущие идеи (не в объём этого плана)

- Субтитры: whisper-транскрипт уже будет — можно жечь в видео или класть рядом .srt.
- Вертикальный рефрейм 9:16 для рилсов/шортсов.
- Апгрейд whisper-модели до large-v3-turbo.
- Удалённый запуск монтажа из Telegram-бота завода (`bot/claude_runner.py` уже умеет headless-запуск claude).
