FROM alpine
RUN apk add --no-cache iproute2
RUN apk add --no-cache arping
ADD start.sh /bin/start.sh
CMD . /bin/start.sh
