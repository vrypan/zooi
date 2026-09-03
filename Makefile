ZIG ?= zig

.DEFAULT_GOAL := build
.PHONY: build test test-unit verify version-check fmt fmt-check check clean

build:
	$(ZIG) build

# Everything, PTY suite included. The PTY tests drive the installed example
# through a real terminal, so they need a system that can allocate one; they
# skip rather than fail where it cannot.
test:
	$(ZIG) build test-all

test-unit:
	$(ZIG) build test

# Standalone runtime check, for pasting back from an unusual terminal.
verify:
	$(ZIG) build verify && ./zig-out/bin/zooi-verify

# Used by the release workflow after deriving the tag from build.zig.zon.
# It remains available for local checks: make version-check TAG=v0.2.1
version-check:
	@tools/check-version.sh $(TAG)

fmt:
	$(ZIG) fmt .

fmt-check:
	$(ZIG) fmt --check .

# The gates every change has to pass.
check: fmt-check test

clean:
	rm -rf zig-out .zig-cache
