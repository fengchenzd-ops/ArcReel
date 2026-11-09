#!/usr/bin/env bash
# ArcReel macOS 本地开发启动脚本（定制分支专用）。
#
# 用法：
#   ./fork/dev-mac.sh          同步依赖、迁移数据库，然后同时启动后端与前端
#   ./fork/dev-mac.sh setup    只同步依赖、准备 .env、迁移数据库，不启动
#
# 前置：uv、Node.js >= 24.12（自带 corepack），内置 Agent 另需 Claude Code。
# 访问 http://localhost:5173，Ctrl-C 同时停止前后端。
# 端口固定：后端 1241，前端 5173（frontend/vite.config.ts 按 1241 转发 /api 与 /mcp）。
#
# 兼容 macOS 自带的 bash 3.2。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '\033[1;34m[arcreel]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[arcreel]\033[0m %s\n' "$*" >&2; exit 1; }

check_prereqs() {
  command -v uv >/dev/null 2>&1 || die "未找到 uv，先安装：brew install uv"
  command -v node >/dev/null 2>&1 || die "未找到 Node.js，先安装 Node 24：brew install node@24"
  node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>24||(a===24&&b>=12)?0:1)' \
    || die "Node.js 版本 $(node -v) 过低，项目要求 >= 24.12"
  command -v corepack >/dev/null 2>&1 || die "未找到 corepack，Node 24 自带；确认 Node 安装完整"
  command -v claude >/dev/null 2>&1 || log "提示：未找到 claude 命令，内置 Agent 无法使用，其余功能不受影响"
}

# 后端禁止环境变量里带供应商密钥（lib/config/env_keys.py），内置 Agent 也不应继承
# 外层 Claude Code 会话的凭据与嵌套标记。在 Claude Code 会话里运行本脚本时需要清掉。
clean_agent_env() {
  local name
  for name in $(compgen -e); do
    case "$name" in
      ANTHROPIC_*|CLAUDE*) unset "$name" ;;
    esac
  done
}

setup() {
  log "同步后端依赖（uv sync --locked）"
  uv sync --locked

  log "同步前端依赖（pnpm install --frozen-lockfile）"
  (cd frontend && corepack pnpm install --frozen-lockfile)

  if [ ! -f .env ]; then
    cp .env.example .env
    log "已从 .env.example 生成 .env；登录密码在首次启动时自动生成并写回 AUTH_PASSWORD"
  fi

  log "迁移数据库（alembic upgrade head）"
  uv run alembic upgrade head
}

start() {
  local backend_pid frontend_pid

  # 任一进程退出或 Ctrl-C 时，停止整个进程组（含 uvicorn --reload 的子进程）
  trap 'trap - INT TERM EXIT; log "正在停止前后端"; kill 0 2>/dev/null || true' INT TERM EXIT

  log "启动后端 http://127.0.0.1:1241（--reload，改 server/ 与 lib/ 自动重启）"
  uv run uvicorn server.app:app --reload --reload-dir server --reload-dir lib \
    --host 127.0.0.1 --port 1241 &
  backend_pid=$!

  log "启动前端 http://localhost:5173"
  (cd frontend && exec corepack pnpm dev) &
  frontend_pid=$!

  # bash 3.2 没有 wait -n：轮询两个进程，任一退出即整体停止
  while kill -0 "$backend_pid" 2>/dev/null && kill -0 "$frontend_pid" 2>/dev/null; do
    sleep 1
  done
  log "有进程已退出，停止其余进程"
}

main() {
  case "${1:-}" in
    ""|setup) ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; return ;;
    *) die "未知参数：$1（可用：setup、--help）" ;;
  esac

  check_prereqs
  clean_agent_env
  setup
  if [ -z "${1:-}" ]; then
    start
  fi
}

main "$@"
