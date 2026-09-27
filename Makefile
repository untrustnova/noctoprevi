PREFIX  ?= $(HOME)/.local
BINDIR  := $(PREFIX)/bin
LIBDIR  := $(PREFIX)/lib/noctoprevi
SHAREDIR := $(PREFIX)/share/noctoprevi
DOCDIR  := $(PREFIX)/share/doc/noctoprevi
CFGDIR  := $(HOME)/.config/noctoprevi

LIBS := core log config media ipc runtime cmd setup aerials

.PHONY: help install uninstall test test-gpu list-tests lint check \
        doctor bench clean dist

help:
	@echo "noctoprevi - target yang tersedia:"
	@echo ""
	@echo "  make install      pasang ke $(PREFIX)"
	@echo "  make uninstall    cabot dari $(PREFIX)"
	@echo "  make test         jalankan test suite (headless)"
	@echo "  make test-gpu     jalankan test suite dengan output video sungguhan"
	@echo "  make list-tests   daftar nama test"
	@echo "  make lint         shellcheck + syntax check"
	@echo "  make check        lint + test"
	@echo "  make doctor       jalankan doctor lewat repo ini"
	@echo "  make bench        ukur latensi"
	@echo "  make dist         paket sources ke dist/"
	@echo ""
	@echo "  make install PREFIX=/usr  (butuh hak akses ke /usr)"

install:
	@mkdir -p "$(BINDIR)" "$(LIBDIR)" "$(SHAREDIR)" "$(DOCDIR)"
	@install -m 755 bin/noctoprevi "$(BINDIR)/noctoprevi"
	@for l in $(LIBS); do install -m 644 "lib/$$l.sh" "$(LIBDIR)/$$l.sh"; done
	@install -m 644 config/config.conf "$(SHAREDIR)/config.conf"
	@install -m 644 config/hypridle.conf.example "$(DOCDIR)/hypridle.conf.example"
	@install -m 644 config/swayidle.config.example "$(DOCDIR)/swayidle.config.example"
	@install -m 644 README.md "$(DOCDIR)/README.md"
	@install -m 644 LICENSE "$(DOCDIR)/LICENSE"
	@mkdir -p "$(CFGDIR)/videos"
	@[ -f "$(CFGDIR)/config.conf" ] || install -m 644 "$(SHAREDIR)/config.conf" "$(CFGDIR)/config.conf"
	@echo "terpasang: $(BINDIR)/noctoprevi"
	@echo "config   : $(CFGDIR)/config.conf"

uninstall:
	@rm -f "$(BINDIR)/noctoprevi"
	@rm -rf "$(LIBDIR)" "$(SHAREDIR)" "$(DOCDIR)"
	@echo "dilepas dari $(PREFIX) (config dan video tetap)"

test:
	@./tests/run-tests.sh

test-gpu:
	@./tests/run-tests.sh --gpu

list-tests:
	@./tests/run-tests.sh --list

lint:
	@bash -n bin/noctoprevi
	@for f in lib/*.sh tests/*.sh scripts/*.sh; do bash -n "$$f" || exit 1; done
	@command -v shellcheck >/dev/null || { echo "shellcheck tidak ada, dilewati"; exit 0; }
	@shellcheck -x -S warning -e SC2034 bin/noctoprevi lib/*.sh
	@shellcheck -S warning -e SC2034,SC2317 tests/*.sh scripts/*.sh
	@echo "lint bersih"

check: lint test

doctor:
	@./bin/noctoprevi doctor

bench:
	@./bin/noctoprevi bench --runs 10

clean:
	@rm -rf dist
	@rm -f /tmp/noctoprevi-$$(id -u).*
	@echo "bersih"

dist:
	@mkdir -p dist
	@tar czf dist/noctoprevi-1.0.0.tar.gz \
		--transform 's,^,noctoprevi-1.0.0/,' \
		bin lib config scripts packaging tests README.md LICENSE PRD.md
	@echo "dist/noctoprevi-1.0.0.tar.gz"
