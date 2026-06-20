#!/usr/bin/env bash
# release-local-test.sh — Local dry-run of the v0.4.11 release acceptance test.
# Usage: release-local-test.sh
#
# Builds the par_runtime wheel locally, then runs scripts/release-acceptance-test.py
# inside 3 Docker containers (debian:12, ubuntu:22.04, ubuntu:24.04) to catch broken
# wheels BEFORE pushing the tag to GitHub. Requires Docker.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not available. Install Docker or use the CI workflow instead." >&2
    exit 1
fi

cleanup() {
    local code=$?
    # Best-effort cleanup of any orphan containers
    docker ps -a --filter "label=par-acceptance" -q | xargs -r docker rm -f >/dev/null 2>&1 || true
    exit "$code"
}
trap cleanup EXIT

echo "=== Building wheel locally ==="
make install-dev >/dev/null 2>&1 || {
    echo "ERROR: make install-dev failed" >&2
    exit 1
}

mkdir -p bindings/python/par_runtime/lib
cp -f _build/default/lib/ffi/par_capi.so bindings/python/par_runtime/lib/

# Build wheel using a fresh venv to get modern setuptools (PEP 621 support)
WHEEL_VENV="/tmp/par-wheel-venv"
rm -rf "$WHEEL_VENV"
python3 -m venv "$WHEEL_VENV"
"$WHEEL_VENV/bin/pip" install --upgrade pip setuptools wheel >/dev/null

rm -rf bindings/python/dist
(cd bindings/python && "$WHEEL_VENV/bin/pip" wheel . -w dist/ --no-deps >/dev/null)

WHEEL=$(ls bindings/python/dist/*.whl | head -1)
VERSION=$(sed -n 's/^(version "\([^"]*\)").*/\1/p' dune-project)
echo "Wheel: $WHEEL"
echo "Version: $VERSION"

# Stage the wheel in a known path that the container will mount
mkdir -p wheels
cp -f "$WHEEL" wheels/test-wheel.whl

CONTAINERS=(debian:12 ubuntu:22.04 ubuntu:24.04)
ALL_PASS=true

for c in "${CONTAINERS[@]}"; do
    echo ""
    echo "=== Testing on $c ==="
    if docker run --rm \
        --label par-acceptance \
        -v "$PWD/wheels:/wheels:ro" \
        -v "$PWD/scripts:/scripts:ro" \
        "$c" \
        bash -euo pipefail <<SCRIPT
            apt-get update -qq
            apt-get install -y -qq python3 python3-pip python3-venv >/dev/null 2>&1
            python3 -m venv /tmp/venv
            /tmp/venv/bin/pip install --upgrade pip >/dev/null 2>&1
            /tmp/venv/bin/pip install --no-cache-dir /wheels/test-wheel.whl
            python3 /scripts/release-acceptance-test.py /wheels/test-wheel.whl "$VERSION"
SCRIPT
    then
        echo "PASS: $c"
    else
        echo "FAIL: $c"
        ALL_PASS=false
    fi
done

echo ""
if $ALL_PASS; then
    echo "=== ALL PLATFORMS PASSED ==="
    echo "Safe to tag and push: git tag v\$VERSION && git push origin main --tags"
    exit 0
else
    echo "=== ONE OR MORE PLATFORMS FAILED ==="
    echo "DO NOT tag or push. Fix the wheel and re-run this script."
    exit 1
fi
