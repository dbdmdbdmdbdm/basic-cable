ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache chromium nodejs npm \
    && mkdir -p /app \
    && cd /app \
    && npm install puppeteer-core@23 \
    && npm cache clean --force

WORKDIR /app
COPY server.js /app/
COPY run.sh /
RUN chmod a+x /run.sh

ENV CHROME_PATH=/usr/bin/chromium-browser

CMD [ "/run.sh" ]
