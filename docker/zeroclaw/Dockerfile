FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y \
        git \
        curl \
        bash \
        procps \
        ca-certificates \
        coreutils \
        bash \
        procps \
        debianutils \
        vim-tiny \
        iproute2 \
        iputils-ping \
        iputils-tracepath \
        dnsutils \
        net-tools \
        && \
    apt-get autoremove && apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /zeroclaw-data/.zeroclaw /zeroclaw-data/workspace /zeroclaw-data/logs

COPY config.toml /zeroclaw-data/.zeroclaw/config.toml
COPY SOUL.md /zeroclaw-data/workspace/SOUL.md
COPY AGENTS.md /zeroclaw-data/workspace/AGENTS.md

RUN chmod 600 /zeroclaw-data/.zeroclaw/config.toml && \
    chmod 644 /zeroclaw-data/workspace/SOUL.md && \
    chmod 644 /zeroclaw-data/workspace/AGENTS.md && \
    chown -R 65534:65534 /zeroclaw-data

# Copy zeroclaw binary from original distroless image
COPY --from=ghcr.io/zeroclaw-labs/zeroclaw:v0.1.7 /usr/local/bin/zeroclaw /usr/local/bin/zeroclaw

# Set environment variables (inherited from original image)
ENV PATH="/bin:/sbin:/usr/local/bin:\${PATH}" \
    SHELL=/bin/bash \
    HOME=/zeroclaw-data \
    ZEROCLAW_WORKSPACE=/zeroclaw-data/workspace \
    ZEROCLAW_GATEWAY_PORT=42617

# Match original image configuration
WORKDIR /zeroclaw-data
USER 65534:65534
EXPOSE 42617
ENTRYPOINT ["zeroclaw"]
CMD ["gateway"]
