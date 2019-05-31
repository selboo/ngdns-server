
require 'resty.core.regex'
local gsub   = string.gsub
local find   = ngx.re.find
local ssub   = string.sub
local gsub   = string.gsub

local server = require 'resty.dns.server'
local sock, err = ngx.req.socket()
local dns = server:new()
local redis = require "resty.redis"
local red = redis:new()
red:set_timeout(3000)

local request_remote_addr = ngx.var.remote_addr

local function ver_and_ttl ( key, re )
    local m, err = find(key, re, "jo")
    if m then
        local ver = ssub(key, 1, m - 1)
        local ttl = ssub(key, m + 1 , -1)

        return ver, ttl, _
    else
        return "", "", err
    end
end


local function getdns( key, rtype )
    local ok, err = red:connect("127.0.0.1", 6379)
    local ver = ""
    if not ok then
        ngx.log(ngx.ERR, "1003 connect 127.0.0.1:6379 redis fail: ", err)
    end

    ngx.log(ngx.DEBUG, "getdns key:", key, " rtype: ", rtype)

    if rtype == "string" then
        ver, err = red:get(key)
    elseif rtype == "set" then
        ver, err = red:smembers(key)
    else
        ngx.log(ngx.DEBUG, "error rtype: ", rtype)
        ver, err = "", "null"
    end

    local ok, _ = red:set_keepalive(10000, 100)
    if not ok then
        ngx.log(ngx.DEBUG, "failed to set keepalive")
    end

    return ver, err

end

local function init()
    if not sock then
        ngx.log(ngx.ERR, "failed to get the request socket: ", err)
        return ngx.exit(ngx.ERROR)
    end

    local req, err = sock:receive()
    if not req then
        ngx.log(ngx.ERR, "failed to receive: ", err)
        return ngx.exit(ngx.ERROR)
    end

    return req
end

local function dnsserver(req)
    local request, err = dns:decode_request(req)

    if not request then
        ngx.log(ngx.ERR, "failed to decode request: ", err)

        local resp = dns:encode_response()
        local ok, err = sock:send(resp)
        if not ok then
            ngx.log(ngx.ERR, "failed to send: ", err)
            ngx.exit(ngx.ERROR)
        end

        return
    end

    return request

end

local function sub_and_tld(request)

    local sub, tld = "", ""
    local query = request.questions[1]

    ngx.log(ngx.DEBUG, "qname: ", query.qname, " qtype: ", query.qtype, " ngx.var.remote_addr: ", ngx.var.remote_addr)

    local m, _, err = find(query.qname, ".[A-Za-z0-9--]*(.com|.cn|.net|.com.cn)", "jo")
    if m then
        if m == 1 then
            sub = "@"
            tld = query.qname
        else
            sub = ssub(query.qname, 1, m - 1)
            tld = ssub(query.qname, m + 1 , -1)
        end
        ngx.log(ngx.DEBUG, " sub: ", sub, " tld: ", tld)
    else
        ngx.log(ngx.DEBUG, "find error: ", err)
        return query, sub, tld, err
    end

    return query, sub, tld, _
end

local function ip_to_isp ( ip )
    -- TODO
    return "*"
end

local req = init()
local request = dnsserver(req)
local view = ip_to_isp(request_remote_addr)
local query, sub, tld, err = sub_and_tld(request)

if not err then
    ngx.log(ngx.DEBUG, "sub_and_tld: ", err)
    return 
end

if query.qtype == server.TYPE_CNAME then
    -- CNAME
    --     tld|sub|view|type   value|ttl    string
    -- set aikaiyuan.com|www|*|CNAME   aikaiyuan.appchizi.com.|3600

    local key = tld .. "|" .. sub .. "|" .. view .. "|" .. "CNAME"
    local redis_value = getdns(key, "string")
    ngx.log(ngx.DEBUG, "TYPE_CNAME key: ", key)

    local ver, ttl, err = ver_and_ttl(redis_value, "\\|")
    if not err then
        ngx.log(ngx.DEBUG, " ver: ", ver, " ttl: ", ttl)
    else
        ngx.log(ngx.DEBUG, "find error: ", err)
        return 
    end
 
    dns:create_cname_answer(query.qname, ttl, ver)

elseif query.qtype == server.TYPE_A then
    -- A
    --     tld|sub|view|type   value|ttl   set
    -- sadd aikaiyuan.com|lb|*|A 220.181.136.165|3600 220.181.136.166|3600

    local key = tld .. "|" .. sub .. "|" .. view .. "|" .. "A"
    local redis_value = getdns(key, "set")
    ngx.log(ngx.DEBUG, "TYPE_A key: ", key)

    for _, ver in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, "A: ", ver)

        local ver, ttl, err = ver_and_ttl(ver, "\\|")
        ngx.log(ngx.DEBUG, " ver: ", ver, " ttl: ", ttl)

        dns:create_a_answer(query.qname, ttl, ver)

    end

elseif  query.qtype == server.TYPE_AAAA then
    -- AAAA
    --     tld|sub|view|type   value|ttl   set
    -- sadd aikaiyuan.com|ipv6|*|AAAA 2400:89c0:1022:657::152:150|86400 2400:89c0:1032:157::31:1201|86400

    local key = tld .. "|" .. sub .. "|" .. view .. "|" .. "AAAA"
    local redis_value = getdns(key, "set")
    ngx.log(ngx.DEBUG, "TYPE_AAAA key: ", key)

    for index, ver in ipairs(redis_value) do

        local ver, ttl, err = ver_and_ttl(ver, "\\|")
        ngx.log(ngx.DEBUG, "index: ", index, " q: ",query.qname, " ver: ", ver, " ttl: ", ttl)

        dns:create_aaaa_answer(query.qname, ttl, ver)

    end

elseif  query.qtype == server.TYPE_MX then
    -- MX
    --     tld|sub|view|type   value|ttl   set
    -- sadd aikaiyuan.com|@|*|MX smtp1.qq.com.|720 smtp2.qq.com.|720

    local key = tld .. "|" .. sub .. "|" .. view .. "|" .. "MX"
    local redis_value = getdns(key, "set")
    ngx.log(ngx.DEBUG, "TYPE_MX key: ", key)

    for _, ver in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, "A: ", ver)

        local ver, ttl, err = ver_and_ttl(ver, "\\|")
        ngx.log(ngx.DEBUG, " ver: ", ver, " ttl: ", ttl)

        dns:create_mx_answer(query.qname, ttl, ver)

    end

elseif  query.qtype == server.TYPE_TXT then

    dns:create_txt_answer(query.qname, "999", "ttttttttt")

elseif  query.qtype == server.TYPE_NS then

    dns:create_ns_answer(query.qname, "999", "ns1.aikaiyuan.com")
    dns:create_ns_answer(query.qname, "999", "ns2.aikaiyuan.com")

elseif  query.qtype == server.TYPE_SRV then

    dns:create_srv_answer(query.qname, "86400", "100", "100", "80", "www.aikaiyuan.com")
    
else
    dns:create_soa_answer(tld, 600, "ns1.aikaiyuan.com.", "domain.aikaiyuan.com.", 1558348800, 1800, 900, 604800, 86400)
end

local resp = dns:encode_response()
local ok, err = sock:send(resp)
if not ok then
    ngx.log(ngx.ERR, "failed to send: ", err)
    return
end



