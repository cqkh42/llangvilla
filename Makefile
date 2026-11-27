# The one place the repo's checks are spelled out: CI (.github/workflows/lint.yml)
# and the docs run these targets. What each one checks: README.md, Development.
#
# The linters are pinned in .github/lint/requirements.txt:
#   pip install -r .github/lint/requirements.txt
# Nix comes from your system. SHELLCHECK=/path/to/shellcheck picks a ShellCheck.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
SHELLCHECK ?= shellcheck
# path: (not a git reference), so new, untracked files are part of the flake.
FLAKE := path:$(CURDIR)/config/home

.PHONY: lint lint-shell lint-env lint-yaml lint-ansible lint-nix lint-docs fmt-nix vm vm-config

lint: lint-shell lint-env lint-yaml lint-ansible lint-nix lint-docs

lint-shell:
	$(SHELLCHECK) installer/*.sh config/*.sh vm/*.sh vm/checks/*.sh .github/scripts/*.sh config/ansible/roles/*/files/*.sh
	@# The first-boot script install.sh writes into the new system, from its FIRSTBOOT
	@# heredoc, with stand-in values for the variables install.sh fills in.
	{ printf '#!/bin/bash\nset -euo pipefail\nurl=u branch=b entry=e dir=/opt/llangvilla\n'; \
	  sed -n "/cat <<'FIRSTBOOT'$$/,/^FIRSTBOOT$$/p" installer/install.sh | sed '1d;$$d'; } \
	  | $(SHELLCHECK) -
	@echo "ShellCheck: the scripts and the first-boot script are clean."

lint-env:
	tmp=$$(mktemp) && trap 'rm -f "$$tmp"' EXIT; \
	hash=$$(openssl passwd -6 lint-test); \
	sed -e 's|__WIFI_SSID__|Lint|' -e 's|__WIFI_PASSWORD__|lint-password|' \
	    -e "s|__PASSWORD_HASH__|$$hash|" installer/autoinstall.env.example > "$$tmp"; \
	bash -n installer/autoinstall.env.example; \
	bash installer/install.sh --check "$$tmp"; \
	if bash installer/install.sh --check installer/autoinstall.env.example >/dev/null 2>&1; then \
	  echo "The raw template passed --check, but its placeholders should be rejected." >&2; exit 1; \
	fi; \
	echo "The raw template is rejected, as it should be."

lint-yaml:
	yamllint .

lint-ansible:
	@# From the repo root, so .ansible-lint picks the files. Deprecation warnings off for
	@# ansible-lint only: it loads every callback plugin in ansible-core, and two of those
	@# are deprecated. The syntax check below keeps them, for the playbook's own.
	ANSIBLE_DEPRECATION_WARNINGS=False ansible-lint
	cd config/ansible && ANSIBLE_CONFIG=ansible.cfg ansible-playbook --syntax-check site.yml

lint-nix:
	nix flake check '$(FLAKE)'
	find config/home -name '*.nix' -print0 | xargs -0 nix run '$(FLAKE)#formatter.x86_64-linux' -- --check

lint-docs:
	.github/scripts/check-links.py

fmt-nix:
	find config/home -name '*.nix' -print0 | xargs -0 nix run '$(FLAKE)#formatter.x86_64-linux' --

vm:
	vm/test-vm.sh all

vm-config:
	vm/test-vm.sh config
