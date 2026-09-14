PYTHON ?= python3

.PHONY: test test-L00

test: test-L00

test-L00:
	PYTHON=$(PYTHON) ./tests/run-L00.sh
