# The one place the repo's checks are spelled out: CI (.github/workflows/lint.yml)
# and the docs run these targets. `make lint` runs everything that needs no VM.
#
#   make lint            all the checks below
#   make lint-shell      ShellCheck on every script
#   make lint-env        the autoinstall.env template passes install.sh --check once
#                        filled in, and is rejected as it is (placeholders left)
#   make lint-yaml       yamllint
#   make lint-ansible    ansible-lint and a playbook syntax check
#   make lint-nix        nix flake check, nixfmt and a build of the home configuration
#   make lint-docs       relative links and #section anchors in the Markdown files
#   make fmt-nix         format the Nix files (what lint-nix checks)
#   make vm              vm/test-vm.sh all: install, check and configure a VM
#   make vm-config       vm/test-vm.sh config: re-apply config/ to the existing VM
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
	$(SHELLCHECK) installer/*.sh config/*.sh vm/*.sh .github/scripts/*.sh

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
	ansible-lint config/ansible
	cd config/ansible && ANSIBLE_CONFIG=ansible.cfg ansible-playbook --syntax-check site.yml

lint-nix:
	nix flake check '$(FLAKE)'
	find config/home -name '*.nix' -print0 | xargs -0 nix run '$(FLAKE)#formatter.x86_64-linux' -- --check
	nix build '$(FLAKE)#homeConfigurations.jack.activationPackage' --no-link

lint-docs:
	.github/scripts/check-links.py

fmt-nix:
	find config/home -name '*.nix' -print0 | xargs -0 nix run '$(FLAKE)#formatter.x86_64-linux' --

vm:
	vm/test-vm.sh all

vm-config:
	vm/test-vm.sh config
