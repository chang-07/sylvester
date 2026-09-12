FROM node:22-slim
WORKDIR /app
COPY server.mjs .
ENV PORT=8080
EXPOSE 8080
USER node
CMD ["node", "server.mjs"]
