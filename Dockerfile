ARG RUST_VERSION=1.80.1
FROM rust:${RUST_VERSION}-alpine3.19
ENV TARGETS x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu riscv64gc-unknown-linux-gnu
RUN rustup target add x86_64-unknown-linux-musl 
RUN cargo install cargo-chef cargo-sbom
