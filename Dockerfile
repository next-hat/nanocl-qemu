FROM alpine:3.17.3

RUN rm -rf /var/cache/apk/* && rm -rf /tmp/*
RUN apk update && apk upgrade
RUN apk add qemu-system-x86_64 iproute2 bash cloud-utils cdrkit
RUN apk add iptables dnsmasq

COPY ./cloud-localds /usr/bin/cloud-localds
RUN chmod +x /usr/bin/cloud-localds

COPY ./entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

LABEL org.opencontainers.image.source https://github.com/nxthat/nanocl-qemu
LABEL org.opencontainers.image.description Nanocl Qemu Runtime

ENTRYPOINT [ "/bin/sh", "entrypoint.sh" ]
