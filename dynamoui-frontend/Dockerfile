FROM node:20-alpine AS build

WORKDIR /app
COPY package*.json ./
RUN npm ci --prefer-offline
COPY . .
ENV VITE_API_BASE_URL=/api/v1
RUN npm run build

FROM nginx:1.27-alpine
RUN rm /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
COPY scripts/nginx.conf.template /etc/nginx/templates/nginx.conf.template
COPY scripts/docker_entrypoint.sh /docker_entrypoint.sh
RUN chmod +x /docker_entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/docker_entrypoint.sh"]
