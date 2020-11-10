#!/bin/bash

cd /app

redis-server &>/dev/null &

# test unit A
echo "del  aikaiyuan.com/a/*/A" | redis-cli
echo 'sadd aikaiyuan.com/a/*/A "1.1.1.1/600"' | redis-cli
echo 'sadd aikaiyuan.com/a/*/A "2.2.2.2/600"' | redis-cli

# test unit CNAME
echo "del  aikaiyuan.com/c/*/CNAME" | redis-cli
echo 'sadd aikaiyuan.com/c/*/CNAME "a.aikaiyuan.com."' | redis-cli

# test unit AAAA
echo "del  aikaiyuan.com/6/*/AAAA" | redis-cli
echo 'sadd aikaiyuan.com/6/*/AAAA "2001:4860:4860::8888/3600"' | redis-cli
echo 'sadd aikaiyuan.com/6/*/AAAA "2001:4860:4860::8844/3600"' | redis-cli

# test unit NS
echo "del  aikaiyuan.com/@/*/NS" | redis-cli
echo 'sadd aikaiyuan.com/@/*/NS "ns1.aikaiyuan.com/86400"' | redis-cli
echo 'sadd aikaiyuan.com/@/*/NS "ns2.aikaiyuan.com/86400"' | redis-cli

# test unit MX
echo "del  aikaiyuan.com/@/*/MX" | redis-cli
echo 'sadd aikaiyuan.com/@/*/MX "mx1.aikaiyuan.com/7200/10"' | redis-cli
echo 'sadd aikaiyuan.com/@/*/MX "mx2.aikaiyuan.com/7200/30"' | redis-cli

# test unit TXT
echo "del  aikaiyuan.com/t/*/TXT" | redis-cli
echo 'sadd aikaiyuan.com/t/*/TXT "is txt/30"' | redis-cli

# test unit SRV
echo "del  aikaiyuan.com/srv/*/SRV" | redis-cli
echo "sadd aikaiyuan.com/srv/*/SRV 1/100/800/a.aikaiyuan.com/120" | redis-cli

# test unit SOA
echo "del aikaiyuan.com/SOA" | redis-cli
echo "set aikaiyuan.com/SOA ns1.aikaiyuan.com/domain.aikaiyuan.com/163/3600/3600/604800/86400/7200" | redis-cli


openresty -p /app -c nginx.conf -g 'daemon off;'


