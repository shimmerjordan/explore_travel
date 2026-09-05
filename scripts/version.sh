#!/usr/bin/env bash
# CHANGELOG.md 是版本号的**唯一来源**。同一套做法来自 xyz-studio-max
# （那边是 conanfile.py 的 get_version_changelog() + CMake 从 CHANGELOG 生成
# 版本头文件），这里做成一个脚本，好让本机与 CI 用的是同一份解析逻辑。
#
#   scripts/version.sh          → 打印版本号，例如 0.2.0
#   scripts/version.sh --check  → 再校验 pubspec.yaml 的 version 与它一致
#
# 约定（标题里的日期后缀随便写，解析只认那个语义化版本号）：
#
#   ## [0.2.0] — TBD          开发中，还没发
#   ## [0.2.0] — 2026-09-06   已发布
#
# 为什么取「最大」而不是「最上面那个」：本仓库 CHANGELOG 的历史段落是按日期
# 倒序排的开发日志，其中大部分还是 `[Unreleased]`。真正决定版本的是最高的那个
# 号，与标题的先后无关（xyz-studio-max 同样取 max，见 data[-1]）。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep -E '^## ' CHANGELOG.md \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
  | sort -V \
  | tail -1)

if [ -z "$VERSION" ]; then
  echo "::error::CHANGELOG.md 里没有任何形如 '## [1.2.3] — …' 的版本标题。" >&2
  echo "发版前先把最上面那段 '## [Unreleased] — …' 改成 '## [x.y.z] — TBD'。" >&2
  exit 1
fi

if [ "${1:-}" = --check ]; then
  # 版本号在仓库里一共有三处副本，全部与 CHANGELOG 比对：
  #
  #   ① pubspec.yaml 的 `version: x.y.z+build`
  #      CI 发版时用 --build-name 覆盖它，所以严格说它只是本机构建的兜底值 ——
  #      但对不上就意味着「本机编的包」和「CI 编的包」自称版本不同。
  #   ② lib/core/app_version.dart 的 kAppVersion
  #      App 内显示的那个（关于页 / 备份 manifest 的 appVersion）。读 pubspec
  #      需要 package_info_plus，那是这个应用别处用不上的依赖，所以存了副本。
  #
  # 三处任意两处不一致就红。这种「一个值抄了几份」的东西，只有断言拦得住。
  FAIL=0

  PUBSPEC=$(grep -E '^version:' pubspec.yaml | head -1 | sed 's/^version:[[:space:]]*//' | tr -d '\r')
  PUBSPEC_SEMVER=${PUBSPEC%%+*}
  if [ "$PUBSPEC_SEMVER" != "$VERSION" ]; then
    echo "::error file=pubspec.yaml::版本漂移：CHANGELOG.md 是 $VERSION，pubspec.yaml 是 $PUBSPEC_SEMVER。改成 ${VERSION}+<build>。" >&2
    FAIL=1
  fi

  DART_FILE=lib/core/app_version.dart
  DART_VERSION=$(grep -oE "kAppVersion = '[^']+'" "$DART_FILE" | grep -oE "'[^']+'" | tr -d "'")
  if [ "$DART_VERSION" != "$VERSION" ]; then
    echo "::error file=$DART_FILE::版本漂移：CHANGELOG.md 是 $VERSION，kAppVersion 是 ${DART_VERSION:-<没解析出来>}。" >&2
    FAIL=1
  fi

  [ "$FAIL" -eq 0 ] || exit 1
  echo "版本一致：$VERSION（pubspec: $PUBSPEC · kAppVersion: $DART_VERSION）"
  exit 0
fi

echo "$VERSION"
