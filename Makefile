.PHONY: deps deps-mini deps-treesitter deps-grammars treesitter-build treesitter-install fmt lint stylua stylua-check selene test

CC ?= cc
NVIM ?= nvim
GIT ?= git
MINI_PATH ?= deps/mini.nvim
TREESITTER_PATH ?= deps/nvim-treesitter
TREESITTER_INSTALL_DIR ?= deps/treesitter
TS_GRAMMAR_TOML ?= deps/tree-sitter-toml

deps: deps-mini deps-treesitter treesitter-install

deps-mini:
	@if [ ! -d "$(MINI_PATH)" ]; then \
		mkdir -p "$$(dirname "$(MINI_PATH)")"; \
		$(GIT) clone --depth 1 https://github.com/echasnovski/mini.nvim "$(MINI_PATH)"; \
	fi

deps-treesitter:
	@if [ ! -d "$(TREESITTER_PATH)" ]; then \
		mkdir -p "$$(dirname "$(TREESITTER_PATH)")"; \
		$(GIT) clone --depth 1 https://github.com/nvim-treesitter/nvim-treesitter "$(TREESITTER_PATH)"; \
	fi

deps-grammars:
	@if [ ! -d "$(TS_GRAMMAR_TOML)" ]; then \
		mkdir -p "$$(dirname "$(TS_GRAMMAR_TOML)")"; \
		$(GIT) clone --depth 1 https://github.com/tree-sitter-grammars/tree-sitter-toml "$(TS_GRAMMAR_TOML)"; \
	fi

treesitter-build: deps-grammars
	@mkdir -p "$(TREESITTER_INSTALL_DIR)/parser" "$(TREESITTER_INSTALL_DIR)/queries"
	@TOML_SCANNER=""; \
		if [ -f "$(TS_GRAMMAR_TOML)/src/scanner.c" ]; then TOML_SCANNER="$(TS_GRAMMAR_TOML)/src/scanner.c"; fi; \
		$(CC) -fPIC -shared -O2 -o "$(TREESITTER_INSTALL_DIR)/parser/toml.so" \
			"$(TS_GRAMMAR_TOML)/src/parser.c" $$TOML_SCANNER -I "$(TS_GRAMMAR_TOML)/src"

treesitter-install: treesitter-build

fmt: stylua

lint: stylua-check selene

stylua:
	stylua .

stylua-check:
	stylua --check .

selene:
	selene ./lua ./plugin ./tests

test: deps
	MINI_PATH="$(MINI_PATH)" TREESITTER_INSTALL_DIR="$(TREESITTER_INSTALL_DIR)" TREESITTER_PATH="$(TREESITTER_PATH)" \
		$(NVIM) --headless -u tests/minimal_init.lua -c "lua require('tests.run').run()" -c "qa"
