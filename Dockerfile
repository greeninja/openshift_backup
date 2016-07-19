FROM alpine
MAINTAINER james.eckersall@1and1.co.uk

## Here we install GNU libc (aka glibc) and set C.UTF-8 locale as default.
#
#RUN ALPINE_GLIBC_BASE_URL="https://github.com/sgerrand/alpine-pkg-glibc/releases/download" && \
#    ALPINE_GLIBC_PACKAGE_VERSION="2.23-r3" && \
#    ALPINE_GLIBC_BASE_PACKAGE_FILENAME="glibc-$ALPINE_GLIBC_PACKAGE_VERSION.apk" && \
#    ALPINE_GLIBC_BIN_PACKAGE_FILENAME="glibc-bin-$ALPINE_GLIBC_PACKAGE_VERSION.apk" && \
#    ALPINE_GLIBC_I18N_PACKAGE_FILENAME="glibc-i18n-$ALPINE_GLIBC_PACKAGE_VERSION.apk" && \
#    apk add --no-cache --virtual=.build-dependencies wget ca-certificates && \
#    wget \
#        "https://raw.githubusercontent.com/andyshinn/alpine-pkg-glibc/master/sgerrand.rsa.pub" \
#        -O "/etc/apk/keys/sgerrand.rsa.pub" && \
#    wget \
#        "$ALPINE_GLIBC_BASE_URL/$ALPINE_GLIBC_PACKAGE_VERSION/$ALPINE_GLIBC_BASE_PACKAGE_FILENAME" \
#        "$ALPINE_GLIBC_BASE_URL/$ALPINE_GLIBC_PACKAGE_VERSION/$ALPINE_GLIBC_BIN_PACKAGE_FILENAME" \
#        "$ALPINE_GLIBC_BASE_URL/$ALPINE_GLIBC_PACKAGE_VERSION/$ALPINE_GLIBC_I18N_PACKAGE_FILENAME" && \
#    apk add --no-cache \
#        "$ALPINE_GLIBC_BASE_PACKAGE_FILENAME" \
#        "$ALPINE_GLIBC_BIN_PACKAGE_FILENAME" \
#        "$ALPINE_GLIBC_I18N_PACKAGE_FILENAME" && \
#    \
#    rm "/etc/apk/keys/sgerrand.rsa.pub" && \
#    /usr/glibc-compat/bin/localedef --force --inputfile POSIX --charmap UTF-8 C.UTF-8 || true && \
#    echo "export LANG=C.UTF-8" > /etc/profile.d/locale.sh && \
#    \
#    apk del glibc-i18n && \
#    \
#    rm "/root/.wget-hsts" && \
#    apk del .build-dependencies && \
#    rm \
#        "$ALPINE_GLIBC_BASE_PACKAGE_FILENAME" \
#        "$ALPINE_GLIBC_BIN_PACKAGE_FILENAME" \
#        "$ALPINE_GLIBC_I18N_PACKAGE_FILENAME"
#
#ENV LANG=C.UTF-8


RUN \
  apk update && apk add ruby bash curl tar supervisor && \
  apk del build-base && rm -rf /var/cache/apk/* && \
  curl -L https://github.com/openshift/origin/releases/download/v1.3.0-alpha.2/openshift-origin-client-tools-v1.3.0-alpha.2-983578e-linux-32bit.tar.gz | tar --strip-components=1 --wildcards -zxC /usr/local/bin "*/oc" && \
  gem install sinatra --no-rdoc --no-ri
COPY files /
RUN \
  mkdir -p /etc/periodic/15min /etc/periodic/hourly /etc/periodic/daily /etc/periodic/weekly /etc/periodic/monthly && \
  chmod +x /etc/periodic/15min/* /etc/periodic/hourly/* /etc/periodic/daily/* /etc/periodic/weekly/* /etc/periodic/monthly/* 2>/dev/null || true

ENTRYPOINT ["supervisord", "--nodaemon", "--configuration", "/etc/supervisord.conf"]
