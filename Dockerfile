FROM alpine
MAINTAINER james.eckersall@1and1.co.uk

RUN \
  apk update && apk add ruby bash curl tar && \
  apk del build-base && rm -rf /var/cache/apk/* && \
  curl -L https://github.com/openshift/origin/releases/download/v1.3.0-alpha.2/openshift-origin-client-tools-v1.3.0-alpha.2-983578e-linux-32bit.tar.gz | tar --strip-components=1 --wildcards -zxC /usr/local/bin "*/oc"

COPY loop.sh /
COPY backup_script.rb /
ENTRYPOINT ["/bin/bash", "-e", "/loop.sh"]
