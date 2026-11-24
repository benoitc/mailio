# Dovecot 2.3 from Alpine, so it runs natively on arm64 and amd64 alike.
FROM alpine:3.20
RUN apk add --no-cache dovecot dovecot-pop3d && adduser -D -u 1000 vmail
CMD ["dovecot", "-F"]
