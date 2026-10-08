# OracleKit is a library of Module.Function.swift files, none over 500 lines (#83).
#   make include   the module map (Module → its .Function files) — fails on a file over MAX lines or off the naming
#   make lib       include, then build the library
#   make test      include, then the library's tests
#   make check     lib + test
# Apps and installs stay in scripts/build.sh (it takes minutes: run it in a herdr pane).

KIT := OracleKit
SRC := $(KIT)/Sources/OracleKit $(KIT)/Tests/OracleKitTests
MAX ?= 500

.PHONY: include lib test check

include:
	@python3 -I scripts/module_map.py --max $(MAX) $(SRC)

lib: include
	cd $(KIT) && swift build

test: include
	cd $(KIT) && swift test

check: lib test
