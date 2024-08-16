ARG RUST_VERSION=1.80.1
FROM rust:${RUST_VERSION}-alpine3.19
ENV TARGETS x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu riscv64gc-unknown-linux-gnu
RUN rustup target add ${TARGETS}

# needed for cargo-chef and cargo-sbom, as well as many other compilations
RUN apk add musl-dev linux-headers make
RUN cargo install cargo-chef cargo-sbom
