.PHONY: build install uninstall clean test sync-version docs-check

PREFIX ?= /usr/local

build:
	dune build

test:
	dune runtest

install: build
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 _build/default/bin/main.exe $(DESTDIR)$(PREFIX)/bin/par

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/par

clean:
	dune clean

sync-version: ## Sync version from dune-project to Python bindings
	$(eval VER := $(shell grep -oP '(?<=version ")[^"]+' dune-project))
	sed -i 's/^version = ".*"/version = "$(VER)"/' bindings/python/pyproject.toml
	sed -i 's/^__version__ = ".*"/__version__ = "$(VER)"/' bindings/python/par_runtime/__init__.py
	@echo "Synced version $(VER) to Python bindings"

docs-check: ## Run all documentation quality checks
	bash scripts/check_doc_identifiers.sh
	bash scripts/check_doc_links.sh
	@grep -rPl "[\x{4e00}-\x{9fff}]" README.md docs/ --include='*.md' | grep -v DOC-MAINTENANCE | grep -v zh-CN | while read f; do extra=$$(grep -P '[\x{4e00}-\x{9fff}]' "$$f" | grep -v '简体中文'); if [ -n "$$extra" ]; then echo "$$f"; fi; done; exit 0
	@echo "All doc checks passed."
