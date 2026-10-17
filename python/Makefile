.PHONY: install
install:
	uv sync --all-groups

.PHONY: test
test:
	uv run pytest src/bearings tests

.PHONY: lint
lint:
	uv run ruff check src/bearings tests
	uv run ty check src/bearings

.PHONY: lintfix
lintfix:
	uv run ruff check src/bearings tests --fix

.PHONY: coverage
coverage:
	uv run pytest --cov-config=pyproject.toml --cov-report html --cov bearings src/bearings tests
