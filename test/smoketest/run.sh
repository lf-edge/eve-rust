#!/bin/bash
# Regression test for the eve-rust toolchain image:
#   - cross-compile a tiny crate for all three supported musl targets using
#     $RUST_IMAGE as the toolchain
#   - assert each resulting ELF has the expected machine type
#   - execute each binary under qemu-user (via binfmt_misc) to prove it
#     actually runs, not just links
#
# Used both locally and in the eve-rust CI pipeline. For non-amd64 execution
# the caller is responsible for registering qemu handlers
# (docker/setup-qemu-action in CI, `docker run --privileged tonistiigi/binfmt
# --install all` locally).

set -euo pipefail

RUST_IMAGE="${RUST_IMAGE:-lfedge/eve-rust:latest}"
cd "$(dirname "$0")"

declare -A TARGETS=(
  [amd64]=x86_64-unknown-linux-musl
  [arm64]=aarch64-unknown-linux-musl
  [riscv64]=riscv64gc-unknown-linux-musl
)

declare -A EXPECTED_MACHINE=(
  [amd64]="Advanced Micro Devices X86-64"
  [arm64]="AArch64"
  [riscv64]="RISC-V"
)

# Build all three targets in one invocation of the rust container, reusing
# the target/ cache across them. We `docker run` directly (no buildx) so a
# just-loaded local image like `eve-rust-ci:pr` is visible without pushing
# to a registry.
echo "=== Cross-compiling smoketest for all 3 targets ==="
docker run --rm \
  -v "$(pwd):/app" \
  -w /app \
  "${RUST_IMAGE}" \
  sh -c '
    set -eu
    mkdir -p .cargo
    cp cargo-config.toml .cargo/config.toml
    for t in x86_64-unknown-linux-musl aarch64-unknown-linux-musl riscv64gc-unknown-linux-musl; do
      echo "--- compile: $t ---"
      CARGO_BUILD_TARGET=$t cargo build --release
    done
  '

fail=0
for arch in amd64 arm64 riscv64; do
  target="${TARGETS[$arch]}"
  expected_machine="${EXPECTED_MACHINE[$arch]}"
  binary="target/${target}/release/smoketest"

  echo
  echo "================ $target  ($arch) ================"

  if [ ! -f "$binary" ]; then
    echo "FAIL: $binary was not produced"
    fail=1
    continue
  fi

  # readelf is provided by binutils (preinstalled on ubuntu-latest); fall
  # back to running it inside the rust image if missing.
  if command -v readelf >/dev/null 2>&1; then
    elf_hdr=$(readelf -h "$binary")
  else
    elf_hdr=$(docker run --rm -v "$(pwd):/app" -w /app "${RUST_IMAGE}" llvm-readelf -h "$binary")
  fi
  echo "$elf_hdr" | grep -E "Class|Data|Machine|Type"

  actual_machine=$(echo "$elf_hdr" | awk -F: '/Machine:/ {sub(/^ +/, "", $2); print $2}')
  if [ "$actual_machine" != "$expected_machine" ]; then
    echo "FAIL: $arch has ELF Machine=\"${actual_machine}\", expected \"${expected_machine}\""
    fail=1
    continue
  fi

  # Execute the binary inside a matching-arch alpine container. Docker plus
  # binfmt_misc routes through qemu-user for non-host arches.
  if docker run --rm --platform="linux/${arch}" -v "$(pwd):/app" -w /app alpine:3.22 "./${binary}"; then
    echo "PASS: $arch"
  else
    rc=$?
    echo "FAIL: $arch (exit $rc)"
    fail=1
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "All three targets linked, are the correct arch, and ran under qemu-user."
else
  echo "One or more targets failed." >&2
  exit 1
fi
