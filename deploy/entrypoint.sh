#!/bin/sh
# 容器 ENTRYPOINT。以 root 跑，做完三件启动前置之后 exec 给 supervisord
# （由它把两个服务分别降权到 65532 / 1000）。
#
#   1. 补建 /data/web 与 /data/backend 并纠正属主
#   2. 把合并前的旧数据布局幂等地迁进子目录
#   3. exec supervisord
#
# 为什么不做成 supervisord 的 program：迁移必须在两个服务碰到数据之前完成，
# program 之间没有"等前一个跑完"的顺序保证。
set -eu

DATA_ROOT="${EJ_DATA_ROOT:-/data}"
WEB_DIR="${EJ_DATA_DIR:-$DATA_ROOT/web}"
BACKEND_DIR="${DATA_DIR:-$DATA_ROOT/backend}"

WEB_UID=65532
WEB_GID=65532
BACKEND_UID=1000
BACKEND_GID=1000

log() { printf '[entrypoint] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 旧布局迁移
#
# 合并前两个镜像各自把 /data 当自己的根：
#   web-front → /data/admin.json, /data/config.json, /data/metrics.json
#   backend   → /data/leaderboard.json
# 现在它们分住 /data/web 与 /data/backend。宿主挂载点没变，所以升级到合并镜像的
# 第一次启动会在同一个 /data 里看到旧文件，需要搬一次。
#
# 判据刻意用"旧文件是否直接躺在 DATA_ROOT 下"，而不是某个 .migrated 标记：
# 标记文件会在用户手工恢复备份后骗过检查（备份里没有标记，但数据已经是新布局，
# 或者反过来）。按实际文件位置判断，重复执行天然安全。
# ---------------------------------------------------------------------------
migrate_one() {
  target_dir="$1"
  owner="$2"
  shift 2
  moved=0
  for name in "$@"; do
    src="$DATA_ROOT/$name"
    [ -e "$src" ] || continue
    # 目标已存在就不覆盖：宁可留下两份让人自己看，也不能悄悄盖掉现有数据。
    if [ -e "$target_dir/$name" ]; then
      log "跳过 $name：$target_dir/$name 已存在，旧文件留在 $src 未动"
      continue
    fi
    if [ "$moved" -eq 0 ]; then
      log "发现合并前的数据布局，迁移到 $target_dir/ ："
    fi
    log "  $name"
    mv "$src" "$target_dir/$name"
    moved=1
  done
  [ "$moved" -eq 1 ] && chown -R "$owner" "$target_dir"
  return 0
}

mkdir -p "$WEB_DIR" "$BACKEND_DIR"

# 文件名核实自源码，不是猜的：
#   web-front → src/admin_file.rs / config_store.rs / metrics.rs
#   backend   → server/modules/leaderboard.js
# 各带一个 .tmp 是因为两边都用"写临时文件再 rename"的原子落盘，崩在中途会留下它。
# **新增持久化文件时记得同步这两行**，否则升级时那个文件会被落在 DATA_ROOT 下，
# 服务看不到它 = 用户眼里的数据丢失。
migrate_one "$WEB_DIR" "$WEB_UID:$WEB_GID" \
  admin.json admin.json.tmp config.json config.json.tmp \
  metrics.json metrics.json.tmp
migrate_one "$BACKEND_DIR" "$BACKEND_UID:$BACKEND_GID" \
  leaderboard.json leaderboard.json.tmp

# 每次启动都纠正属主，不只在迁移时：named volume 首次使用会继承镜像里的属主，
# 但 bind mount 不会 —— 宿主上新建的目录是 root:root，服务降权后写不进去。
# 这一步让 bind mount 也零配置可用，用户不必先手工 chown。
chown "$WEB_UID:$WEB_GID" "$WEB_DIR"
chown "$BACKEND_UID:$BACKEND_GID" "$BACKEND_DIR"

log "web-front → $WEB_DIR (${WEB_UID}) · backend → $BACKEND_DIR (${BACKEND_UID})"
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
