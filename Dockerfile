FROM alpine
MAINTAINER james.eckersall@1and1.co.uk

RUN \
  apk update && apk add ruby bash curl tar supervisor && \
  apk del build-base && rm -rf /var/cache/apk/* && \
  gem install sinatra -v 1.4.7 --no-rdoc --no-ri && \
  curl -L https://github.com/openshift/origin/releases/download/v1.5.1/openshift-origin-client-tools-v1.5.1-7b451fc-linux-32bit.tar.gz | tar --strip-components=1 --wildcards -zxC /usr/local/bin "*/oc"
COPY files /
RUN \
  mkdir -p /etc/periodic/15min /etc/periodic/hourly /etc/periodic/daily /etc/periodic/weekly /etc/periodic/monthly && \
  chmod +x /etc/periodic/15min/* /etc/periodic/hourly/* /etc/periodic/daily/* /etc/periodic/weekly/* /etc/periodic/monthly/* 2>/dev/null || true

ENTRYPOINT ["supervisord", "--nodaemon", "--configuration", "/etc/supervisord.conf"]
