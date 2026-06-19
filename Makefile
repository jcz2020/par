.PHONY: build install uninstall clean test sync-version docs-check \
        install-dev verify validate-version check-version-sync test-count \
        release-patch release-minor release-major release-beta

PREFIX ?= /usr/local
BUMP_TYPE ?= patch

# Extract version from dune-project: (version "X.Y.Z") → X.Y.Z
get-version = $(shell sed -n 's/^(version "\([^"]*\)")/\1/p' dune-project)

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
	$(eval VER := $(get-version))
	sed -i 's/^version = ".*"/version = "$(VER)"/' bindings/python/pyproject.toml
	sed -i 's/^__version__ = ".*"/__version__ = "$(VER)"/' bindings/python/par_runtime/__init__.py
	@echo "Synced version $(VER) to Python bindings"

docs-check: ## Run all documentation quality checks
	bash scripts/check_doc_identifiers.sh
	timeout 60 bash scripts/check_doc_links.sh
	@grep -rPl "[\x{4e00}-\x{9fff}]" README.md docs/ --include='*.md' | grep -v DOC-MAINTENANCE | grep -v zh-CN | while read f; do extra=$$(grep -P '[\x{4e00}-\x{9fff}]' "$$f" | grep -v '简体中文'); if [ -n "$$extra" ]; then echo "$$f"; fi; done; exit 0
	@echo "All doc checks passed."

# ─── Dev Install ──────────────────────────────────────────────────────

install-dev: build ## Build + install to both locations + sync + verify
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 _build/default/bin/main.exe $(DESTDIR)$(PREFIX)/bin/par
	-cp -f _build/default/bin/main.exe _opam/bin/par 2>/dev/null || true
	$(MAKE) --no-print-directory sync-version
	$(MAKE) --no-print-directory verify

verify: ## Verify installed binary matches source version
	@SRC="$(get-version)"; \
	BIN=$$(par --version 2>/dev/null | tr -d '\n'); \
	if [ "$$SRC" != "$$BIN" ]; then \
		echo "ERROR: source=$$SRC binary=$$BIN mismatch"; \
		echo "which par → $$(which par)"; exit 1; \
	fi; \
	echo "OK Dev install verified: $$SRC"

# ─── Version Validation ───────────────────────────────────────────────

SEMVER_RE := ^\(0\|\[1-9\][0-9]*\)\.\(0\|\[1-9\][0-9]*\)\.\(0\|\[1-9\][0-9]*\)

validate-version: ## Validate dune-project version is valid semver
	@VERSION="$(get-version)"; \
	if ! echo "$$VERSION" | grep -qE '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[a-zA-Z0-9._-]+)?$$'; then \
		echo "ERROR: Invalid semver: $$VERSION"; exit 1; \
	fi; \
	echo "OK $$VERSION is valid semver"

check-version-sync: validate-version ## Check all 3 version files agree
	@DUNE="$(get-version)"; \
	PY=$$(sed -n 's/^version = "\([^"]*\)"/\1/p' bindings/python/pyproject.toml); \
	INIT=$$(sed -n 's/^__version__ = "\([^"]*\)"/\1/p' bindings/python/par_runtime/__init__.py); \
	if [ "$$DUNE" != "$$PY" ] || [ "$$DUNE" != "$$INIT" ]; then \
		echo "ERROR: Version mismatch:"; \
		echo "  dune-project:   $$DUNE"; \
		echo "  pyproject.toml: $$PY"; \
		echo "  __init__.py:    $$INIT"; \
		echo "Run 'make sync-version' to fix"; exit 1; \
	fi; \
	echo "OK All files agree: $$DUNE"

test-count: ## Run tests and output total count
	@OUTPUT=$$(dune runtest -f 2>&1); \
	echo "$$OUTPUT"; \
	COUNT=$$(echo "$$OUTPUT" | grep -oP '\d+(?= tests? run\.)' | awk '{s+=$$1} END {print s}'); \
	if [ -z "$$COUNT" ]; then COUNT=unknown; fi; \
	echo ""; echo "TEST_COUNT=$$COUNT"

# ─── Release Automation (scripts/release-bump.sh enforces Pre-Bump Gate) ───

release-patch: validate-version ## Bump patch (X.Y.Z → X.Y.Z+1). Use FORCE=1 to skip gate.
	@bash scripts/release-bump.sh patch $(if $(FORCE),--force,)
	$(MAKE) --no-print-directory install-dev

release-minor: validate-version ## Bump minor (X.Y.Z → X.Y+1.0). Use FORCE=1 to skip gate.
	@bash scripts/release-bump.sh minor $(if $(FORCE),--force,)
	$(MAKE) --no-print-directory install-dev

release-major: validate-version ## Bump major (X.Y.Z → X+1.0.0). Use FORCE=1 to skip gate.
	@bash scripts/release-bump.sh major $(if $(FORCE),--force,)
	$(MAKE) --no-print-directory install-dev

release-beta: validate-version ## Set beta with today's date (BUMP_TYPE=patch|minor|major)
	@bash scripts/release-bump.sh beta $(BUMP_TYPE)
	$(MAKE) --no-print-directory install-dev
