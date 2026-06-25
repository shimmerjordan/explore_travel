# ── build ────────────────────────────────────────────────────────────────────
# Full `rust` image (not -slim): includes gcc, which rusqlite's `bundled`
# feature needs to compile SQLite from source.
FROM rust:1-bookworm AS build
WORKDIR /src
COPY Cargo.toml ./
COPY src ./src
RUN cargo build --release
# Pre-make an empty /data so we can stamp nonroot ownership onto it in the
# final image (distroless has no shell, so we can't mkdir/chown there).
RUN mkdir -p /data

# ── runtime ──────────────────────────────────────────────────────────────────
# distroless/cc has glibc + libgcc (the release binary is dynamically linked
# against glibc). nonroot user, no shell, tiny attack surface.
FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /src/target/release/ejnas /ejnas
# /data owned by the nonroot user (UID 65532). A Docker NAMED volume inherits
# this ownership on first use, so the DB is writable with zero host setup. (A
# bind mount does NOT inherit it — see docker-compose.yml for that case.)
COPY --from=build --chown=65532:65532 /data /data
EXPOSE 48080
VOLUME ["/data"]
USER nonroot:nonroot
ENTRYPOINT ["/ejnas"]
