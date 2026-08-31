FROM node:26-alpine

# Build argument for version (can be overridden during build)
ARG VERSION=1.0.8

# Set metadata
LABEL maintainer="kjanat" \
    description="SVG Converter - Convert SVG files to multiple formats" \
    version="${VERSION}"

# Copy VERSION file for runtime reference
COPY VERSION /tmp/VERSION

# Enable pnpm
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable

# Create non-root user early for security
RUN addgroup -g 1001 svguser && \
    adduser -u 1001 -G svguser -s /bin/bash -D svguser

# Install minimal system dependencies in a single layer
RUN apk add --no-cache \
    # Basic tools
    bash \
    curl \
    ca-certificates \
    jq \
    coreutils \
    findutils \
    # Core image conversion (lightweight alternatives)
    librsvg \
    imagemagick \
    # Essential fonts only
    fontconfig \
    ttf-dejavu \
    # Minimal font rendering
    freetype \
    cairo \
    pango \
    # Remove package cache
    && rm -rf /var/cache/apk/*

# Create working directories and set proper permissions
RUN mkdir -p /app /tmp/svg-converter /github/workspace \
    /home/svguser/.config /home/svguser/.local/share /home/svguser/.cache && \
    chown -R svguser:svguser /app /tmp/svg-converter /github/workspace \
    /home/svguser/.config /home/svguser/.local /home/svguser/.cache && \
    chmod -R 755 /home/svguser/.config /home/svguser/.local /home/svguser/.cache

# Install only essential web-safe fonts (much smaller than MS Core Fonts)
RUN apk add --no-cache \
    ttf-liberation \
    font-noto \
    && fc-cache -f \
    && rm -rf /var/cache/apk/*

# Copy package files for dependency installation
COPY --chown=svguser:svguser package.json pnpm-lock.yaml* /app/

# Switch to app directory and install dependencies
WORKDIR /app
RUN --mount=type=cache,id=pnpm,target=/pnpm/store,uid=1001,gid=1001 \
    pnpm install --frozen-lockfile --prod

# Copy application code after dependencies are installed
COPY --chown=svguser:svguser . /app/

# Make entrypoint script executable
RUN chmod +x /app/entrypoint.sh

# Switch to non-root user
USER svguser

# Add /app/node_modules/.bin to PATH so CLI tools are available
ENV PATH="/app/node_modules/.bin:$PATH"

# Set working directory
WORKDIR /github/workspace

# Set minimal environment variables
ENV FONTCONFIG_PATH=/etc/fonts \
    XDG_CONFIG_HOME=/home/svguser/.config \
    XDG_DATA_HOME=/home/svguser/.local/share \
    XDG_CACHE_HOME=/home/svguser/.cache

# Set the entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]
