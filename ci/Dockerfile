# CI toolchain image with the pinned Zig version.
#
# The Zig toolchain is vendored locally under tools/ (gitignored, ~400 MB),
# so building this image does not depend on ziglang.org being reachable:
#
#   docker build -f ci/Dockerfile -t registry.sl-tx.ru/develop/busybox-zig/zig:0.17.1 .
#   docker push registry.sl-tx.ru/develop/busybox-zig/zig:0.17.1
#
FROM debian:bookworm-slim

ARG ZIG_VERSION=0.17.1
COPY tools/zig-x86_64-linux-${ZIG_VERSION} /opt/zig

ENV PATH="/opt/zig:${PATH}"
WORKDIR /workspace

# The test suite uses /tmp/opencode/... as its scratch directory.
RUN mkdir -p /tmp/opencode && chmod 1777 /tmp/opencode

# The manifest freshness gate (`zig build manifest`) runs the Python extractor.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*

RUN zig version

CMD ["zig", "version"]
