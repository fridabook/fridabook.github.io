.PHONY: web html pdf epub all open serve clean deploy help

web: html open

html:
	@./build.sh html

pdf:
	@./build.sh pdf

epub:
	@./build.sh epub

all:
	@./build.sh all

open: html
	@echo "[INFO] 在浏览器中打开..."
	@if command -v open >/dev/null 2>&1; then \
		open build/index.html; \
	elif command -v xdg-open >/dev/null 2>&1; then \
		xdg-open build/index.html; \
	else \
		echo "[INFO] 请手动打开 build/index.html"; \
	fi

serve:
	@./build.sh web

clean:
	@./build.sh clean

deploy:
	@./deploy.sh

help:
	@echo ""
	@echo "  《解密 Frida》构建系统"
	@echo "  =========================="
	@echo ""
	@echo "  make          构建 HTML 并在浏览器中打开（默认）"
	@echo "  make pdf      构建 PDF（需要 pandoc + LaTeX 或 weasyprint）"
	@echo "  make epub     构建 EPUB（需要 pandoc）"
	@echo "  make all      构建所有格式（HTML + PDF + EPUB）"
	@echo "  make serve    启动本地 Web 预览服务器（localhost:8000）"
	@echo "  make clean    清理构建产物"
	@echo "  make deploy   构建并部署到 GitHub Pages + 创建 Release"
	@echo "  make help     显示此帮助"
	@echo ""
