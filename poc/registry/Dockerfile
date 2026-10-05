FROM registry:2.8.3
RUN apk add --no-cache nginx
COPY nginx.conf /etc/nginx/nginx.conf
COPY start.sh /start.sh
ENTRYPOINT ["/bin/sh", "/start.sh"]
