# pmbootstrap, run by pmb-exec.sh. The image is the host's architecture; pmbootstrap's own
# chroots bring qemu-user for foreign arches (binfmt_misc, mounted by entrypoint.sh).
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf
RUN apk add --no-cache python3 git openssl sudo su-exec util-linux multipath-tools procps tar \
 && adduser -D -u 1000 pmos \
 && echo 'pmos ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/pmos
ARG PMB_VERSION=3.12.1
ARG PMB_COMMIT=7d23010a125ca7386fec4e390d14128b6c24d266
RUN git clone -q --depth 1 --branch "$PMB_VERSION" \
      https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git /opt/pmbootstrap \
 && test "$(git -C /opt/pmbootstrap rev-parse HEAD)" = "$PMB_COMMIT" \
 && ln -s /opt/pmbootstrap/pmbootstrap.py /usr/local/bin/pmbootstrap
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
ENV HOME=/home/pmos
WORKDIR /home/pmos
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
