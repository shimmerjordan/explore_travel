# explore_journal backend — leaderboard + group relay.
# Zero npm dependencies → no `npm install`, no node_modules, no lockfile
# drift. The image is just the runtime plus ~1500 lines of JS.
FROM node:22-alpine

ENV NODE_ENV=production \
    PORT=48081 \
    DATA_DIR=/data

WORKDIR /app
COPY server/ ./server/
COPY package.json ./

# Persisted leaderboard lives here — mount a volume over it.
RUN mkdir -p /data && chown node:node /data /app
VOLUME /data

USER node
EXPOSE 48081

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -qO- "http://127.0.0.1:${PORT}/healthz" || exit 1

CMD ["node", "server/server.js"]
