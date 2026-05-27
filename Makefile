.PHONY: build install uninstall clean test

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
