FROM alpine:3.18.2

RUN apk update \
    && apk upgrade \
    && apk add qemu-system-x86_64 \
        iproute2 \
        bash \
        cloud-utils \
        cdrkit \
        && rm -rf /var/cache/apk/* \
        && rm -rf /tmp/*

COPY ./cloud-localds /usr/bin/cloud-localds
RUN chmod +x /usr/bin/cloud-localds

COPY ./entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

LABEL org.opencontainers.image.source https://github.com/nxthat/nanocl-qemu
LABEL org.opencontainers.image.description Nanocl Qemu Runtime

ENTRYPOINT [ "/bin/sh", "entrypoint.sh" ]
