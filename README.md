# openresty-dns

dns server

## install openresty

```
# wget https://openresty.org/download/openresty-1.15.8.1.tar.gz
# ./configure --prefix=/usr/local/openresty-dns/
# gmake -j
# gmake install
```

## install lua-resty-dns-server

https://github.com/vislee/lua-resty-dns-server

```
wget https://raw.githubusercontent.com/vislee/lua-resty-dns-server/master/lib/resty/dns/server.lua \
 -O /usr/local/openresty-dns/lualib/resty/dns/server.lua
```

## install openresty-dns

```
wget https://raw.githubusercontent.com/selboo/openresty-dns/master/53.lua \
 -O /usr/local/openresty-dns/nginx/conf/53.lua
```

## install redis

```
# yum install redis -y
```

## config nginx.conf

```
#user  nobody;
worker_processes auto;

error_log  logs/error.log ;
pid        logs/nginx.pid;

events {
    worker_connections  1024;
}


stream {

    lua_package_path '/usr/local/openresty-dns/lualib/?.lua;/usr/local/openresty-dns/nginx/conf/?.lua;;';
    lua_package_cpath '/usr/local/openresty-dns/lualib/?.so;;';

    lua_shared_dict QUERYCACHE 32m;

    server {
        listen 53 udp ;
        content_by_lua_file conf/53.lua;
    }


}
```

## start redis openresty-dns

```
# systemctl restart redis
# /usr/local/openresty-dns/nginx/sbin/nginx
```

## dns type

#### A

```
## tld|sub|view|type   value|ttl   set
# redis-cli
127.0.0.1:6379> sadd aikaiyuan.com|lb|*|A 220.181.136.165|3600 220.181.136.166|3600
OK
# dig @127.0.0.1 lb.aikaiyuan.com
```

#### CNAME

```
## tld|sub|view|type   value|ttl    set
# redis-cli
127.0.0.1:6379> sadd aikaiyuan.com|www|*|CNAME   aikaiyuan.appchizi.com.|3600
OK
# dig @127.0.0.1 www.aikaiyuan.com CNAME
```
