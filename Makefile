.PHONY: check pin unpin update upgrade switch switch-tags test-actions

## The paths to search for yaml files.
PATHS := actions .github/workflows
## The yaml files from above paths up to 2 levels deep.
FILES := $(foreach path, $(PATHS), $(wildcard $(path)/*.yaml $(path)/*/*.yaml))

## help: Show Makefile targets. This is the default target.
help:
	@echo "Available Targets:\n"
	@egrep '^## .+?:' ${MAKEFILE_LIST} | column -t -s ':' | sed -e 's,^## ,,'

## check: Check for pinned uses values.
check:
	@ratchet check $(FILES)

## pin: Pin any unpinned uses values.
pin:
	@ratchet pin $(FILES)

## unpin: Unpin previously pinned items and revert back to previous value.
unpin:
	@ratchet unpin $(FILES)

## update: Update pinned uses values to the latest commit matching the unpinned reference.
update:
	@ratchet update $(FILES)

## upgrade: Upgrade pinned uses values to the latest available upstream reference commit.
upgrade:
	@ratchet upgrade $(FILES)

## Set container_arch to the desired architecture for testing.
set-container-arch:
container_arch := linux/amd64
ifeq ($(shell uname -s),Darwin)
ifeq ($(shell uname -m),arm64)
	container_arch := linux/arm64
endif
endif

## test: Run github action "tests" job locally.
test: set-container-arch
	act --container-architecture="$(container_arch)" \
	--job tests --rm
