# Repository Guidelines

## Project Structure & Module Organization
- `lib/`: Dart UI and logic (`main.dart`, MethodChannel client).
- `test/`: Flutter widget/unit tests (`*_test.dart`).
- `android/`: Android app, Kotlin channel handlers, and JNI bridge.
  - `android/app/src/main/kotlin/...`: `MainActivity.kt`, `NativeBridge.kt` (channel `mnn_runner`).
  - `android/app/src/main/cpp/`: C++17 JNI (`mnn_runner.cpp`, `CMakeLists.txt`).
  - Native deps: headers in `android/app/src/main/cpp/third_party/MNN/include`, and `libMNN.so` in `android/app/src/main/jniLibs/${ABI}/`.
- `ios`, `macos`, `linux`, `windows`, `web`: Platform shells.
- `pubspec.yaml`: Dependencies; `analysis_options.yaml`: lint rules.

## Build, Test, and Development Commands
- Install deps: `flutter pub get`
- Run app: `flutter run -d macos` (or `-d android`, `-d ios`, `-d web`)
- Analyze code: `flutter analyze`
- Format code: `dart format .`
- Run tests: `flutter test`
- Android release: `flutter build apk --release` (requires `libMNN.so` per-ABI)

## Coding Style & Naming Conventions
- Dart: 2-space indent, prefer `const`, avoid `dynamic` where possible.
- Naming: files `snake_case.dart`; classes `UpperCamelCase`; members/functions `lowerCamelCase`.
- Lints: uses `flutter_lints` via `analysis_options.yaml`. Fix all analyzer warnings.
- Kotlin/Java: idiomatic Android style; C++: C++17, keep includes local, avoid global state.

## Testing Guidelines
- Framework: `flutter_test`.
- Location/pattern: place tests in `test/`, name as `feature_name_test.dart`.
- What to test: widget rendering of core flows, MethodChannel JSON serialization, and error states.
- Run locally: `flutter test`; keep tests deterministic and fast.

## Commit & Pull Request Guidelines
- Commits: use concise, present-tense messages. Recommended Conventional Commits (e.g., `feat: add Vulkan backend toggle`, `fix(android): handle missing libMNN.so`).
- PRs: include summary, rationale, screenshots for UI changes, test plan (`commands run`, `devices`), and linked issues.
- Checks: pass `flutter analyze`, `dart format .`, and `flutter test` before requesting review.

## Security & Configuration Tips
- Android JNI: ensure `libMNN.so` exists under `android/app/src/main/jniLibs/${ABI}/`; headers under `android/app/src/main/cpp/third_party/MNN/include`.
- MethodChannel: channel name `mnn_runner`; method `runModel` expects JSON with `modelPath`, `inputShape`, `backend`, `memoryMode`, `precisionMode`, `powerMode`, `threads`.
