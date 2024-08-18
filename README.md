# eve-rust

Base image for building rust-based executables in containers for the EVE platform. Contains the basic rust binaries
such as `rustc`, `cargo`, `rustup`, etc., as well as additional plugins and targets. As of this writing:

* `cargo-chef` - a tool for building and caching dependencies for a rust project
* `cargo-sbom` - a tool for generating SBoMs for rust-based projects
* targets to build for linux amd64, arm64 and riscv64 on linux for both musl and glibc

The image also includes additional tools to support cross-compilation

* `mold` - a very fast linker for cross-compilation targets
* `clang` - to invoke `mold` for cross-compilation targets

## Usage

Use this image as a base `FROM` when building in your EVE Dockerfile. For example:

```Dockerfile
FROM lfedge/eve-rust:1.80.1 AS rust

ADD https://github.com/foo/bar.git#v1.2.3 /src/foo
WORKDIR /src/foo

# tools already in place
RUN cargo build --release
RUN cargo sbom > sbom.spdx.json

FROM lfedge/eve-alpine:1f7685f95a475c6bbe682f0b976f12180b6c8726 AS build
# do the rest of your regular eve-alpine work

COPY --from=rust /src/foo/target/release/foo /out/foo

FROM scratch

COPY --from=build /out/ /
```

The above assumes that you do *not* need additional eve-alpine packages inside the rust build stage. This should work for
the overwhelming majority of cases. If it does not work for you, and you need to use the rust toolchain _inside_ of
your build `FROM eve-alpine`,, you can copy the build toolchain from `eve-rust` into your `eve-alpine` image. For example:

```Dockerfile
FROM lfedge/eve-rust:1.80.1 AS rust
FROM lfedge/eve-alpine:1f7685f95a475c6bbe682f0b976f12180b6c8726 AS build

ENV BUILD_PKGS packages you need for build # e.g. gcc, make, etc.
ENV PKGS packages you need for final install # e.g. mtools dosfstools
RUN eve-alpine-deploy.sh

# copy over the tooling we need from the rust image
# ALL OF THESE STEPS ARE REQUIRED
COPY --from=rust /usr/local/cargo /usr/local/cargo
COPY --from=rust /usr/local/rustup /usr/local/rustup
ENV RUSTUP_HOME=/usr/local/rustup
ENV PATH=/usr/local/cargo/bin:${PATH}
ENV CARGO_HOME=/usr/local/cargo

# build as before
ADD https://github.com/foo/bar.git#v1.2.3 /src/foo
WORKDIR /src/foo
RUN cargo build --release
RUN cargo sbom > sbom.spdx.json
```

To enable cross-compilation we need few extra steps. By default cargo builds for host platform so the target must be specified explicitly either using `--target <target>` or by setting `CARGO_BUILD_TARGET` environment variable. See [Cargo docs](https://doc.rust-lang.org/cargo/reference/environment-variables.html?highlight=CARGO_BUILD_TARGET#configuration-environment-variables)

```Dockerfile
# we use host tools to avoid emulation and slow builds
FROM --platform=$BUILDPLATFORM lfedge/eve-rust:1.80.1 AS rust-host
ARG TARGETARCH

# map Docker's $TARGETARCH to Rust target
FROM rust-host AS target-amd64
ENV CARGO_BUILD_TARGET="x86_64-unknown-linux-musl"

FROM rust-host AS target-arm64
ENV CARGO_BUILD_TARGET="aarch64-unknown-linux-musl"

FROM rust-host AS target-riscv64
ENV CARGO_BUILD_TARGET="riscv64gc-unknown-linux-gnu"

FROM target-$TARGETARCH AS rust

ADD https://github.com/foo/bar.git#v1.2.3 /src/foo
WORKDIR /src/foo

# invoke you build here e.g. cargo build --release

# cargo creates a subdirectory /<your app>/target/$CARGO_BUILD_TARGET
# copy build artifacts to a common place to avoid passing extra ARG to following
# stage that doesn't inherit the environment
RUN cp /src/foo/target/$CARGO_BUILD_TARGET/release/foo /src/foo/target/release/foo


FROM lfedge/eve-alpine:1f7685f95a475c6bbe682f0b976f12180b6c8726 AS build
# do the rest of your regular eve-alpine work

COPY --from=rust /src/foo/target/release/foo /out/foo

FROM scratch

COPY --from=build /out/ /
```


## Supported platforms

This image is built for linux/amd64 and linux/arm64. riscv64 is
not supported _yet_ as a host platform, and therefore no image is released for riscv64.
When rust on alpine is fully ready, it will be added, likely with alpine 3.21.

Supported target platforms are listed in the [Dockerfile](./Dockerfile#L3). As of this writing, these
are:

* x86_64-unknown-linux-musl
* aarch64-unknown-linux-musl
* x86_64-unknown-linux-gnu
* aarch64-unknown-linux-gnu
* riscv64gc-unknown-linux-gnu

Note that riscv64 is supported gnu only, not musl, and so is not usable on Alpine-based systems
without first installing glibc. This, too, will be fixed when rust on alpine is fully ready.

## Versioning

The version of this image is the version of the rust toolchain it contains. This makes it easy to know what
version of rust you are using. For rust version 1.80.1, the image tag is `lfedge/eve-rust:1.80.1`.

We try very hard never to cut a new image of `eve-rust` that uses the same rust version as a previous one.
For example, if `eve-rust:1.80.1` is released, and we need to add a new cargo plugin or build target,
we will bump to a newer version of rust and include it, thus getting to `eve-rust:1.80.2`.

In the rare case that this does not work, and we **must** release a new image of `eve-rust` with the same rust version
as an already-released image of `eve-rust`, we will append a patch version to the tag. For example, if `eve-rust:1.80.1`
is released, and we need to add a new cargo plugin or build target, we will release `eve-rust:1.80.1-1`, where `-1` is
the sequential `eve-rust` patch version. This will be very short-lived, only as long as we need to get to the next
version of rust.

New versions are released to Docker Hub by adding a tag, e.g. `1.80.1` or `1.80.1-1`. The GitHub Actions workflow
checks that it matches the version in the Dockerfile, and if it does not, it will fail the build.
