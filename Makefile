PREFIX ?= /usr/local
SHELLCHECK ?= shellcheck

.PHONY: lint test e2e check install uninstall

lint:
	$(SHELLCHECK) bin/revenant

test:
	bash test/unit_test.sh

e2e:
	bash test/e2e_local.sh

check: lint test e2e

install:
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 0755 bin/revenant "$(DESTDIR)$(PREFIX)/bin/revenant"

uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/revenant"
