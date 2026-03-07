FROM node:22-bookworm-slim

# Bootstrap ca-certificates over HTTP first (slim image has none)
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Now switch apt sources to HTTPS (fixes Docker Desktop for Mac networking)
RUN sed -i "s|http://deb.debian.org|https://deb.debian.org|g" /etc/apt/sources.list.d/debian.sources

# System deps: browser, media, search, Playwright (Chromium), IR blaster (ir-blast skill)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git chromium ffmpeg ripgrep python3 python3-pip \
    v4l-utils \
    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2 \
    fonts-noto-color-emoji fonts-freefont-ttf \
    && rm -rf /var/lib/apt/lists/*

# Rename existing UID-1000 user (node) to ai_sandbox for clarity
RUN usermod -l ai_sandbox -d /home/ai_sandbox -m node \
    && groupmod -n ai_sandbox node \
    && mkdir -p /home/ai_sandbox/.openclaw \
    && chown -R 1000:1000 /home/ai_sandbox

USER ai_sandbox
WORKDIR /home/ai_sandbox

# Python Playwright + stealth for browser_automation
RUN pip3 install --break-system-packages playwright playwright-stealth pypdf pymupdf && python3 -m playwright install chromium

# Install OpenClaw via official installer
RUN curl -fsSL --proto "=https" --tlsv1.2 https://openclaw.ai/install.sh | bash \
    || [ -f /home/ai_sandbox/.npm-global/bin/openclaw ]

ENV PATH="/home/ai_sandbox/.npm-global/bin:${PATH}"

EXPOSE 18789

# Run the gateway server. Binding is controlled by openclaw.json (bind: "lan").
CMD ["openclaw", "gateway"]
