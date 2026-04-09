#!/usr/bin/env bash
set -euo pipefail

BOOK_TITLE="解密 Frida：动态插桩框架源码之旅"
OUTPUT_DIR="build"
PORT=8000

CHAPTERS=(
  cover.md
  preface.md
  chapter01.md chapter02.md chapter03.md
  chapter04.md chapter05.md chapter06.md chapter07.md
  chapter08.md chapter09.md chapter10.md chapter11.md
  chapter12.md chapter13.md chapter14.md chapter15.md
  chapter16.md chapter17.md chapter18.md chapter19.md
  chapter20.md chapter21.md chapter22.md
  chapter23.md chapter24.md chapter25.md
  chapter26.md chapter27.md chapter28.md
  chapter29.md chapter30.md
  appendix-a.md appendix-b.md appendix-c.md
  about-author.md
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

check_dep() {
  if ! command -v "$1" &>/dev/null; then
    error "$1 未安装。$2"
    return 1
  fi
}

build_html() {
  mkdir -p "$OUTPUT_DIR"
  info "构建双栏 HTML..."
  python3 "$(dirname "$0")/scripts/build_html.py" "." "$OUTPUT_DIR"
  info "HTML 已生成 -> $OUTPUT_DIR/index.html"
}

serve_web() {
  build_html
  info "启动 Web 预览服务器 -> http://localhost:$PORT"
  info "按 Ctrl+C 停止"
  cd "$OUTPUT_DIR"
  python3 -m http.server "$PORT"
}

clean() {
  rm -rf "$OUTPUT_DIR"
  info "已清理 $OUTPUT_DIR/"
}

case "${1:-web}" in
  web)   serve_web ;;
  html)  build_html ;;
  clean) clean ;;
  *)
    echo "用法: $0 [web|html|clean]"
    exit 1
    ;;
esac
