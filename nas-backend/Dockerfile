# ── build ────────────────────────────────────────────────────────────────────
# Requires BuildKit (the default since Docker 20.10). `--platform=$BUILDPLATFORM`
# pins the build stage to the machine doing the building and cross-compiles for
# the target, instead of letting buildx run this stage under QEMU: emulated
# Rust + bundled-SQLite takes 40+ minutes per arch, native cross-compilation a
# few. Full `rust` image (not -slim) — rusqlite's `bundled` feature compiles
# SQLite from C source and needs a working gcc.
FROM --platform=$BUILDPLATFORM rust:1-bookworm AS build
ARG TARGETARCH
WORKDIR /src

# Resolve the target triple and, for a foreign arch, install the cross
# toolchain. Fails loudly on an arch we haven't taught it about rather than
# silently producing a host-arch binary.
#
# libc6-dev-arm64-cross is REQUIRED, not optional — do NOT drop it: it ships the
# aarch64 glibc headers/libs under /usr/aarch64-linux-gnu. Debian only
# *Recommends* it from gcc-aarch64-linux-gnu, so with --no-install-recommends the
# cross gcc silently falls back to the host's /usr/include and dies with
# `bits/libc-header-start.h: No such file` while compiling ring's and bundled
# SQLite's C sources.
#
# Keep this RUN body free of `#` comments: a comment line here carries no
# trailing backslash, so if it were ever treated as shell input instead of being
# stripped as a Dockerfile comment, the RUN would end early and the next line
# would parse as a Dockerfile instruction.
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) TRIPLE=x86_64-unknown-linux-gnu ;; \
      arm64) TRIPLE=aarch64-unknown-linux-gnu; \
             apt-get update; \
             apt-get install -y --no-install-recommends \
               gcc-aarch64-linux-gnu libc6-dev-arm64-cross; \
             rm -rf /var/lib/apt/lists/* ;; \
      *) echo "unsupported TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
    esac; \
    echo "$TRIPLE" > /triple; \
    rustup target add "$TRIPLE"

# Cross linker (cargo) + cross C compiler (the `cc` crate, used by
# libsqlite3-sys). Both are ignored when building for amd64.
ENV CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc

# --locked: build exactly the dependency set recorded in Cargo.lock, so a given
# commit always yields the same image contents.
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN set -eux; \
    TRIPLE="$(cat /triple)"; \
    cargo build --release --locked --target "$TRIPLE"; \
    cp "target/$TRIPLE/release/ejnas" /ejnas

# Pre-make an empty /data so we can stamp nonroot ownership onto it in the
# final image (distroless has no shell, so we can't mkdir/chown there).
RUN mkdir -p /data

# ── runtime ──────────────────────────────────────────────────────────────────
# distroless/cc has glibc + libgcc (the release binary is dynamically linked
# against glibc). nonroot user, no shell, tiny attack surface. buildx resolves
# this to the TARGET arch automatically.
FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /ejnas /ejnas
# /data owned by the nonroot user (UID 65532). A Docker NAMED volume inherits
# this ownership on first use, so the DB is writable with zero host setup. (A
# bind mount does NOT inherit it — see docker-compose.yml for that case.)
COPY --from=build --chown=65532:65532 /data /data
EXPOSE 48080
VOLUME ["/data"]
USER nonroot:nonroot
ENTRYPOINT ["/ejnas"]
