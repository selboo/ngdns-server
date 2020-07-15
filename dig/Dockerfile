
FROM selboo/dig:base

ARG dig_version=9.11.20

ADD https://downloads.isc.org/isc/bind9/${dig_version}/bind-${dig_version}.tar.gz /tmp/
#COPY bind-${dig_version}.tar.xz /tmp/


RUN cd /tmp/ \
    && tar zxvf bind-${dig_version}.tar.gz \
    && cd bind-${dig_version} \
    && ./configure --without-python --disable-symtable --disable-linux-caps && make -j && make install \
    && rm -rf /tmp/*

FROM frolvlad/alpine-glibc

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories \
    && apk add --no-cache libuv-dev 

COPY --from=0 /usr/local/bin/dig /bin/dig
COPY --from=0 /usr/local/bin/host /bin/host
COPY --from=0 /usr/local/bin/nslookup /bin/nslookup
#COPY --from=0 /usr/local/bind/lib /usr/local/bind/lib

