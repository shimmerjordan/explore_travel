/// 应用版本号在 Dart 侧的**唯一**副本。
///
/// 权威来源是 `CHANGELOG.md`（`scripts/version.sh` 读它，发版流水线用它给镜像、
/// web 产物、APK、IPA 打同一个号）。这里再存一份是因为 App 内要显示它，而读
/// `pubspec.yaml` 的运行时版本需要 `package_info_plus` —— 那是这个应用别处
/// 用不上的依赖，不值得为一行文字引进来。
///
/// **改 CHANGELOG 的版本标题时，把这里和 `pubspec.yaml` 一起改。**
/// `scripts/version.sh --check` 会在每次 push 的门禁里比对三处，对不上就红。
/// 同一套思路来自 xyz-studio-max：那边由 CMake 从 CHANGELOG 生成版本头文件，
/// 这里没有代码生成步骤，改用断言把漂移拦在 CI 上。
library;

const String kAppVersion = '0.2.0';
