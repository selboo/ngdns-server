
require 'resty.core.regex'

local gsub   = string.gsub
local ssub   = string.sub
local find   = ngx.re.find

local server = require 'resty.dns.server'
local sock, err = ngx.req.socket()
local dns = server:new()

local cjson = require "cjson"

local redis = require "resty.redis"
local red = redis:new()
red:set_timeout(3000)

local request_remote_addr = ngx.var.remote_addr




local function ver_and_ttl ( key )
    local m, err = find(key, "\\|", "ijo")
    if m then
        local ver = ssub(key, 1, m - 1)
        local ttl = ssub(key, m + 1 , -1)

        return ver, ttl, _
    else
        return "", "", err
    end
end

local function redisconnect()
    local ok, err = red:connect("127.0.0.1", 6379)
    if not ok then
        ngx.log(ngx.ERR, "1003 connect 127.0.0.1:6379 redis fail: ", err)
        return false, err
    end

    return red, _
end

local function _getcache( prefix, key )
    local var, err = QC:get(prefix .. key)
    if var then
        ngx.log(ngx.DEBUG, "HIT key: " .. prefix .. key .. " value: ", var)
        return var
    end

    return false
end

local function cache_exist( key )

    local red , err = redisconnect()
    local ver, err = red:exists(key)
    return ver

end

local function existsdns( key )

    local value, err = cache:get("_exist_" .. key, nil, cache_exist, key)
    return value

end

local function cache_dns( key )

    local red , err = redisconnect()
    local ver, err = red:smembers(key)
    return cjson.encode(ver)

end

local function getdns( prefix, key )

    local value, err = cache:get(prefix .. key, nil, cache_dns, key)
    return cjson.decode(value), _

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


local function _cname( key )
    -- CNAME
    --     tld|sub|view|type   value|ttl    set
    -- sadd aikaiyuan.com|www|*|CNAME   aikaiyuan.appchizi.com.|3600

    local redis_value = getdns("_CNAME_", key)
    ngx.log(ngx.DEBUG, "TYPE_CNAME key: ", key)

    for _, ver in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, "CNAME: ", ver)

        local ver, ttl, err = ver_and_ttl(ver)
        ngx.log(ngx.DEBUG, " ver: ", ver, " ttl: ", ttl)

        dns:create_cname_answer(query.qname, ttl, ver)

    end

end

local function _a( key )
    -- A
    --     tld|sub|view|type   value|ttl   set
    -- sadd aikaiyuan.com|lb|*|A 220.181.136.165|3600 220.181.136.166|3600

    ngx.log(ngx.DEBUG, "TYPE_A key: ", key)
    local redis_value = getdns("_A_", key)

    for _, ver in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, "A: ", ver)

        local ver, ttl, err = ver_and_ttl(ver)
        ngx.log(ngx.DEBUG, " ver: ", ver, " ttl: ", ttl)

        dns:create_a_answer(query.qname, ttl, ver)

    end

end

local function _aaaa( key )
    -- AAAA
    --     tld|sub|view|type   value|ttl   set
    -- sadd aikaiyuan.com|ipv6|*|AAAA 2400:89c0:1022:657::152:150|86400 2400:89c0:1032:157::31:1201|86400

    local redis_value = getdns(key)
    ngx.log(ngx.DEBUG, "TYPE_AAAA key: ", key)

    for index, ver in ipairs(redis_value) do

        local ver, ttl, err = ver_and_ttl(ver)
        ngx.log(ngx.DEBUG, "index: ", index, " q: ",query.qname, " ver: ", ver, " ttl: ", ttl)

        dns:create_aaaa_answer(query.qname, ttl, ver)

    end

end

local function _mx( key )
    -- MX
    --     tld|sub|view|type   value|ttl   set
    -- sadd aikaiyuan.com|@|*|MX smtp1.qq.com.|720 smtp2.qq.com.|720

    local redis_value = getdns(key)
    ngx.log(ngx.DEBUG, "TYPE_MX key: ", key)

    for _, ver in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, "A: ", ver)

        local ver, ttl, err = ver_and_ttl(ver)
        ngx.log(ngx.DEBUG, " ver: ", ver, " ttl: ", ttl)

        dns:create_mx_answer(query.qname, ttl, ver)

    end

end

local function _txt( key )

    local redis_value = getdns(key)

    dns:create_txt_answer(query.qname, "999", "ttttttttt")

end

local function _ns( key )

    local redis_value = getdns(key)

    dns:create_ns_answer(query.qname, "999", "ns1.aikaiyuan.com")
    dns:create_ns_answer(query.qname, "999", "ns2.aikaiyuan.com")

end

local function _srv( key )

    local redis_value = getdns(key)

    dns:create_srv_answer(query.qname, "86400", "100", "100", "80", "www.aikaiyuan.com")

end

local function split(s, p)

    local r = {}
    gsub(s, '[^'..p..']+', function(w) table.insert(r, w) end )
    return r

end

local function issub( sub, tld, view, types )

    local new_sub = split(sub, "\\.")
    local key = tld .. "|" .. sub .. "|" .. view .. "|" .. types

    if #new_sub == 1 then

        return key, 0

    else

        for k, v in ipairs(new_sub) do
            new_sub[k] = "*"
            local x_sub = table.concat(new_sub,".", k )

            local key = tld .. "|" .. x_sub .. "|" .. view .. "|" .. types
            local testkey = existsdns(key)
            if testkey == 1 then
                return key, 1
            end
        end

    end

    return key, 0
end

local function result()
    -- return dns
    local resp = dns:encode_response()
    local ok, err = sock:send(resp)
    if not ok then
        ngx.log(ngx.ERR, "failed to send: ", err)
        return
    end

end



if query.qtype == server.TYPE_CNAME then

    local key = tld .. "|" .. sub .. "|" .. view .. "|"

    local testkey = existsdns(key .. "CNAME")
    if testkey == 1 then
        local res = _cname(key .. "CNAME")
        return result()
    end

    local new_key, num = issub(sub, tld, view, "CNAME")
    if num == 1 then
        local res = _cname(new_key)
        return result()
    end

    return result()

elseif query.qtype == server.TYPE_A then

    local key = tld .. "|" .. sub .. "|" .. view .. "|"

    local testkey = existsdns(key .. "A")
    if testkey == 1 then
        local res = _a(key .. "A")
        return result()
    end

    local new_key, num = issub(sub, tld, view, "A")
    if num == 1 then
        local res = _a(new_key)
        return result()
    end

    local testkey = existsdns(key .. "CNAME")
    if testkey == 1 then
        local res = _cname(key .. "CNAME")
        return result()
    end

    local new_key, num = issub(sub, tld, view, "CNAME")
    if num == 1 then
        local res = _cname(new_key)
        return result()
    end

    return result()

elseif  query.qtype == server.TYPE_AAAA then

    local key = tld .. "|" .. sub .. "|" .. view .. "|"
    local res = _aaaa(key)

elseif  query.qtype == server.TYPE_MX then

    local key = tld .. "|" .. sub .. "|" .. view .. "|"
    local res = _mx(key)

elseif  query.qtype == server.TYPE_TXT then

    local key = tld .. "|" .. sub .. "|" .. view .. "|"
    local res = _txt(key)

elseif  query.qtype == server.TYPE_NS then

    local key = tld .. "|" .. sub .. "|" .. view .. "|"
    local res = _ns(key)

elseif  query.qtype == server.TYPE_SRV then

    local key = tld .. "|" .. sub .. "|" .. view .. "|"
    local res = _srv(key)

else

    dns:create_soa_answer(tld, 600, "ns1.aikaiyuan.com.", "domain.aikaiyuan.com.", 1558348800, 1800, 900, 604800, 86400)

end





