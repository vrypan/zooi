ZIG ?= zig

.DEFAULT_GOAL := build
.PHONY: build test fmt fmt-check check clean

build:
	$(ZIG) build

test:
	$(ZIG) build test

fmt:
	$(ZIG) fmt .

fmt-check:
	$(ZIG) fmt --check .

# The gates every change has to pass.
check: fmt-check test

clean:
	rm -rf zig-out .zig-cache
