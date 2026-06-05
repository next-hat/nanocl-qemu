FROM alpine:3.18.2

RUN apk update \
    && apk upgrade \
    && apk add qemu-system-x86_64 \
        qemu-ui-gtk \
        qemu-ui-sdl \
        libcanberra-gtk3 \
        gdk-pixbuf \
        shared-mime-info \
        adwaita-icon-theme \
        fontconfig \
        ttf-dejavu \
        iproute2 \
        bash \
        python3 \
        py3-pip \
        cloud-utils \
        cdrkit \
        && pip3 install --break-system-packages --no-cache-dir websockify \
        && rm -rf /var/cache/apk/* \
        && rm -rf /tmp/*

COPY ./cloud-localds /usr/bin/cloud-localds
RUN chmod +x /usr/bin/cloud-localds

COPY ./entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5930 6080

LABEL org.opencontainers.image.source=https://github.com/next-hat/nanocl-qemu
LABEL org.opencontainers.image.description="Nanocl Qemu Runtime"

ENTRYPOINT [ "/bin/bash", "/entrypoint.sh" ]
