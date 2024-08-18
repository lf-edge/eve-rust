ARG RUST_VERSION=1.80.1

FROM --platform=$BUILDPLATFORM tonistiigi/xx AS xx

FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION}-alpine3.20 AS builder
ARG TARGETARCH
ARG TARGETOS
COPY --from=xx / /
RUN echo $(xx-info march)-unknown-$(xx-info os)-musl > /etc/rustc_target

RUN rustup target add $(cat /etc/rustc_target)
# needed for cargo-chef and cargo-sbom
RUN apk add musl-dev linux-headers make
RUN cargo install --target=$(cat /etc/rustc_target) cargo-chef@0.1.67 cargo-sbom@0.9.1

FROM rust:${RUST_VERSION}-alpine3.20 AS toolchain
ARG TARGETS="x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu riscv64gc-unknown-linux-gnu"
RUN rustup target add ${TARGETS}

# needed for downstream compilations
RUN apk add musl-dev linux-headers make
COPY --from=builder /usr/local/cargo/bin/cargo-chef /usr/local/cargo/bin
COPY --from=builder /usr/local/cargo/bin/cargo-sbom /usr/local/cargo/bin
