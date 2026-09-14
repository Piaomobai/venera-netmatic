# Scheduled tasks, ranking monitor, and silent incremental download

Design notes and integration contracts for the `lib/foundation/scheduler/`
subsystem. Written against venera 1.6.3 (`pubspec.yaml:5`), Flutter 3.41.4,
Dart SDK `>=3.8.0 <4.0.0`, targeting Windows desktop.

## Goal

1. A scheduling engine with persistent task definitions and run history.
2. A ranking monitor that periodically scans comic sources' ranking categories
   and detects newly-appeared entries.
3. Incremental silent downloading: only fetch chapters that appeared since the
   last run, into venera's existing local structured storage.
4. A visual task-queue page to create / edit / monitor / stop tasks.
5. A local file-management page for the downloaded library.

## Phases

| Phase | Content | State |
|---|---|---|
| 1 | Cron engine + schedule model + task model + store + engine | analyzed, tested, verified end-to-end through the built binary |
| 2 | Ranking monitor task | paging and config unit-tested; dispatch verified end-to-end (skipped, no sources installed); no run against a live source |
| 3 | Incremental silent download task | delta and config unit-tested; no download has actually run |
| 4 | Visual task queue + file manager + headless CLI + wiring | analyzed, widget-tested, renders in the built app |

All four phases are written. `flutter analyze` and `flutter test` pass with zero
issues attributable to this work, `flutter build windows` succeeds, and the
headless scheduler command has been run against the real executable. See
"Verification status" below for exactly what that does and does not prove.

Files added:

```
lib/foundation/scheduler/cron.dart                        CronExpression
lib/foundation/scheduler/schedule.dart                    ScheduleSpec
lib/foundation/scheduler/task.dart                        task model + runner registry
lib/foundation/scheduler/store.dart                       SQLite persistence + seen_items
lib/foundation/scheduler/engine.dart                      tick loop + run bookkeeping
lib/foundation/scheduler/tasks/builtin.dart               registerBuiltInTaskRunners()
lib/foundation/scheduler/tasks/comic_download_planner.dart incremental delta + enqueue
lib/foundation/scheduler/tasks/ranking_monitor.dart       rankingMonitor runner
lib/foundation/scheduler/tasks/incremental_download.dart  incrementalDownload runner
lib/pages/scheduler/scheduler_page.dart                   task queue UI
lib/pages/scheduler/task_editor_page.dart                 create / edit UI
lib/pages/scheduler/scheduler_home_card.dart              Home-page entries
lib/pages/storage_manager_page.dart                       file management UI
test/cron_test.dart                                       differential cron test
test/schedule_test.dart                                   schedule + task model tests
test/scheduler_engine_test.dart                           store + engine tests
test/scheduler_runners_test.dart                          runner config tests
```

Files modified:

```
lib/init.dart              checkUpdates() now calls _startScheduler()
lib/pages/main_page.dart   two new paneActions (scheduler, storage)
lib/pages/home_page.dart   two new Home cards
lib/headless.dart          new `scheduler` command
assets/translation.json    zh_CN and zh_TW entries (536 keys each)
windows/CMakeLists.txt     one add_compile_definitions line (see below)
tool/e2e_scheduler.py      drives the built binary for end-to-end checks
```

## Where the features are reachable

| Feature | Entry point |
|---|---|
| Task queue | Home card, or the clock icon in the nav rail |
| Create / edit a task | "+" in the queue app bar, or "Edit" in a task's menu |
| Run history + recent log | "Run history" in a task's menu |
| File management | Home card, or the storage icon in the nav rail |
| Chapter pruning | Storage page, per comic, "Manage chapters" |
| Unattended run | `venera --headless scheduler rundue` |

Headless subcommands: `list`, `rundue`, `run <id>`. They print the same
`[CLI PRINT] {json}` protocol the other headless commands use, and never touch
`App.rootContext` (there is no UI to show a toast in).

The four navigation tabs in `main_page.dart` are deliberately left alone. Adding
a fifth `PaneItemEntry` would also require extending `_pages` in step, since
`pageBuilder: (index) => _pages[index]` indexes both lists in parallel, and it
would shift the values of `appdata.settings['initialPage']` that the settings
page offers. New destinations were added as `paneActions` instead, which needs
no index bookkeeping.

## Layering

`cron.dart` and `schedule.dart` are pure Dart with no Flutter and no venera
imports, so they are unit-testable in isolation. Everything above them touches
app state.

```
cron.dart      CronExpression: parse, matches, next          (no deps)
schedule.dart  ScheduleSpec: interval + friendly presets      (imports cron.dart)
task.dart      task definitions, run records, runner registry (imports schedule.dart)
store.dart     SQLite persistence                            (imports sqlite3, app.dart)
engine.dart    tick loop, due-task dispatch, run bookkeeping  (imports all of the above)
tasks/*.dart   concrete runners (ranking monitor, incremental download)
```

## Verification status

**Verified with the real toolchain.**

```
Flutter 3.47.3 (stable) · Dart 3.13.3 · Rust 1.85.1 (pinned by rust-toolchain.toml)
flutter pub get        OK
flutter analyze        13 issues, 0 of them in scheduler/storage/headless code
flutter test           193 tests, all passing, 0 skipped
flutter build windows --release  OK -> build\windows\x64\runner\Release\venera-netmatic.exe
```

Packaged as `Venera-win64.zip` (19.68 MB, 49 files), SHA256
`6FED2554BAA7F0D4D6B83F6629940FBA467919CD8E5E2C89E91C6A1B3B99799F`. The archive's
`data/app.so` was diffed against the freshly built one to confirm the zip is not
stale — Dart AOT code lives there, not in `venera-netmatic.exe`.

### Windows build prerequisites

The build needs four things, three of which were missing on the machine this
was developed on:

1. **Windows Developer Mode.** Flutter registers plugins with directory
   symlinks, which an unprivileged process may only create when Developer Mode
   is on. Without it the build stops immediately with "Building with plugins
   requires symlink support". Enable with
   `start ms-settings:developers`, or:
   ```
   reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1
   ```
   Note that PowerShell's `New-Item -ItemType SymbolicLink` still fails even
   with Developer Mode on, because that cmdlet does not pass the
   `SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE` flag. `mklink /D` succeeds, and
   so does Flutter. Testing Developer Mode with `New-Item` gives a false negative.
2. **NuGet**, required by `flutter_inappwebview_windows` to fetch
   `Microsoft.Windows.CppWinRT`, `Microsoft.Web.WebView2` and friends.
   `winget install --id Microsoft.NuGet`.
3. **Rust**, required because `rhttp` compiles native code through cargokit.
   `winget install --id Rustlang.Rustup`, then the project's pinned 1.85.1
   toolchain installs itself on first use.
4. **Visual Studio with the C++ workload** — VS 18 Build Tools already present.

### One project change made for the build

`windows/CMakeLists.txt` gained a single `add_compile_definitions` line:

```cmake
add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)
```

`local_auth_windows` includes the deprecated `<experimental/coroutine>` header,
and MSVC 14.5x (Visual Studio 18) promotes that deprecation to a hard error
(STL1011) which aborts the build. This is the mitigation the error message itself
recommends. It must be set before `flutter/generated_plugins.cmake` adds the
plugin subdirectories, because `add_compile_definitions` only affects targets
created afterwards. It is scoped to the Windows build and touches no Dart code.

### End-to-end verification against the built binary

`tool/e2e_scheduler.py` drives the real executable, not a test harness:

```
venera-netmatic.exe --headless scheduler list     -> {"total":0,...,"tasks":[]}
# insert one due task into the app's own scheduler.db, then:
venera-netmatic.exe --headless scheduler list     -> {"total":1,"enabled":1,...}
venera-netmatic.exe --headless scheduler rundue   -> lastState "skipped", lastRunAt set,
                                            nextRunAt advanced by exactly the
                                            interval, minute-truncated
# task_runs row: state=skipped, duration=0.021s,
#   message="No installed comic source exposes a ranking list"
```

That exercises the SQLite schema (`scheduled_tasks`, `task_runs`, `seen_items`),
task serialization round-trip, due-task dispatch, the runner, rescheduling and
run-history persistence, all through the Windows binary. "skipped" rather than
"failed" is correct: no comic sources are installed, so the ranking monitor has
nothing to scan.

Launching the GUI with no arguments then leaving it for 20 seconds produces no
exceptions on stderr — the app boots, initialises every manager and renders the
Home page including both new cards.

#### Against a live comic source

The ranking monitor has since been verified against a real source. With a Pica
(哔咔) source installed, a `rankingMonitor` task run from the GUI produced:

```
Running task "E2E ranking scan"
uri: https://picaapi.picacomic.com/comics/leaderboard?tt=H24&ct=VC
statusCode: 200
Task "E2E ranking scan" finished: success
last_summary: {"sourcesScanned":1,"optionsScanned":1,"failedOptions":0,
               "comicsListed":40,"newComics":0,"processed":0,
               "favorited":0,"queuedForDownload":0,"detailFailures":0}
```

So the full path works: source discovery, ranked-list paging (`load`, 1-based),
`Res.subData` handling, the seen-items table, and the summary. The user reports
that incremental downloads triggered from the UI also work.

### When tasks actually run

The engine is driven by an in-process timer, so it only runs while the app is
open. Two mechanisms make that acceptable:

* **Overdue catch-up (always on).** If a task's slot passed while the app was
  closed, it runs on the next check. Verified end to end: a daily 12:00 task was
  caught up when the app was opened at 12:24.
* **`runOnStart` (opt-in, per task).** Marks an enabled task due at startup even
  when its next slot is still in the future. This covers the case catch-up
  cannot: an interval longer than a typical session, where the slot never
  arrives while the app is open.

The first check runs `initialCheckDelay` (3 s) after the engine starts rather
than waiting a full `tickInterval` (20 s), so a startup run happens within a few
seconds. Verified end to end with `tool/probe_run_on_start.py`: with the next
slot 4 hours in the future and only `runOnStart` set, the task ran **5.8 seconds
after launch** and then rescheduled to its normal slot.

Previously this check waited a full tick. That delay, plus a slow first start
(QuickJS parsing the installed comic sources), is what made an overdue task look
like it had not run at all in a 40-second observation window.

**Interrupted runs are closed on startup.** A run killed mid-flight never reaches
`finishRun`, which left two inconsistent records: the task's `lastState` stayed
`running`, and the matching `task_runs` row stayed `running` *forever*. The engine
already repaired the task, but the history row was left showing a run that starts
and never ends — which is exactly what the run-history UI renders. Startup now
calls `SchedulerStore.closeInterruptedRuns()`, which marks those rows `cancelled`
and stamps `finished_at` (via `MAX(started_at, now)`, so it can never precede
`started_at`). It is idempotent, so a second startup is a no-op.

| Test file | Covers |
|---|---|
| `cron_test.dart` | `CronExpression`, including the differential oracle |
| `schedule_test.dart` | `ScheduleSpec`, `TaskDefinition`, `TaskRetryPolicy` |
| `scheduler_runners_test.dart` | runner registration, identity, config validation |
| `download_planner_test.dart` | the incremental chapter delta (feature 3's core) |
| `ranking_monitor_test.dart` | ranking-list paging (feature 2's core) |
| `scheduler_engine_test.dart` | SQLite store, tick loop, retry, interrupted-run recovery |
| `local_layout_test.dart` | on-disk source/author/title layout, and pure source grouping |
| `ui_widgets_test.dart` | the three UI pages, rendered and interacted with |

Two pieces of logic were deliberately refactored to make them testable, because
neither could be reached from a plain test:

* `ComicDownloadPlanner.computeDelta` is now a pure function over primitives.
  Previously the delta was computed inline against `LocalManager`, which needs
  `path_provider` and a real library on disk, so the single most important
  decision in the feature — *which chapters to fetch* — had no test at all.
* `RankingMonitorRunner.scanOption` is now static and loader-injected.
  `RankingData` already took its loaders as constructor arguments, so fakes can
  exercise both paging conventions without a network or a comic source.

`pubspec.yaml` pins `environment: flutter: 3.41.4`, but pub treats a bare
version there as a *minimum*, so the installed 3.47.3 resolves without changes.

All 13 analyzer issues are pre-existing in files this work never touched — 8
`deprecated_member_use` in `utils/io.dart`, `components/image.dart`,
`pages/reader/comic_image.dart` and `pages/favorites/favorite_actions.dart`,
2 `unawaited_return_in_try_block` in `cached_image.dart` and `app_dio.dart`,
1 `unused_import` in `history.dart`, and one **pre-existing analyzer error** in
`network/file_downloader.dart:187` (`return_without_value`). The scheduler code
adds none.

### What the real toolchain caught that no static check could

This is the payoff for finally compiling. Every item below was invisible to the
Node harnesses in `cron-verify/`, which check brackets, translation keys and
parameter *names* but cannot type-check.

| # | Bug | Kind |
|---|---|---|
| 1 | `store.dart` used `ScheduleSpec` without importing `schedule.dart` | **compile error** — Dart imports are not transitive, so importing `task.dart` did not bring it in |
| 2 | `copyWith(nextRunAt: null)` was a no-op, because `copyWith` reads `nextRunAt ?? this.nextRunAt` | **logic bug** — disabling a task never cleared its next run; caught by the engine test |
| 3 | `createTask` never called `runner.validateConfig` | **logic bug** — a task could be persisted with an invalid config and fail on every run |
| 4 | `ScheduleSpec.weekly` range-checked *after* `normalizeWeekday`, so `8` and `14` wrapped to valid days | **logic bug** |
| 5 | `decodeTaskList` threw `FormatException` on malformed JSON instead of returning empty | **logic bug** in a persistence path |
| 6 | two unused imports, two `unnecessary_brace_in_string_interps`, one doc-comment `<id>` read as HTML | lints |
| 7 | `StorageManagerPage` read `LocalManager().path`, a `late` field set by `LocalManager.init()` | **runtime crash** — `LateInitializationError` thrown from `build()` |
| 8 | `StorageManagerPage` read `CacheManager().currentSize`, which derives from `App.cachePath`, another `late` field | **runtime crash** |
| 9 | both Home cards returned a `Column` but were placed in `home_page.dart`'s `slivers:` list | **runtime layout crash** — "A RenderViewport expected a child of type RenderSliver but received RenderFlex" |

Items 7 and 8 were found by the **widget tests**, not by `flutter analyze`, and
not by any static check. `flutter analyze` is perfectly happy with a `late` field
read; only executing `build()` reveals it. Both are now guarded, so the pages
degrade gracefully instead of throwing when an optional subsystem is not ready,
and that guard is what makes the pages testable at all.

Item 9 was missed by *both* `flutter analyze` **and** the widget tests, and was
only caught by launching the built Windows app. The reason is instructive: a
widget that returns a `Column` is a perfectly valid `Widget`, so it type-checks,
and my widget tests rendered `SchedulerPage`, `TaskEditorPage` and
`StorageManagerPage` but never a card inside a `slivers:` list. There is now a
regression test that pumps each card into a real `CustomScrollView(slivers: [...])`
— which is exactly the failing condition — so the gap is closed.

Widget tests also exposed dead code: `task_editor_page.dart` seeded the weekly
schedule with Monday, but the seed only ran when the schedule type was *already*
weekly, which is never true for a new task. Removing it was the correct fix, and
the behaviour it was trying to create — an explicit weekday choice — is now
covered by a test that asserts saving is refused until a day is picked.

Test bugs the toolchain also exposed: coverage-floor assertions calibrated for
sample counts I later reduced, an assumption that *every* runner's default config
is valid (incremental download's deliberately is not, since a favourites folder
cannot be guessed), and an expectation that weekday `7` would be rejected — it is
a valid alias for Sunday.

### Tests need sqlite3.dll

`test/scheduler_engine_test.dart` needs the native sqlite3 library. In the built
app `sqlite3_flutter_libs` places `sqlite3.dll` next to the executable, but
`flutter test` runs on the host VM, where it is not on the search path. The tests
probe for it once and print an explicit `SKIPPED` notice rather than reporting a
false failure. To make them actually run, put a `sqlite3.dll` on `PATH`; Python's
works:

```
$env:Path = "$env:LOCALAPPDATA\Programs\Python\Python313\DLLs;$env:Path"
flutter test
```

### Not yet verified

- **Nobody has driven the UI interactively.** The app boots and renders without
  exceptions, widget tests exercise the pages and their interactions, and the
  user has edited a task in the real window (changing its schedule to daily 12:00
  and selecting a source), so the queue and editor do work in practice. What is
  still unseen is a deliberate click-through at various screen sizes; layout
  problems that only appear at a particular window size would not have been
  caught.
- **`autoFavorite` has not been exercised.** The ranking monitor's code path that
  adds new comics to a favourites folder is covered only by config validation.
  It needs a run that actually detects a new comic, which is not something a test
  can force against a live source.
- **A scheduled download is now verified end to end.** It had been the one
  unproven link, because every observed run reported `newComics: 0` — the
  `seen_items` table already held the whole ranking, so nothing was ever new.
  With that table cleared, one run against picacg reported
  `comicsListed: 40, newComics: 40, processed: 1, queuedForDownload: 1` and wrote
  a real `ImagesDownloadTask` into `downloading_tasks.json`. See *Remembered
  comics* below for why the counters stayed at zero for so long.

### Supporting static checks

`CronExpression` uses a fast "advance to the next candidate" algorithm, which is
easy to get subtly wrong. Every result is therefore cross-checked against an
independently written brute-force oracle (expand each field by testing every
candidate value; find the next run by scanning minute by minute).

- `test/cron_test.dart` runs that differential comparison as a permanent test.
- Before the Dart toolchain was available the same algorithm was mirrored to
  JavaScript and validated in `cron-verify/` at the workspace root:
  13,079,634 comparisons, 0 failures. That harness also caught a real bug —
  folding day-of-week `7 -> 0` *before* iterating collapsed `*/2` from
  `{0,2,4,6}` to `{0}`. Normalization must be applied per collected value,
  never to the range bounds.
- `cron-verify/check_expectations.js` validates the concrete expected values
  hard-coded in `test/cron_test.dart` against the verified engine, so a
  mis-computed expectation cannot be baked into the test suite.
- `cron-verify/check_dart.js` performs the strongest check possible without the
  SDK: it masks comments and string-literal text (handling nested same-quote
  interpolation, multi-line interpolation and raw triple-quoted strings), then
  verifies bracket balance and nesting. It was validated in both directions —
  it detects injected missing braces, unterminated strings and mismatched
  brackets with correct line numbers, and reports zero problems across all 153
  Dart files in this repository.
- `cron-verify/check_translations.js` validates `assets/translation.json`:
  `JSON.parse` accepts duplicate object keys silently (last wins), so a mistyped
  key would be ignored at runtime with no error. The script scans the file as
  text to detect duplicates, checks that `zh_CN` and `zh_TW` carry identical key
  sets, and reports which `.tl` strings in the UI files have no translation.
  It caught a real duplicate (`Clear Cache` already existed, and a second entry
  was added) and exposed an adjacent-string-literal bug in which `.tl` bound to
  only half of a concatenated helper string.
- `cron-verify/check_api.js` checks every call site in the scheduler files
  against venera's real signatures. It indexes all 548 classes and the top-level
  functions in `lib/`, recording the named parameters of each constructor and
  method, then verifies for each call that every `name:` argument is declared,
  every `required` named parameter is supplied, and the positional argument
  count is in range. It resolves `Appbar`, `Button.filled`, `Button.icon`,
  `Select`, `OptionChip`, `MenuButton`, `showConfirmDialog`, `openComicFolder`
  and the rest of the venera surface used here.

  Getting this tool honest took four rounds of fixing **its own** bugs, each
  found by noticing that pristine venera files were being flagged:
  a constructor *declaration* looks exactly like a call; `static` methods have
  no declared return type, so `Log.error` was invisible; a default value such as
  `Duration d = const Duration(minutes: 5)` sits at the same brace depth as the
  declaration containing it and was indexed as a declaration in its own right;
  and `Future<void> showConfirmDialog(` was skipped because the `>` closing a
  generic return type was mistaken for an operator. Only after those fixes does
  it report clean on the scheduler code, and
  `cron-verify/fixtures/api_calls.dart` exists to prove it still fails on bad
  input — it detects all four injected error kinds while passing the correct
  calls in the same file.
- `cron-verify/test_mask.js` self-tests the shared lexical masking module. It
  caught a wrong assumption about `splitTopLevel` (it operates on masked text,
  where string bodies are already blanked, so it does not need to skip commas
  inside literals).

Run all of them at once:

```
cd cron-verify
powershell -NoProfile -ExecutionPolicy Bypass -File check_all.ps1
```

`check_all.ps1` also runs both **negative** tests, asserting that the structural
checker still reports 3 of 3 deliberately broken fixtures and the API checker
still reports 4 of 4 deliberately wrong calls. A checker that passes on good
input proves nothing on its own.

**The static checkers supplement the compiler, they do not replace it.** They
cannot type-check, resolve a name to a type, check nullability, or see any API
outside venera's own `lib/` — which includes every Flutter widget used by the UI
(`Scaffold`, `Column`, `TextField`, `CheckboxListTile`,
`LinearProgressIndicator`, …). Those were matched by reading the Flutter API's
shape. `cron-verify/` earns its place because it caught the cron day-of-week bug
and pinned the algorithm before Dart was available; `flutter analyze` and
`flutter test` are now the authority.

## Remembered comics

The ranking monitor keeps a record of comics it has **finished with**, in the
`seen_items` table under the namespace `ranking:<sourceKey>`. A comic counts as
"new" only while it is absent from that record, which is what stops a nightly
scan from re-downloading the same titles forever.

### The record is written only once the download is settled

The first implementation wrote the record at *detection* time, before any
follow-up action was considered:

```dart
// WRONG -- the original code, since replaced by a read-only isSeen check
final isNew = SchedulerStore().markSeen(namespace, comic.id);
if (isNew) discovered.add(...);
```

That made "seen" mean *listed* rather than *handled*, and it silently lost
downloads in four separate ways:

| Case | What the old code recorded | Consequence |
|---|---|---|
| `autoDownload` off | every comic | turning the toggle on later did nothing |
| more new comics than `maxNewPerRun` | every comic, including the untried tail | `N left for the next run` was a lie; those titles never came back |
| comic details failed to load | the comic | never retried |
| queueing the download failed | the comic | never retried |

The scan is now read-only, and `_remember` runs only once
`DownloadFollowUp.isSettled` says the download is done with:

```dart
// _handOffDownload
if (!plan.hasWork)  return DownloadFollowUp.alreadyComplete;  // already on disk
if (enqueue(plan))  return DownloadFollowUp.queued;           // handed over
return isQueued(plan)
    ? DownloadFollowUp.alreadyQueued                          // already owed
    : DownloadFollowUp.failed;                                // stays unrecorded
```

`failed` is deliberately the only unsettled outcome, and therefore the only one
that is never recorded. `DownloadFollowUp` exists as a value precisely so that
rule can be tested without a source, a store, or a library on disk —
`download_planner_test.dart` pins it, including that `failed` is the *only*
unsettled value.

Two consequences are intended rather than bugs:

* **With auto-download off, nothing is ever recorded**, so the summary keeps
  reporting the same comics as new on every run. That is accurate — nothing has
  been consumed — and it is exactly what makes switching the toggle on later
  work.
* **A comic is recorded when it is queued, not when its download finishes.** The
  queue is persisted in `downloading_tasks.json` and resumed on start, so a
  queued comic is owed its download either way. Waiting for completion instead
  would re-fetch details for every in-flight comic on every run, which is the
  API traffic the record exists to avoid. The one hole left is a queued download
  that fails permanently inside the download subsystem; the Forget button below
  is the way back from that.

### Verified end to end

Against picacg, whose ranking page is 40 entries:

| `autoDownload` | `maxNewPerRun` | run summary | `seen_items` |
|---|---|---|---|
| off | 3 | `40 new, 40 left for the next run` | **0** |
| on | 3 | `40 new, 3 processed, 1 queued, 2 already complete, 37 left for the next run` | **3** |

The second row is the one that matters: only the three comics actually handed to
the download queue were recorded, and `37 left for the next run` is now
literally true. The two `already complete` were comics whose chapters were
already on disk.

### Resetting it

`SchedulerStore.clearSeen` had existed since the beginning and was never called
from anywhere, so there was no way out of a bad record from the UI. The task
editor now exposes it, under the ranking monitor's options:

```
Remembered comics
Comics this task already reported. Forget them to download them again.
3  ·  picacg: 3                                      [ Forget ]
```

The count is per selected source and updates in place, so the reset is visible
without reopening the editor.

### Related behaviour

* `forgetAfterDays` (default 90) prunes the record on its own, so a title that
  leaves the ranking and later returns is reported again.
* The ranking monitor has **no per-comic chapter limit**, unlike the incremental
  download runner's `maxChaptersPerComic`. Enabling auto-download fetches each
  newly detected comic in full, so a ranking page of 40 entries is a large first
  download. Three comics per run is a safe starting point.
* The run summary gained `upToDate`, `remembered` and `leftForNextRun`, so the
  state of the record is legible from the run history alone.

## Library folder layout

New downloads are grouped as:

```
<library root>/
  <comic source name>/
    <author>/
      <comic title>/
        cover.jpg
        <chapter>/
          0.jpg
          1.jpg
```

so the library has a browsable hierarchy instead of one flat pile of folders.

Naming rules:

* **Source folder** — the source's display name, sanitised. Falls back to
  `Source <n>` when the source cannot be resolved, which happens when a comic was
  downloaded from a source the user has since removed. `ComicType.sourceKey`
  asserts that the source is installed, so it must not be used here.
* **Author folder** — `ComicDetails.findAuthor()`, falling back to `subTitle`
  then `uploader`. When there is no author at all the folder is
  `Unknown Author`, a fixed ASCII name so it does not change with the app
  language.
* **Comic folder** — the title, deduplicated against existing sibling folders.

### The change that made this possible

`LocalComic.directory` used to be either a leaf folder name or an absolute path,
and `baseDir` decided which by testing for a separator:

```dart
// before
String get baseDir => (directory.contains('/') || directory.contains('\\'))
    ? directory
    : FilePath.join(LocalManager().path, directory);
```

A nested relative path like `picacg/author/title` therefore read as absolute, and
every file access for such a comic would break. The check is now
`FilePath.isAbsolute`, which fixes the ambiguity. `utils/pdf.dart` and
`LocalComicImageProvider` had copies of the same heuristic and now use
`comic.baseDir`.

`LocalManager.deleteComic` and `batchDeleteComics` used
`FilePath.join(path, c.directory)`, which is wrong for an absolute directory;
they use `baseDir` now.

### Existing comics are untouched

A stored `directory` of just `My Comic` still resolves to
`<library root>/My Comic`, so nothing already downloaded moves or breaks. Old and
new layouts coexist; only new downloads use the hierarchy. Migrating an existing
library into the new shape is not implemented — it would mean moving files on
disk.

`LocalManager.search` now also matches `directory`, so typing a source or author
name finds everything under that folder.

## In-app grouping on the local comics page

The local comics page used to render one flat grid, which made the new on-disk
hierarchy invisible inside the app: the folders were grouped but the UI was not.
It now renders one titled section per source, styled after the Explore page:

```
[Source A]                                    12
  <grid of that source's comics>
[Source B]                                     3
  <grid>
[Local]                                        5
  <grid>
```

Layout details, so the style stays consistent with Explore:

* Section title — `SizedBox(height: 60)` containing a row with
  `EdgeInsets.fromLTRB(16, 10, 5, 10)`, `fontSize: 20`, `w500`, plus a count
  badge on the right.
* Each group is a `SliverToBoxAdapter` header followed by the page's existing
  grid, so the page still scrolls as one list.

Ordering and naming rules:

* **Group key comes from `comicType`, not from `directory`.** A comic's
  `directory` is a relative path that may or may not carry the hierarchy (old
  comics do not), so parsing it would scatter pre-hierarchy comics into a bogus
  group. `comicType` is exact, and `LocalManager.sourceFolderName` is the same
  function that names the folders on disk, so the UI and the file manager agree.
* **Locally imported comics sort last**; named sources sort alphabetically,
  case-insensitively.
* **Within a group the page's existing sort is preserved** — grouping must not
  silently reorder what the user already chose.
* `LocalComicsPage.groupBySource` is a public static so it can be tested as pure
  logic, independently of sliver laziness.

### A latent crash this surfaced

`ComicTile` reads `comic.sourceKey`, which for `LocalComic` delegated to
`ComicType.sourceKey`, which does `comicSource!`:

```dart
// lib/foundation/comic_type.dart
String get sourceKey => this == local ? "local" : comicSource!.key;
```

`ComicType.comicSource` returns `ComicSource.fromIntKey(value)`, which is `null`
for any key that is not currently installed. So **a comic downloaded from a
source the user later uninstalled crashed the whole local comics page** with
`Null check operator used on a null value`, not just its own tile. The grouping
work made this visible because the widget test seeds exactly that case.

`FavoriteItem` had already solved this and `LocalComic` simply had not:

```dart
// lib/foundation/local.dart — now matches FavoriteItem
String get sourceKey => comicType == ComicType.local
    ? "local"
    : comicType.comicSource?.key ?? "Unknown:${comicType.value}";
```

The tap handler in `local_comics_page.dart` had the same shape of problem: it
re-derived the type with `ComicType.fromKey(c.sourceKey)!` and then null-asserted
the lookup. Re-deriving cannot round-trip for an orphaned comic, so the lookup
now null-checks and reports `Comic not found` instead of crashing.

Both are covered by `test/ui_widgets_test.dart` → *a comic from an uninstalled
source still reports a source key*, which was confirmed to fail with the exact
`Null check operator` error before the fix and pass after it.

## Key integration contracts

These were read out of the source and are load-bearing. Line numbers refer to
the unmodified 1.6.3 tree.

### Init ordering

`Init.ensureInit()` (`lib/utils/init.dart:12-19`) only *awaits* an init someone
else started; if `init()` was never called it awaits a `Completer` that is never
completed, so it **hangs forever**. Always call the real `init()` /
`App.initComponents()`, or `ComicSourceManager().init()` explicitly.
`lib/headless.dart:33` shows the working pattern: `await init();` first.

### Comic sources and ranking

`lib/foundation/comic_source/comic_source.dart` is a library with `part` files
(`category.dart`, `favorites.dart`, `parser.dart`, `models.dart`, `types.dart`),
so `CategoryData`, `RankingData`, `ComicDetails`, `ComicChapters`, `Comic` and
`ComicID` all come from that one import. `CatalogData` does not exist.

```dart
static List<ComicSource> all();            // comic_source.dart:111
static ComicSource? find(String key);      // comic_source.dart:113
```

Ranking is reachable per source as
`source.categoryComicsData?.rankingData`, whose type is
(`comic_source.dart:487-496`):

```dart
class RankingData {
  final Map<String, String> options;                                   // key -> label
  final Future<Res<List<Comic>>> Function(String option, int page)? load;
  final Future<Res<List<Comic>>> Function(String option, String? next)? loadWithNext;
  const RankingData(this.options, this.load, this.loadWithNext);
}
```

`enableRankingPage` lives on `CategoryData` (`category.dart:10`), **not** on
`RankingData`. `parser.dart` sets exactly one of `load` / `loadWithNext`
(`605-660`). The UI gates only on `enableRankingPage` and then null-asserts
(`ranking_page.dart:24-25`), which can throw; detect ranking support robustly:

```dart
source.categoryData != null &&
source.categoryComicsData?.rankingData != null &&
rankingData.options.isNotEmpty &&
(rankingData.load != null || rankingData.loadWithNext != null)
```

`Res<T>` (`lib/foundation/res.dart`): `error` is a **getter** (`errorMessage !=
null`), `data` **throws** when null, use `dataOrNull` or check `error` first.
`subData` is `dynamic` and carries `maxPage` (for `load`) or the next cursor
(for `loadWithNext`).

Comic detail and pages:

```dart
final r = await source.loadComicInfo!(comicId);        // Res<ComicDetails>
final r = await source.loadComicPages!(comicId, ep);   // Res<List<String>>, ep nullable
```

`ComicDetails` (`models.dart:139+`): the id field is **`comicId`**, and `id` is a
getter returning it. Update time is `String? findUpdateTime()` (sync,
`models.dart:301`), returning `"YYYY-M-D"` with no zero padding. `comicType` is
`ComicType(sourceKey.hashCode)`.

`ComicChapters` (`models.dart:334+`): `ids` is the ordered chapter-id list,
`allChapters` maps id -> title, and a chapter id is what is passed as the `ep`
argument and what becomes the on-disk directory name after
`LocalManager.getChapterDirectoryName`. Pass `null` for comics with no chapters.

### Favorites

`LocalFavoritesManager()` is a singleton (`favorites.dart:205-211`); `init()` is
required and is run by `App.initComponents()`. A **folder is a SQLite table
name** (`local_favorite.db`); there is no `Folder` class.

```dart
bool addComic(String folder, FavoriteItem comic, [int? order, String? updateTime]);  // :601
List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfo(String folder);            // :1212
void updateUpdateTime(String folder, String id, ComicType type, String updateTime);  // :1149
void updateCheckTime(String folder, String id, ComicType type);                      // :1173
void notifyChanges();                                                                // :1247
void prepareTableForFollowUpdates(String table, [bool clearData = true]);             // :1118
```

`prepareTableForFollowUpdates` adds the `last_update_time` / `has_new_update` /
`last_check_time` columns and **must** be called for any folder used with
`getComicsWithUpdatesInfo`; otherwise the row lookup throws. `addComic` throws
`Exception("Folder does not exists")` when the table is missing.

`updateTime`, `lastCheckTime` and `hasNewUpdate` exist only on
`FavoriteItemWithUpdateInfo` (`favorites.dart:161`), never on `FavoriteItem`.

The app's own periodic checker is `FollowUpdatesService` in
`lib/pages/follow_updates_page.dart:537-591` — a static class whose
`initChecker()` starts an **uncancellable** `Timer.periodic(Duration(minutes:
10))`. Its state is library-private, so the scheduler cannot coordinate with it
via its `_isChecking` guard; the two will coexist unless that timer is disabled.

### Download engine

`ImagesDownloadTask` (`lib/network/download.dart:76-516`):

```dart
ImagesDownloadTask({
  required ComicSource source,
  required String comicId,
  ComicDetails? comic,        // fetched by resume() when null
  List<String>? chapters,     // chapter IDs; null = every chapter
  String? comicTitle,
});
```

`resume()`/`pause()`/`cancel()` return `void` (the bodies are `async`), so they
**cannot be awaited** and there is no completion future.

`LocalManager().addTask(task)` (`local.dart:554-559`) appends to the FIFO
`downloadingTasks`, then calls `resume()` on the **head of the list, not the new
task**. So it does not start the new task, and execution is serialised to one
task at a time. Only `completeTask` (`local.dart:502-508`) starts the next.
Hazards: an errored head is re-resumed rather than the queued task; a
manually-paused head is un-paused; tasks restored by `restoreDownloadingTasks()`
are never auto-resumed.

**`resume()` never consults `downloadedChapters` or the filesystem** — it will
re-download chapters and overwrite the same `"$index$ext"` filenames. The caller
must filter:

```dart
final type = ComicType(source.key.hashCode);
final local = LocalManager().find(comicId, type);
final missing = comic.chapters!.ids
    .where((id) => !(local?.downloadedChapters.contains(id) ?? false))
    .toList();
if (missing.isNotEmpty) {
  LocalManager().addTask(ImagesDownloadTask(
    source: source, comicId: comicId, comic: comic, chapters: missing,
  ));
}
```

`LocalManager.add()` merges the previous row's `downloadedChapters` into the new
one (`local.dart:316-336`), so the union is preserved while only the delta is
fetched. `isDownloaded` (`local.dart:455`) is the other reader.

After a successful download `_isRunning` stays `true`, so the same instance can
never be resumed again — a new task must be constructed for further chapters.

### Persistence

`LocalManager._db` is **private** (`local.dart:185`), so the scheduler cannot
reuse that connection. Precedent (`cache_manager.dart:71-90`,
`cookie_jar.dart:14-32`) is to open a separate file, so the scheduler owns
`'${App.dataPath}/scheduler.db'`.

```dart
_db = sqlite3.open('${App.dataPath}/scheduler.db');
_db.execute('CREATE TABLE IF NOT EXISTS ...');
_db.select('SELECT ... WHERE x = ?', [value]);   // ResultSet, ListMixin<Row>
_db.execute('INSERT OR REPLACE INTO t VALUES (?, ?);', [a, b]);
```

`sqlite3.open` is a method on the global `Sqlite3` instance from
`package:sqlite3/sqlite3.dart`. On Windows nothing needs initializing:
`package:sqlite3` loads `sqlite3.dll`, and `sqlite3_flutter_libs` bundles it
next to the executable (`windows/build.iss:73`). Transactions are plain strings
(`'BEGIN TRANSACTION;'` / `'COMMIT;'` / `'ROLLBACK;'`); there is no helper, no
WAL, and nesting is not supported.

`Row` supports both `row[0] as String` (positional) and `row["column"]`
(by name, returns `dynamic` without auto-cast).

Schema migrations follow `history.dart:223-225`: read `PRAGMA table_info(t)` and
`alter table t add column ...` when a column is absent.

### Settings

`appdata.settings['key'] = value` only mutates memory and calls
`notifyListeners()`; **`appdata.saveData()` must be called to persist**, and with
the default `sync: true` it also fires `DataSync().uploadData()`. For
device-local scheduler state prefer the scheduler's own SQLite file, or
`appdata.implicitData['k'] = v` + `appdata.writeImplicitData()`.

`saveData(false)` skips the WebDAV upload.

### Notifications and logging

- `Log.logs` (`log.dart:23`) is a live in-memory `List<LogItem>` capped at 500,
  but there is **no listener, stream, or ChangeNotifier** — per-task run logs
  must be polled (remember `Log.logs.length`, read the tail) or recorded by the
  engine itself. `Log.isMuted = true` (used by headless mode, `headless.dart:20`)
  suppresses both the buffer and the file, so it must stay false when run logs
  are wanted.
- `App.rootContext.showMessage(message: "...")` is the only context-free toast
  (`context.dart:41`, re-exported by `app.dart:12-13`). It requires the root
  Navigator to be mounted, so it **throws in headless mode / before the first
  frame** and must be guarded. There is no OS notification support at all.

### UI integration

- `components/components.dart` contains **no `export` statements** — it is a
  `part`-based library. A page needs explicit imports of
  `foundation/app.dart` (which exports `context.dart` and `widget_utils.dart`,
  giving `context.to`, `App`, `ts`, `.paddingHorizontal`, `.toSliver`),
  `foundation/appdata.dart`, and `utils/translations.dart`.
- `Future<T?> to<T>(Widget Function() builder)` (`context.dart:17`) — **no named
  parameters**. Use `App.rootContext.to(() => const MyPage())` for a full-screen
  page.
- `Appbar` (`appbar.dart:3-28`) takes only `title` (required `Widget`),
  `leading`, `actions`, `backgroundColor`, `style`. There is **no `bottom`**.
- Tabs: `main_page.dart` `_pages` (47-58) and `paneItems` (68-89) are
  index-aligned and must be extended together.
- A Home-page card is one more `const _X()` entry in the `slivers:` list of
  `home_page.dart:31-43`; `_Local` (332) is the template. "Downloading" is
  opened with `showPopUpWidget(context, const DownloadingPage())`, not a route.
- Settings sub-pages must be `part of 'settings_page.dart';` to reach the
  private helpers (`_SwitchSetting`, `_SliderSetting`, `_CallbackSetting`,
  `_SettingPartTitle`); only `SelectSetting` is public. Registering one touches
  four places: `categories`, `icons`, `_buildSettingsContent`, and
  `_SettingsDetailPage._buildPage`.
- `"text".tl` falls back to the source string when a key is missing, so new
  English strings work with no JSON edit. `assets/translation.json` has only
  `zh_CN` and `zh_TW`; `tlEN` would throw and is never used.
- There is no `RefreshIndicator` anywhere; use `ComicList(refreshHandlerCallback:)`
  plus an `IconButton(Icons.refresh)`.

### File management

- `DirectoryExtension.size` — `Future<int> get size` (`io.dart:87-96`) walks the
  directory and sums file lengths. Windows-safe. There is no free-space helper
  and no `DiskSpace` type.
- `bytesToReadableString(int)` (`io.dart:427-437`).
- `Directory.joinFile(name)` exists; `File.joinFile` does not.
- `detectFileType(List<int>)` returns a `FileType` whose `.ext` **includes** the
  leading dot, and is `"."` when the MIME is unknown.
- `import 'package:venera_netmatic/utils/io.dart'` re-exports `dart:io` and
  `dart:typed_data`, so `File`/`Directory` are plain `dart:io` types.
  `AndroidDirectory`, `AndroidFile` and `SAFTTaskWorker` come from
  `package:flutter_saf` and must not be used on Windows.
- `LocalManager().deleteComic(...)`, `deleteComicChapters(...)` and
  `batchDeleteComics(...)` already handle on-disk deletion, favorites and
  history; reuse them rather than deleting directories directly.

## Risks

- **Only a debug build exists.** `flutter build windows --debug` succeeds, but
  `--release` (which additionally runs AOT compilation) has not been attempted,
  so no shippable artifact has been produced. Everything below in this section
  is about *runtime* behaviour no test currently exercises.
- **The UI starts cleanly but has never been driven interactively.** Launching
  the built app for 20 seconds produces no exceptions, and widget tests exercise
  the pages and their interactions, but nobody has clicked through a real window
  at a real screen size. Layout problems that only appear at particular window
  sizes would not have been caught.
- **The ranking monitor and download runner have no integration test.** Both
  depend on `ComicSourceManager` (a QuickJS runtime that needs a Flutter binding
  and real comic-source scripts) and on `LocalManager` (which needs
  `path_provider`), neither of which is reachable inside `flutter test`. Their
  config validation, registration and identity are tested; their scraping and
  enqueueing are not.

### A widget-test gotcha worth recording

`find.byKey` and `find.text` skip **offstage** widgets by default, and widgets
scrolled below the fold count as offstage even though they are fully built. The
first widget test run reported "`Found 0 widgets with key [<'task-save'>]`" for a
button that was demonstrably present in the element tree. The fix is either to
raise the test surface — `tester.view.physicalSize = const Size(1400, 3200)` —
or to scroll the target into view. This is worth knowing because the failure
message actively misleads: it looks like a missing widget, not an off-screen one.
- **Uncancellable 10-minute update timer.** `FollowUpdatesService` keeps running
  alongside the scheduler; duplicate update checks are possible.
- **`addTask` resume semantics.** The download queue is serialised and
  `addTask` does not start the new task, so the engine must not assume a
  container task began when it was enqueued.
- **Rate limiting.** Ranking scans hit third-party sites. The engine needs
  per-source concurrency limits and throttle delays, mirroring
  `follow_updates.dart:119-137` (channel of 10, 5 consumers, throttled every 5
  items). The runners currently throttle with a fixed inter-request delay
  (`throttleMs`, default 300 ms) and the engine runs one task at a time.
- **`newComics` truncation is deliberate but lossy.** The ranking monitor records
  every detected id as seen, then applies follow-up actions (favourite,
  download) to at most `maxNewPerRun`. When it truncates, the remainder is
  *never re-processed* — it is reported in the run summary as
  `processed` vs `newComics` and called out in the run message. Raise
  `maxNewPerRun` if that matters.
- **The ranking monitor does not call `ensureInit()`.** `Init.ensureInit()`
  awaits a `Completer` that is never completed if `init()` was never started
  (`utils/init.dart:12-19`), so calling it from a runner could hang forever.
  Instead the runner reads `ComicSource.all()` and returns a `skipped` outcome
  when it is empty. In the app this is always populated, because
  `LocalManager.init()` finishes with `ComicSourceManager().ensureInit()`
  (`local.dart:297`).
- **"Queued" is not "downloaded".** Both runners report how many tasks they
  added to the download queue. Whether those downloads succeed is the download
  manager's business, visible on the existing Downloading page. Neither runner
  waits for completion, so a scheduled run finishes long before the bytes do.
- **Interrupted runs are terminal, not resumable.** The engine is not a job
  queue: a run that is cancelled or interrupted is recorded as such and
  rescheduled. Task-level idempotency comes from the incremental delta (already
  stored chapters are never re-fetched), not from checkpointing.
- **The engine only runs while the app is open.** It is driven by an
  in-process `Timer.periodic`, so closing venera stops all scheduled work. The
  headless `scheduler rundue` command is the unattended path; wire it to Windows
  Task Scheduler if true 24/7 operation is wanted. A separate always-on service
  would have to reimplement the QuickJS comic-source runtime and the network
  stack, which is why it was not chosen.
- **Measuring the library size is expensive.** `Directory.size` walks the whole
  tree and stats every file, and there is no cached or incremental variant, so
  the Storage page re-measures on every visit. The scan is async and shows
  progress, but on a very large library opening the page still costs a full
  directory walk.
- **The ranking monitor reads the first option only by default.** With an empty
  `options` config it scans `ranking.options.keys.first` per source, because
  some sources expose many options and scanning all of them multiplies the
  request count. Set `options` explicitly to cover more.
- **`pagesPerOption` relies on documented page semantics, not on a type.** For
  `ranking.load` the first page is 1 (`ComicList` uses `int _page = 1`), and
  `Res.subData` is treated as `maxPage` only when it is an `int`. For
  `ranking.loadWithNext` the first cursor is `null` and `subData` is read as the
  next cursor only when it is a non-empty `String`. A source that returns
  something else simply terminates paging early, which is safe but may under-read.
- **The UI has never been rendered.** `scheduler_page.dart`,
  `task_editor_page.dart`, `scheduler_home_card.dart` and
  `storage_manager_page.dart` are the least verified part of this work: layout,
  overflow and runtime widget errors cannot be caught by any tool used here. The
  pure-Dart layers beneath them are the well-tested part.
