FROM node:20-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends chromium fonts-liberation fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN npm install puppeteer-core@23 && npm cache clean --force
COPY server.js .
ENV CHROME_PATH=/usr/bin/chromium
EXPOSE 8080
CMD ["node", "server.js"]
