# ── build ────────────────────────────────────────────────────────────────────
# Requires BuildKit (the default since Docker 20.10). `--platform=$BUILDPLATFORM`
# pins the build stage to the machine doing the building and cross-compiles for
# the target, instead of letting buildx run this stage under QEMU: emulated
# Rust takes 40+ minutes per arch, native cross-compilation a few. Full `rust`
# image (not -slim) — `ureq`'s `rustls`/`ring` dependency compiles C and
# assembly source as part of its build and needs a working gcc (see the
# `libc6-dev-arm64-cross` note below). Whether `-slim` also carries a usable
# gcc has not been measured; the build stage's size doesn't affect the final
# image either way, only how long CI spends pulling it.
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
# `bits/libc-header-start.h: No such file` while compiling ring's C sources.
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

# Cross linker (cargo) + cross C compiler (the `cc` crate, used by ring's
# build script to compile its C/assembly sources). Both are ignored when
# building for amd64.
ENV CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc

# --locked: build exactly the dependency set recorded in Cargo.lock, so a given
# commit always yields the same image contents.
COPY Cargo.toml Cargo.lock ./
COPY src ./src
# The console page is `include_str!`'d into the binary, so it has to be in the
# BUILD stage's context -- not just the runtime stage. Missing it fails the
# compile with `couldn't read src/../assets/dashboard.html`, which only shows up
# in the image build and never when running `cargo build` in a checkout.
COPY assets ./assets
RUN set -eux; \
    TRIPLE="$(cat /triple)"; \
    cargo build --release --locked --target "$TRIPLE"; \
    cp "target/$TRIPLE/release/web-front" /web-front

# Pre-make an empty /data so we can stamp nonroot ownership onto it in the
# final image (distroless has no shell, so we can't mkdir/chown there).
RUN mkdir -p /data

# ── runtime ──────────────────────────────────────────────────────────────────
# distroless/cc has glibc + libgcc (the release binary is dynamically linked
# against glibc). nonroot user, no shell, tiny attack surface. buildx resolves
# this to the TARGET arch automatically.
FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /web-front /web-front
# /data owned by the nonroot user (UID 65532). A Docker NAMED volume inherits
# this ownership on first use, so admin.json and the encrypted config blob
# are writable with zero host setup. (A bind mount does NOT inherit it — see
# docker-compose.yml for that case.)
COPY --from=build --chown=65532:65532 /data /data
# The Flutter web build, if any. Docker has no optional COPY, so web-dist/
# is kept present in the repo by a .gitkeep: an image built without a web
# build in place must still build, and the server serves a setup page for
# a directory that holds nothing but that placeholder.
#
# Deliberately NOT --chown'd to nonroot: default COPY leaves this
# root:root, so the service that will read it at runtime (USER nonroot below)
# has no write access to its own static assets. If the service were ever
# compromised, a writable /web would let the attacker plant a backdoored
# main.dart.js that phishes the next admin login; read-only costs nothing
# here since nothing at runtime ever needs to write into /web. Verified, not
# assumed: with plain root:root ownership nonroot reads through nested
# directories and a 0644 file, and is refused when it tries to overwrite,
# create, or delete anything under it.
#
# Also deliberately NOT --chmod=0644: that flag applies to
# directories too, and a directory that loses its execute bit can no longer
# be traversed at all, breaking every nested asset (assets/, canvaskit/,
# etc.) — see `open_within` in static_files.rs, which requires the whole
# path to be traversable to reach the file it re-opens by fd.
#
# Precondition this relies on: whatever copies a real web build into
# web-dist/ before `docker build` (CI, or a local `flutter build web`) must
# leave files/directories world-readable (the Flutter build output already
# is, and `COPY` preserves whatever mode bits the host files have — a 0600
# file on the host stays unreadable to nonroot in the image).
COPY web-dist/ /web/
EXPOSE 48080
VOLUME ["/data"]
USER nonroot:nonroot
ENTRYPOINT ["/web-front"]
