FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils unzip libnspr4 libnss3 libatk-bridge2.0-0 \
    libgbm1 libxkbcommon0 libasound2t64 libcups2 libdrm2 libdbus-1-3 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libpango-1.0-0 \
    libcairo2 fonts-liberation fonts-noto-color-emoji fonts-noto-cjk \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://nodejs.org/dist/v24.0.0/node-v24.0.0-linux-x64.tar.xz \
    | tar -xJf - --strip-components=1 -C /usr/local
ENV PUPPETEER_SKIP_CHROME_HEADLESS_SHELL_DOWNLOAD=true
ENV PUPPETEER_SKIP_FIREFOX_DOWNLOAD=true
WORKDIR /opt/oracle
COPY package.json package-lock.json ./
RUN npm ci
COPY browser-server.mjs ./
EXPOSE 9222
CMD ["node", "browser-server.mjs"]
