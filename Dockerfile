FROM alpine
RUN apk add --no-cache iproute2
ADD start.sh /bin/start.sh
CMD . /bin/start.sh
