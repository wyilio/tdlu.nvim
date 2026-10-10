NVIM ?= nvim
LUA ?= luajit
.PHONY: test test-model test-integration

test: test-model test-integration

test-model:
	$(LUA) tests/model.lua

test-integration:
	NVIM_LOG_FILE=/tmp/tdlu-nvim-test.log $(NVIM) --headless -u NONE -i NONE -l tests/integration.lua
