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

# 复制图片资源到输出目录
copy_assets() {
  for img in wx.png cover.jpg; do
    if [[ -f "$img" ]]; then
      cp "$img" "$OUTPUT_DIR/"
    fi
  done
}

# 合并所有章节为一个 Markdown 文件
merge_chapters() {
  local output="$1"
  mkdir -p "$OUTPUT_DIR"
  > "$output"
  for ch in "${CHAPTERS[@]}"; do
    if [[ -f "$ch" ]]; then
      cat "$ch" >> "$output"
      echo -e "\n\n---\n\n" >> "$output"
    else
      warn "文件不存在，跳过: $ch"
    fi
  done

  # 在最后追加微信公众号二维码
  if [[ -f "wx.png" ]]; then
    cat >> "$output" <<'WXEOF'

---

<div align="center">

**关注微信公众号，探索更多有趣的技术以及 AI 前沿技术**

![微信公众号](wx.png)

</div>
WXEOF
  fi

  copy_assets
  info "已合并 ${#CHAPTERS[@]} 个文件 → $output"
}

build_html() {
  mkdir -p "$OUTPUT_DIR"
  info "构建双栏 HTML..."
  python3 "$(dirname "$0")/scripts/build_html.py" "." "$OUTPUT_DIR"
  info "HTML 已生成 → $OUTPUT_DIR/index.html"
}

# 构建 PDF
build_pdf() {
  check_dep pandoc "请安装: brew install pandoc" || return 1

  local merged="$OUTPUT_DIR/book.md"
  local pdf="$OUTPUT_DIR/解密Frida.pdf"
  merge_chapters "$merged"

  # 检查是否有中文 PDF 引擎
  local pdf_engine=""
  if command -v xelatex &>/dev/null; then
    pdf_engine="--pdf-engine=xelatex"
  elif command -v lualatex &>/dev/null; then
    pdf_engine="--pdf-engine=lualatex"
  elif command -v weasyprint &>/dev/null; then
    info "使用 weasyprint 生成 PDF..."
    local html_single="$OUTPUT_DIR/book_single.html"

    local merged_no_cover="$OUTPUT_DIR/book_no_cover.md"
    > "$merged_no_cover"
    for ch in "${CHAPTERS[@]}"; do
      [[ "$ch" == "cover.md" ]] && continue
      if [[ -f "$ch" ]]; then
        cat "$ch" >> "$merged_no_cover"
        echo -e "\n\n---\n\n" >> "$merged_no_cover"
      fi
    done

    pandoc "$merged_no_cover" \
      --from markdown \
      --to html5 \
      --standalone \
      --toc \
      --toc-depth=2 \
      --metadata title="$BOOK_TITLE" \
      --highlight-style=tango \
      --resource-path=".:$OUTPUT_DIR" \
      -V lang=zh-CN \
      -o "$html_single"

    # 注入封面页和中文字体样式
    python3 -c "
import sys
html = open(sys.argv[1], encoding='utf-8').read()
css = '<style>body, p, h1, h2, h3, h4, h5, h6, li, td, th, span, div { font-family: \"Hiragino Sans GB\", \"Heiti SC\", \"STSong\", \"Arial Unicode MS\", sans-serif; } code, pre { font-family: Menlo, \"Hiragino Sans GB\", monospace; }</style>'
html = html.replace('</head>', css + '</head>', 1)
cover = '''<div style=\"page-break-after:always;text-align:center;padding-top:20px;\">
<img src=\"cover.jpg\" style=\"width:90%;\" />
</div>
<div style=\"text-align:center;page-break-after:always;padding-top:120px;\">
<h1 style=\"font-size:2.2em;margin-bottom:0.3em;\">$BOOK_TITLE</h1>
<p style=\"font-size:1.2em;color:#666;margin:0.5em 0;\">作者：everettjf</p>
<p style=\"font-size:1em;color:#888;margin:0.5em 0;\">使用 Claude Code 分析源码</p>
<p style=\"font-size:0.9em;color:#999;margin:1.5em 0;\">深度解析 Frida 动态插桩框架的架构与设计思路</p>
<p style=\"font-size:0.85em;color:#999;\">30 章正文 | 3 个附录 | 150+ 代码示例 | 40+ 架构图</p>
<p style=\"font-size:0.85em;color:#aaa;margin-top:1em;\">Frida 官网: https://frida.re | GitHub: https://github.com/frida/frida</p>
<p style=\"font-size:0.8em;color:#cc8800;margin-top:2em;border:1px solid #cc8800;display:inline-block;padding:6px 16px;border-radius:6px;\">本书由 Claude Code 分析 Frida 源码生成，人工校准仍在进行中</p>
</div>'''
html = html.replace('<body>', '<body>' + cover, 1)
open(sys.argv[1], 'w', encoding='utf-8').write(html)
" "$html_single"

    weasyprint "$html_single" "$pdf"
    info "PDF 已生成 → $pdf"
    return 0
  else
    warn "未找到 xelatex/lualatex/weasyprint。尝试基础 pandoc..."
    pdf_engine=""
  fi

  pandoc "$merged" \
    --from markdown \
    --to pdf \
    $pdf_engine \
    --toc \
    --toc-depth=2 \
    --metadata title="$BOOK_TITLE" \
    --highlight-style=tango \
    --resource-path=".:$OUTPUT_DIR" \
    -V geometry:margin=2.5cm \
    -V fontsize=11pt \
    -V documentclass=report \
    -V CJKmainfont="PingFang SC" \
    -V mainfont="PingFang SC" \
    -V monofont="Menlo" \
    -V linkcolor=cyan \
    -o "$pdf" 2>/dev/null || {
      warn "LaTeX PDF 生成失败，尝试 HTML→PDF 备选方案..."
      if command -v weasyprint &>/dev/null; then
        local html_single="$OUTPUT_DIR/book_single.html"
        pandoc "$merged" \
          --from markdown \
          --to html5 \
          --standalone \
          --toc \
          --toc-depth=2 \
          --metadata title="$BOOK_TITLE" \
          --highlight-style=tango \
          --resource-path=".:$OUTPUT_DIR" \
          -V lang=zh-CN \
          -o "$html_single"
        python3 -c "
import sys
html = open(sys.argv[1], encoding='utf-8').read()
css = '<style>body, p, h1, h2, h3, h4, h5, h6, li, td, th, span, div { font-family: \"Hiragino Sans GB\", \"Heiti SC\", \"STSong\", \"Arial Unicode MS\", sans-serif; } code, pre { font-family: Menlo, \"Hiragino Sans GB\", monospace; }</style>'
html = html.replace('</head>', css + '</head>', 1)
cover = '''<div style=\"page-break-after:always;text-align:center;padding-top:20px;\">
<img src=\"cover.jpg\" style=\"width:90%;\" />
</div>
<div style=\"text-align:center;page-break-after:always;padding-top:120px;\">
<h1 style=\"font-size:2.2em;margin-bottom:0.3em;\">$BOOK_TITLE</h1>
<p style=\"font-size:1.2em;color:#666;margin:0.5em 0;\">作者：everettjf</p>
<p style=\"font-size:1em;color:#888;margin:0.5em 0;\">使用 Claude Code 分析源码</p>
<p style=\"font-size:0.9em;color:#999;margin:1.5em 0;\">深度解析 Frida 动态插桩框架的架构与设计思路</p>
<p style=\"font-size:0.85em;color:#999;\">30 章正文 | 3 个附录 | 150+ 代码示例 | 40+ 架构图</p>
<p style=\"font-size:0.85em;color:#aaa;margin-top:1em;\">Frida 官网: https://frida.re | GitHub: https://github.com/frida/frida</p>
<p style=\"font-size:0.8em;color:#cc8800;margin-top:2em;border:1px solid #cc8800;display:inline-block;padding:6px 16px;border-radius:6px;\">本书由 Claude Code 分析 Frida 源码生成，人工校准仍在进行中</p>
</div>'''
html = html.replace('<body>', '<body>' + cover, 1)
open(sys.argv[1], 'w', encoding='utf-8').write(html)
" "$html_single"
        weasyprint "$html_single" "$pdf"
      else
        error "PDF 生成失败。请安装以下任一工具："
        error "  brew install --cask mactex-no-gui  # LaTeX (推荐)"
        error "  pip3 install weasyprint             # weasyprint"
        return 1
      fi
    }

  info "PDF 已生成 → $pdf"
}

# 构建 EPUB
build_epub() {
  check_dep pandoc "请安装: brew install pandoc" || return 1

  local merged="$OUTPUT_DIR/book.md"
  local epub="$OUTPUT_DIR/解密Frida.epub"
  merge_chapters "$merged"

  local cover_opt=""
  if [[ -f "cover.jpg" ]]; then
    cover_opt="--epub-cover-image=cover.jpg"
  fi

  pandoc "$merged" \
    --from markdown \
    --to epub3 \
    --toc \
    --toc-depth=2 \
    --metadata title="$BOOK_TITLE" \
    --metadata language="zh-CN" \
    --highlight-style=tango \
    --resource-path=".:$OUTPUT_DIR" \
    $cover_opt \
    -o "$epub"

  info "EPUB 已生成 → $epub"
}

serve_web() {
  build_html
  info "启动 Web 预览服务器 → http://localhost:$PORT"
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
  pdf)   build_pdf ;;
  epub)  build_epub ;;
  clean) clean ;;
  all)
    build_html
    build_pdf
    build_epub
    info "全部构建完成！输出目录: $OUTPUT_DIR/"
    ;;
  *)
    echo "用法: $0 [web|html|pdf|epub|clean|all]"
    echo ""
    echo "  web    构建 HTML 并启动本地预览服务器（默认）"
    echo "  html   仅构建 HTML"
    echo "  pdf    构建 PDF（需要 pandoc + LaTeX 或 weasyprint）"
    echo "  epub   构建 EPUB（需要 pandoc）"
    echo "  clean  清理构建产物"
    echo "  all    构建所有格式"
    exit 1
    ;;
esac
