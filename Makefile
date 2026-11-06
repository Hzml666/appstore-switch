BIN  := sswitch
SRC  := Sources/AppStoreSwitch/main.swift
PREFIX ?= /usr/local/bin

.PHONY: build install uninstall clean

build:
	swiftc -O -o $(BIN) $(SRC)

install: build
	install -d $(PREFIX)
	install -m 755 $(BIN) $(PREFIX)/$(BIN)

uninstall:
	rm -f $(PREFIX)/$(BIN)

clean:
	rm -f $(BIN)
