# Oops developer commands. Tools are pinned in mise.toml; `just setup` installs them.

# List the commands
default:
    @just --list --unsorted

# Install the pinned tools and the commit hook
setup:
    mise install
    @if hooks=$(git config core.hooksPath); then echo "setup: git runs hooks from $hooks, not this repo; make its pre-commit run 'prek run'."; else mise exec -- prek install; fi

# Gate: hooks, build and tests for what changed since BASE (default: uncommitted changes)
[no-exit-message]
check base="":
    @script/check {{ base }}

# CI's gate: every hook on every file, the build, all unit tests and the packaging contracts
[no-exit-message]
ci:
    mise exec -- prek run --all-files --color never
    python3 -m unittest discover -s fixtures/eval -p 'test_*.py'
    CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift build --build-tests --disable-sandbox --disable-keychain
    CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test --skip-build --disable-sandbox
    python3 -m unittest discover -s script -p 'test_release*.py'

# OopsCore's unit tests in a Release build, as the app ships, under Address Sanitizer: the optimizer can
# free memory still in use where Debug passes, and only the sanitizer catches it every time
[no-exit-message]
test-release:
    CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test -c release -Xswiftc -enable-testing --sanitize=address --scratch-path .build/release-asan --disable-sandbox --disable-keychain --filter OopsCoreTests

# All unit tests (arguments go to swift test, e.g. --filter Placement)
[no-exit-message]
test *args:
    CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test --disable-sandbox --disable-keychain {{ args }}

# Offline scoring, adapter, review persistence and server contracts (no model calls)
eval-test:
    python3 -m unittest discover -s fixtures/eval -p 'test_*.py'

# Local eval dashboard and blind output review (cannot launch inference)
eval-dashboard *args:
    python3 fixtures/eval/manage.py serve {{ args }}

# End-to-end runs with a stub provider: a quick set, or --full for every web case (fronts the lab windows)
[no-exit-message]
e2e *args:
    fixtures/e2e/run.py {{ args }}

# Build, sign, install and launch the development app (--build-only to just build)
[no-exit-message]
run *args:
    script/build_and_run.sh {{ args }}

# Build or verify a local Apple silicon Release bundle; never installs or launches
[no-exit-message]
release *args:
    python3 script/release.py {{ args }}

# Release build 0.1.0 updates itself to 0.1.1 from a localhost feed, as a separate test copy (no input, no window)
[no-exit-message]
update-test *args:
    python3 script/test_update.py {{ args }}
