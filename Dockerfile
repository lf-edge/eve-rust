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


FROM rust:${RUST_VERSION}-alpine3.20 AS tools-target-base
ENV TARGETS="x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu riscv64gc-unknown-linux-gnu"
RUN rustup target add ${TARGETS}

# needed for cargo-chef and cargo-sbom, as well as many other compilations
RUN apk add musl-dev linux-headers make clang llvm lld mold python3 git perl protoc

ENV PATH=/usr/lib/llvm/bin:$PATH
# export cross-compilation vars for both musl targets
ENV CC_aarch64_unknown_linux_musl=clang \
    CFLAGS_aarch64_unknown_linux_musl="--target=aarch64-unknown-linux-musl" \
    AR_aarch64_unknown_linux_musl=llvm-ar \
    RANLIB_aarch64_unknown_linux_musl=llvm-ranlib \
    CC_x86_64_unknown_linux_musl=clang \
    CFLAGS_x86_64_unknown_linux_musl="--target=x86_64-unknown-linux-musl" \
    AR_x86_64_unknown_linux_musl=llvm-ar \
    RANLIB_x86_64_unknown_linux_musl=llvm-ranlib

# copy the cargo plugins from the tools stage
COPY --from=tools /cargo-cross /usr/local/cargo
# we define target specific rustc flags for cross-compilation
ADD config.toml /usr/local/cargo/

FROM tools-target-base AS tools-target-amd64
ENV CARGO_BUILD_TARGET="x86_64-unknown-linux-musl"

FROM tools-target-base AS tools-target-arm64
ENV CARGO_BUILD_TARGET="aarch64-unknown-linux-musl"

FROM tools-target-base AS tools-target-riscv64
ENV CARGO_BUILD_TARGET="riscv64gc-unknown-linux-gnu"

FROM tools-target-$TARGETARCH AS tools-target
RUN echo "Cargo target: $CARGO_BUILD_TARGET"
