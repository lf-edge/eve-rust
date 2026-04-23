ARG RUST_VERSION=1.93.1
FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION}-alpine3.22 AS tools-host
ARG BUILDPLATFORM
ARG TARGETARCH

ENV TARGETS="x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu riscv64gc-unknown-linux-gnu"
RUN rustup target add ${TARGETS}
RUN apk add musl-dev linux-headers make clang mold

FROM tools-host AS target-amd64
ENV CARGO_BUILD_TARGET="x86_64-unknown-linux-musl"

FROM tools-host AS target-arm64
ENV CARGO_BUILD_TARGET="aarch64-unknown-linux-musl"

FROM tools-host AS target-riscv64
ENV CARGO_BUILD_TARGET="riscv64gc-unknown-linux-gnu"

FROM target-$TARGETARCH AS tools
RUN echo "Cargo target: $CARGO_BUILD_TARGET"

ADD config.toml /usr/local/cargo/
# CARGO_BUILD_TARGET is respected by cargo install and other cargo commands
RUN cargo install --root /cargo-cross cargo-chef@0.1.71 cargo-sbom@0.9.1


# ---------------------------------------------------------------------------
# Extract the riscv64 linker inputs that rustup's tier-1 musl targets
# normally ship in <sysroot>/lib/rustlib/<target>/lib/self-contained/:
#   - musl startup objects: Scrt1.o, crt1.o, crti.o, crtn.o, rcrt1.o
#   - libc.a  (from musl-dev)
#   - libunwind.a  (from llvm-libunwind-static)
#   - libgcc runtime startup: crtbegin.o, crtbeginS.o, crtend.o, crtendS.o
#     (from Alpine gcc — rustc's linux_musl target spec emits these as
#     bare filenames to the linker, so they must be findable via -L at link
#     time; rustup's self-contained dir is added to -L automatically.)
# None of these come from `-Z build-std` (which only builds Rust crates).
# Without this bundle, rustc's linker invocation falls back to clang's host
# library search (/usr/lib on amd64), silently picking up amd64 artifacts.
# ---------------------------------------------------------------------------
FROM --platform=linux/riscv64 alpine:3.22 AS riscv64-musl-crt
RUN apk add --no-cache musl-dev llvm-libunwind-static gcc
RUN mkdir -p /crt-out && \
    cp /usr/lib/Scrt1.o /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o /usr/lib/rcrt1.o \
       /usr/lib/libc.a /usr/lib/libunwind.a \
       /crt-out/ && \
    cp /usr/lib/gcc/riscv64-alpine-linux-musl/*/crtbegin.o \
       /usr/lib/gcc/riscv64-alpine-linux-musl/*/crtbeginS.o \
       /usr/lib/gcc/riscv64-alpine-linux-musl/*/crtend.o \
       /usr/lib/gcc/riscv64-alpine-linux-musl/*/crtendS.o \
       /crt-out/ && \
    ls -la /crt-out


# ---------------------------------------------------------------------------
# Build std/core/alloc/proc_macro for the tier-3 riscv64gc-unknown-linux-musl
# target. The resulting rlibs are copied into the final image's rustup sysroot
# so downstream builds see the target as fully installed (no -Z build-std,
# no RUSTC_BOOTSTRAP, no rust-src needed downstream).
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION}-alpine3.22 AS riscv64-std-builder
RUN rustup target add riscv64gc-unknown-linux-musl && \
    rustup component add rust-src
RUN apk add musl-dev linux-headers make clang llvm lld mold

ENV PATH=/usr/lib/llvm/bin:$PATH
ENV CC_riscv64gc_unknown_linux_musl=clang \
    CFLAGS_riscv64gc_unknown_linux_musl="--target=riscv64-unknown-linux-musl" \
    AR_riscv64gc_unknown_linux_musl=llvm-ar \
    RANLIB_riscv64gc_unknown_linux_musl=llvm-ranlib
# allow `-Z` flags on stable rust
ENV RUSTC_BOOTSTRAP=1

# Build std (and its deps: core, alloc, proc_macro) for the riscv64 musl
# target by compiling a tiny dummy crate with `-Z build-std`. The compiled
# rlibs end up under target/<triple>/release/deps and we then assemble them
# into a rustup-style sysroot layout at /sysroot-out.
WORKDIR /build-std
RUN cargo init --lib --name dummy_std_build .
# Configure cross-compilation for the dummy crate (mirrors final image config)
RUN mkdir -p .cargo && printf '%s\n' \
    '[target.riscv64gc-unknown-linux-musl]' \
    'linker = "/usr/bin/clang"' \
    'rustflags = [' \
    '    "-C", "link-arg=--ld-path=/usr/bin/mold",' \
    '    "-C", "link-arg=--target=riscv64-unknown-linux-musl",' \
    ']' \
    > .cargo/config.toml

# Build std with:
#   - `-C embed-bitcode=yes` so downstream fat-LTO builds (e.g. vector with
#     `-C lto=fat`) can perform cross-crate LTO including std. Without this,
#     the linker fails with: "failed to get bitcode from object file for
#     LTO (Can't find section .llvmbc)".
#   - `-C target-feature=+crt-static` to match how consumers will be built.
#     Upstream rustc's tier-3 riscv64gc-unknown-linux-musl target spec is
#     missing `crt-static-default: true` (present on x86_64/aarch64 musl),
#     so we bake it in both here and in /usr/local/cargo/config.toml.
#     Mismatched std vs user crt-static can produce TLS/panic-runtime ABI
#     drift at link time.
ENV CARGO_PROFILE_RELEASE_LTO=off
RUN RUSTFLAGS="-C embed-bitcode=yes -C target-feature=+crt-static" \
    cargo build --release \
        --target riscv64gc-unknown-linux-musl \
        -Z build-std=std,panic_abort,core,alloc,proc_macro

# Assemble a rustup-style sysroot fragment containing the freshly built std
# rlibs PLUS the musl libc startup objects that rustc expects under
# self-contained/. rustc looks for these under:
#   <sysroot>/lib/rustlib/<target>/lib/                  (rlibs)
#   <sysroot>/lib/rustlib/<target>/lib/self-contained/   (Scrt1.o, crt1.o, ...)
COPY --from=riscv64-musl-crt /crt-out/ /sysroot-out/lib/rustlib/riscv64gc-unknown-linux-musl/lib/self-contained/
RUN SYSROOT_LIB=/sysroot-out/lib/rustlib/riscv64gc-unknown-linux-musl/lib && \
    mkdir -p "${SYSROOT_LIB}" && \
    cp /build-std/target/riscv64gc-unknown-linux-musl/release/deps/*.rlib "${SYSROOT_LIB}/" && \
    cp /build-std/target/riscv64gc-unknown-linux-musl/release/deps/*.rmeta "${SYSROOT_LIB}/" 2>/dev/null || true && \
    ls -la "${SYSROOT_LIB}" && \
    ls -la "${SYSROOT_LIB}/self-contained/"


FROM rust:${RUST_VERSION}-alpine3.22 AS tools-target-base
ARG RUST_VERSION
ENV TARGETS="x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu riscv64gc-unknown-linux-gnu"
RUN rustup target add ${TARGETS}

# needed for cargo-chef and cargo-sbom, as well as many other compilations
RUN apk add musl-dev linux-headers make clang llvm lld mold python3 git perl protoc

# Stage the prebuilt riscv64gc-unknown-linux-musl std rlibs into a known
# location, then install them into whichever host-arch toolchain dir rustup
# actually created in this image. The target rlibs are host-independent, so
# the same artifacts work regardless of the final image's host architecture.
COPY --from=riscv64-std-builder /sysroot-out/ /tmp/riscv64-musl-sysroot/
RUN HOST_TOOLCHAIN_DIR="$(ls -d /usr/local/rustup/toolchains/${RUST_VERSION}-* | head -n1)" && \
    echo "Installing riscv64-musl std into ${HOST_TOOLCHAIN_DIR}" && \
    cp -r /tmp/riscv64-musl-sysroot/lib "${HOST_TOOLCHAIN_DIR}/" && \
    rm -rf /tmp/riscv64-musl-sysroot && \
    ls -la "${HOST_TOOLCHAIN_DIR}/lib/rustlib/riscv64gc-unknown-linux-musl/lib/"

ENV PATH=/usr/lib/llvm/bin:$PATH
# export cross-compilation vars for all musl targets
ENV CC_aarch64_unknown_linux_musl=clang \
    CFLAGS_aarch64_unknown_linux_musl="--target=aarch64-unknown-linux-musl" \
    AR_aarch64_unknown_linux_musl=llvm-ar \
    RANLIB_aarch64_unknown_linux_musl=llvm-ranlib \
    CC_x86_64_unknown_linux_musl=clang \
    CFLAGS_x86_64_unknown_linux_musl="--target=x86_64-unknown-linux-musl" \
    AR_x86_64_unknown_linux_musl=llvm-ar \
    RANLIB_x86_64_unknown_linux_musl=llvm-ranlib \
    CC_riscv64gc_unknown_linux_musl=clang \
    CFLAGS_riscv64gc_unknown_linux_musl="--target=riscv64-unknown-linux-musl" \
    AR_riscv64gc_unknown_linux_musl=llvm-ar \
    RANLIB_riscv64gc_unknown_linux_musl=llvm-ranlib

# copy the cargo plugins from the tools stage
COPY --from=tools /cargo-cross /usr/local/cargo

# Per-target cross-compile config. Consumers that need to add their own
# rustflags should either (a) not override RUSTFLAGS, or (b) ship their own
# cargo config.toml that uses `[target.<triple>]` or `[target.'cfg(...)']`
# rustflags so cargo merges them with the entries below (rustflags from the
# RUSTFLAGS env var fully replaces config.toml rustflags and is discouraged).
ADD config.toml /usr/local/cargo/
