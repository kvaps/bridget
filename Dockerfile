FROM alpine
RUN apk add --no-cache iproute2 iputils
ADD bridget.sh /bin/bridget.sh
CMD . /bin/bridget.sh
