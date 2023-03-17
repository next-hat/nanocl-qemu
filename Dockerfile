FROM alpine:3.17

RUN apk add --no-cache qemu-system-x86_64 iproute2 bash cloud-utils cdrkit
RUN apk add --no-cache iptables dnsmasq

COPY ./cloud-localds /usr/bin/cloud-localds
RUN chmod +x /usr/bin/cloud-localds

COPY ./entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT [ "/bin/sh", "entrypoint.sh" ]
