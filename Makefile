SHELL = /bin/bash
PROJECT_NAME=$(shell basename "$(shell pwd)")

# See https://kodfabrik.com/journal/a-good-makefile-for-go#help
help: Makefile
	@echo
	@echo " Choose a command run in "$(PROJECT_NAME)":"
	@echo
	@sed -n 's/^##//p' $< | column -t -s ':' |  sed -e 's/^/ /'
	@echo

VENV := .venv
PRE_COMMIT := $(VENV)/bin/pre-commit

.PHONY: help pre-commit-install pre-commit
all: help

# A repo-local venv holding pre-commit, created on demand and gitignored. No
# pyproject.toml: this template seeds Go, Terraform, and docs repos too, and none
# of them should carry a Python manifest to install one dev tool.
#
# Deliberately not `uv tool install`: that mutates the developer's global
# environment, and this repo has no business doing that.
#
# Deliberately not `uvx` either: `pre-commit install` bakes an absolute
# interpreter path into .git/hooks/pre-commit, and uvx environments live in uv's
# cache, which uv documents as disposable and `uv cache prune` deletes. The hook
# would then fail on every commit until someone re-ran this target.
#
# A local .venv is neither global nor prunable. If this repo grows real Python
# code, add pre-commit to a `dev` dependency group in its pyproject.toml and
# switch this target to `uv sync --only-group dev`.
$(PRE_COMMIT):
	@command -v uv >/dev/null || { \
	  echo "ERROR: uv is not installed. Python tooling here runs through uv."; \
	  echo ""; \
	  echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"; \
	  echo ""; \
	  exit 1; }
	uv venv $(VENV)
	uv pip install --python $(VENV) pre-commit

## pre-commit-install: Installs the git pre-commit hooks
pre-commit-install: $(PRE_COMMIT)
	$(PRE_COMMIT) install

## pre-commit: Runs all pre-commit hooks against every file
pre-commit: $(PRE_COMMIT)
	$(PRE_COMMIT) run --all-files
