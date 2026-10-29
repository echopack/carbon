#!/usr/bin/env bash
# carbongen end to end: build the generator, regenerate examples/blog,
# examples/movies and carbon's own test fixtures, check each is current, and run the tests on
# the generated code.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ECHOC="${ECHOC:-echoc}"

echo "== carbongen tests"
(cd "$root/cli" && "$ECHOC" test --silent)

echo "== build carbongen"
(cd "$root/cli" && "$ECHOC" build)
gen="$root/cli/ecobuild/carbongen"

echo "== generate examples/blog"
(cd "$root/examples/blog" && "$gen" --echoc "$ECHOC" && "$gen" check --echoc "$ECHOC")

echo "== generate examples/movies"
(cd "$root/examples/movies" && "$gen" --echoc "$ECHOC" && "$gen" check --echoc "$ECHOC")

echo "== generate tests/fixtures"
(cd "$root/tests/fixtures" && "$gen" --echoc "$ECHOC" && "$gen" check --echoc "$ECHOC")

echo "== examples/blog tests"
(cd "$root/examples/blog" && "$ECHOC" test --silent)

echo "== examples/movies tests"
(cd "$root/examples/movies" && "$ECHOC" test --silent)

echo "== carbon tests"
(cd "$root" && "$ECHOC" test --silent)

echo "all green"
