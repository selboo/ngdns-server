FROM centos:7

LABEL maintainer="Selboo <root@selboo.com>"

ENV APP_PATH=/app
ENV OPENRESTY_VERSION="1.19.3.1"
ENV OPENRESTY_PATH=/usr/local/ngdns-server
ENV PATH $OPENRESTY_PATH/bin:$PATH

WORKDIR $APP_PATH

ADD https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz $APP_PATH
ADD https://github.com/vislee/ngx_stream_ipdb_module/archive/add-lua-api.zip $APP_PATH/ngx_stream_ipdb_module-add-lua-api.zip

RUN yum install -y perl make gcc unzip redis perl-Digest-MD5 \
    openssl-devel bind-utils json-c-devel wget pcre-devel \
    && yum clean all \
    && rm -fr /tmp/* /var/cache/yum/* \
    && tar zxvf openresty-${OPENRESTY_VERSION}.tar.gz \
    && unzip ngx_stream_ipdb_module-add-lua-api.zip \
    && sed -i 's/ngx_stream_lua_get_request/ngx_stream_lua_get_req/g' /app/ngx_stream_ipdb_module-add-lua-api/ngx_stream_ipdb_lua.c \
    && cd openresty-${OPENRESTY_VERSION} \
    && ./configure --prefix=$OPENRESTY_PATH --with-stream \
        --add-module=/app/ngx_stream_ipdb_module-add-lua-api/ \
        --with-cc-opt="-I $PWD/build/ngx_stream_lua*/src" \
    && make -j 4 && make install


FROM centos:7

ENV APP_PATH=/app
ENV OPENRESTY_VERSION="1.19.3.1"
ENV OPENRESTY_PATH=/usr/local/ngdns-server
ENV PATH $OPENRESTY_PATH/bin:$PATH

WORKDIR $APP_PATH

ADD https://cdn.jsdelivr.net/npm/qqwry.ipdb/qqwry.ipdb $APP_PATH
ADD http://mirrors.aliyun.com/repo/epel-7.repo /etc/yum.repos.d/epel.repo

COPY nginx.conf $APP_PATH
COPY 53.lua $APP_PATH
COPY docker-entrypoint.sh $APP_PATH
COPY redis_iresty.lua $APP_PATH

COPY --from=0 $OPENRESTY_PATH $OPENRESTY_PATH

RUN yum install -y redis bind-utils wget perl perl-Digest-MD5 \
    && yum clean all \
    && rm -fr /tmp/* /var/cache/yum/* \
    && opm get vislee/lua-resty-dns-server \
    && wget https://github.com/vislee/lua-resty-dns-server/raw/add-feature-subnet/lib/resty/dns/server.lua -O /usr/local/ngdns-server/site/lualib/resty/dns/server.lua \
    && opm get thibaultcha/lua-resty-mlcache \ 
    && opm get p0pr0ck5/lua-resty-logger-socket \
    && mkdir -p $APP_PATH/logs \
    && ln -sf /dev/stdout $APP_PATH/logs/access.log \
    && ln -sf /dev/stderr $APP_PATH/logs/error.log

EXPOSE 53/tcp
EXPOSE 53/udp
EXPOSE 6379/tcp

ENTRYPOINT ["/bin/bash", "/app/docker-entrypoint.sh"]


STOPSIGNAL SIGQUIT