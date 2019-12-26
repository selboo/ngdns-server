
local DEBUG = false

require 'resty.core.regex'

local re     = require "ngx.re"
local cjson  = require "cjson"
local redis  = require "resty.redis"
local sipdb  = require "ngx.stream.ipdb"
local server = require 'resty.dns.server'

local ssub    = string.sub    -- yes
local strlen  = string.len    -- yes
local strfind = string.find   -- 2.1 partial Only fixed string searches (no patterns).
local strlower = string.lower -- 2.1
local find    = ngx.re.find
local sub     = ngx.re.sub

local table_insert = table.insert   -- no
local table_concat = table.concat   -- 2.1
local table_remove = table.remove   -- 2.1


local cjson_encode = cjson.encode
local cjson_decode = cjson.decode

local dns = server:new()
local red = redis:new()
red:set_timeout(3000)


local request_remote_addr = ngx.var.remote_addr

local _g = {
    _VERSION    = '0.01',

    sock        = nil,
    req         = "",
    request     = "",
    query       = "",

    separator   = '/',
    request_remote_addr = request_remote_addr,
    eip         = "",
    view        = "",

    -- time client_ip subnet_ip domain tld sub view qtype redis_key
    log_sort = {
        [1] = "time",
        [2] = "client_ip",
        [3] = "subnet_ip",
        [4] = "domain",
        [5] = "tld",
        [6] = "sub",
        [7] = "view",
        [8] = "qtype",
        [9] = "redis_key"
    },

    log = {
        time      = os.date("%Y-%m-%d %H:%M:%S", os.time()),
        client_ip = request_remote_addr,
        subnet_ip = "_",
        domain    = "_",
        tld       = "_",
        sub       = "_",
        view      = "_",
        qtype     = "_",
        redis_key = "_"
    },

    logs = {},

    key_sort = {
        [1] = "tld",
        [2] = "sub",
        [3] = "view",
        [4] = "qtype"
    },

    key = {
        tld = "_",
        sub = "_",
        view = "_",
        qtype = "_"
    },

    keys = {},

    ipv6 = {
        [9] = {":"},
        [8] = {":",":"},
        [7] = {":",":",":"},
        [6] = {":",":",":",":"},
        [5] = {":",":",":",":",":"},
        [4] = {":",":",":",":",":",":"},
        [3] = {":",":",":",":",":",":",":"},
        [2] = {":",":",":",":",":",":",":",":"},
    }

}

local function redisconnect()

    local ok, err = red:connect(_G.redis_host, _G.redis_port)
    if not ok then
        ngx.log(ngx.ERR, "1003 connect redis fail: ", err)
        return false, err
    end

    return red, _

end

local function redis_exist_key( key )

    local red , err = redisconnect()
    local ver, err = red:exists(key)
    return ver

end

local function dns_exist_key( k )

    -- _g.keys = {"aikaiyuan.com", "lb", "DX", "A"}
    local view_tmp = k[3]
    local key = table_concat(k, _g.separator)
    local value, err = cache:get("_exist_" .. key, nil, redis_exist_key, key)

    if value == 1 then
        return key, value
    else
        k[3] = "*"
        local key = table_concat(k, _g.separator)
        local value, err = cache:get("_exist_" .. key, nil, redis_exist_key, key)
        k[3] = view_tmp

        return key, value
    end

end

local function redis_get_key( key )

    local red , err = redisconnect()
    local ver, err = red:smembers(key)
    return cjson_encode(ver)

end

local function dns_get_key( key )

    _g.log.redis_key = key
    local value, err = cache:get(key, nil, redis_get_key, key)
    return cjson_decode(value), _

end

local function findsub( key )

    -- keys = {"aikaiyuan.com", "lb", "DX", "A"}
    local sub = re.split(key[2], "\\.")
    if #sub == 1 then
        return key, 0
    end

    for k, v in ipairs(sub) do
        sub[k] = "*"
        key[2] = table_concat(sub, ".", k)

        local new_key, num = dns_exist_key(key)
        if num == 1 then
            return new_key, num
        end
    end

    return key, 0

end

local function dnsserver()

    local sock, err = ngx.req.socket()
    if not sock then
        ngx.log(ngx.ERR, "failed to get the request socket: ", err)
        return err
    end
    _g.sock = sock

    local req, err = _g.sock:receive()
    if not req then
        ngx.log(ngx.ERR, "failed to receive: ", err)
        return err
    end
    _g.req = req

    local request, err = dns:decode_request(_g.req)
    if not request then
        ngx.log(ngx.ERR, "failed to decode request: ", err)
        return err
    end
    _g.request = request

    return _

end

local function result()

    for k, v in pairs(_g.log_sort) do
        table_insert(_g.logs, _g.log[v])
    end
    ngx.ctx.log = table_concat(_g.logs, " ")
    ngx.log(ngx.DEBUG, "query log: ", ngx.ctx.log)

    local resp = dns:encode_response()
    local ok, err = _g.sock:send(resp)

    if not ok then
        ngx.log(ngx.ERR, "failed to send: ", err)
        return
    end

end

local function sub_tld()

    local query = _g.request.questions
    if #query == 1 then
        _g.query = query[1]
    else
        return "failed to query"
    end
    local qname = strlower(_g.query.qname)

    _g.eip = _g.request.subnet[1].address or request_remote_addr

    ngx.log(ngx.DEBUG, " qname: ", qname, " qclass: ", _g.query.qclass,
            " qtype: ", _g.query.qtype,  " ngx.var.remote_addr: ", request_remote_addr,
            " subnet.ipaddr: ", _g.eip
    )

    _g.key["qtype"] = _G.DNSTYPES[_g.query.qtype] or "SOA"

    local m, _, err = find(qname, _G.zone, "ijo")
    if m then
        if m == 1 then
            _g.key["sub"] = "@"
            _g.key["tld"] = qname
        else
            _g.key["sub"] = ssub(qname, 1, m - 2)
            _g.key["tld"] = ssub(qname, m, -1)
        end
        ngx.log(ngx.DEBUG, "sub: ", _g.key["sub"])
        ngx.log(ngx.DEBUG, "tld: ", _g.key["tld"])
    else
        ngx.log(ngx.DEBUG, "not find tld: ", err)
        ngx.log(ngx.DEBUG, "_G.zone: ", _G.zone)
        return err
    end

    _g.log.subnet_ip = _g.eip
    _g.log.domain    = _g.query.qname
    _g.log.tld       = _g.key.tld
    _g.log.sub       = _g.key.sub
    _g.log.qtype     = _g.key.qtype

    return _

end

local function ip_to_isp ()

    local view = ""
    ngx.log(ngx.DEBUG, "_g.eip: ", _g.eip)
    local raw = sipdb.get_raw(_g.eip)
    ngx.log(ngx.DEBUG, "raw: ", raw)
    local ipdb = re.split(raw, '\t')

    local country_name = ipdb[1]
    local region_name  = ipdb[2]
    -- local city_name    = ipdb[3]
    -- local owner_domain = ipdb[4]
    local isp_domain   = ipdb[5]
    ngx.log(ngx.DEBUG, "country_name: ", country_name)
    ngx.log(ngx.DEBUG, "region_name: ", region_name)
    ngx.log(ngx.DEBUG, "isp_domain: ", isp_domain)

    if country_name == "中国" then
        view = _G.VIEWS[isp_domain] or "*"
    elseif region_name == "局域网" then
        view = "JYW"
    else
        view = "HW"
    end

    _g.key["view"] = view
    _g.log.view = view

    return _

end

------------------------------------------------------------------

local function _cname( key )
    -- CNAME
    --     tld|sub|view|type   value|ttl
    -- sadd aikaiyuan.com|www|*|CNAME   aikaiyuan.appchizi.com.|3600

    local redis_value = dns_get_key(key)
    ngx.log(ngx.DEBUG, "_cname key: ", key)

    for _, data in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, _g.key.qtype, " ", data)

        local info  = re.split(data, _g.separator)
        local value = info[1]
        local ttl   = info[2]
        ngx.log(ngx.DEBUG, "value: ", value, " ttl: ", ttl)

        -- create_cname_answer(self, name, ttl, cname)
        dns:create_cname_answer(_g.query.qname, ttl, value)
    end

end

local function cname()

    local key, num = dns_exist_key(_g.keys)
    if num == 1 then
        local res = _cname(key)
        return result()
    end

    local key, num = findsub(_g.keys)
    if num == 1 then
        local res = _cname(key)
        return result()
    end

    return result()

end

local function _a( key )
    -- A
    --     tld|sub|view|type   value|ttl
    -- sadd aikaiyuan.com|lb|*|A 220.181.136.165|3600 220.181.136.166|3600

    local redis_value = dns_get_key(key)
    ngx.log(ngx.DEBUG, "_a key: ", key)

    for _, data in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, _g.key.qtype, " ", data)

        local info  = re.split(data, _g.separator)
        local value = info[1]
        local ttl   = info[2]
        ngx.log(ngx.DEBUG, "value: ", value, " ttl: ", ttl)

        -- create_a_answer(self, name, ttl, ipv4)
        dns:create_a_answer(_g.query.qname, ttl, value)
    end

end

local function a()

    local key, num = dns_exist_key(_g.keys)
    if num == 1 then
        local res = _a(key)
        return result()
    end

    local key, num = findsub(_g.keys)
    if num == 1 then
        local res = _a(key)
        return result()
    end

    _g.keys[4] = "CNAME"
    return cname()

end

local function _full_aaaa(ipv6)

    local n = re.split(ipv6, ':')
    return sub(ipv6, "::", table_concat(_g.ipv6[#n], "0"))

end

local function _aaaa( key )
    -- AAAA
    --     tld|sub|view|type   value|ttl
    -- sadd aikaiyuan.com|ipv6|*|AAAA 2400:89c0:1022:657::152:150|86400 2400:89c0:1032:157::31:1201|86400

    local redis_value = dns_get_key(key)
    ngx.log(ngx.DEBUG, "_aaaa key: ", key)

    for _, data in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, _g.key.qtype, " ", data)

        local info  = re.split(data, _g.separator)
        local value = info[1]
        if find(value, '::') then
            value = _full_aaaa(value)
        end
        local ttl   = info[2]
        ngx.log(ngx.DEBUG, "value: ", value, " ttl: ", ttl)

        -- create_aaaa_answer(self, name, ttl, ipv6)
        dns:create_aaaa_answer(_g.query.qname, ttl, value)
    end

end

local function aaaa()

    local key, num = dns_exist_key(_g.keys)
    if num == 1 then
        local res = _aaaa(key)
        return result()
    end

    local key, num = findsub(_g.keys)
    if num == 1 then
        local res = _aaaa(key)
        return result()
    end

    return result()

end

local function _ns( key )
    -- NS
    --     tld|sub|view|type   value|ttl
    -- sadd aikaiyuan.com|ns|*|NS ns10.aikaiyuan.com.|86400

    local redis_value = dns_get_key(key)
    ngx.log(ngx.DEBUG, "_ns key: ", key)

    for _, data in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, _g.key.qtype, " ", data)

        local info  = re.split(data, _g.separator)
        local value = info[1]
        local ttl   = info[2]
        ngx.log(ngx.DEBUG, "value: ", value, " ttl: ", ttl)

        -- create_ns_answer(self, name, ttl, nsdname)
        dns:create_ns_answer(_g.query.qname, ttl, value)
    end

end

local function ns()

    local key, num = dns_exist_key(_g.keys)
    if num == 1 then
        local res = _ns(key)
        return result()
    end

    local key, num = findsub(_g.keys)
    if num == 1 then
        local res = _ns(key)
        return result()
    end

    return result()

end

local function soa()

    ngx.log(ngx.DEBUG, "function SOA, ")

    dns:create_soa_answer(tld, 600, "ns1.aikaiyuan.com.", "domain.aikaiyuan.com.",
                          1558348800, 1800, 900, 604800, 86400)
    return result()

end

local function ptr( k, t )
    -- TODO
end

local function _mx( key )
    -- MX
    --     tld|sub|view|type   value|ttl|preference
    -- sadd aikaiyuan.com|@|*|MX smtp1.qq.com.|720|10 smtp2.qq.com.|720|10

    local redis_value = dns_get_key(key)
    ngx.log(ngx.DEBUG, "_mx key: ", key)

    for _, data in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, _g.key.qtype, " ", data)

        local info  = re.split(data, _g.separator)
        local value = info[1]
        local ttl   = info[2]
        local preference = info[3]

        ngx.log(ngx.DEBUG, "value: ", value, " ttl: ", ttl, " preference: ", preference)

        -- create_mx_answer(self, name, ttl, preference, exchange)
        dns:create_mx_answer(_g.query.qname, ttl, preference, value)
    end

end

local function mx()

    local key, num = dns_exist_key(_g.keys)
    if num == 1 then
        local res = _mx(key)
        return result()
    end

    local key, num = findsub(_g.keys)
    if num == 1 then
        local res = _mx(key)
        return result()
    end

    return result()
end

local function _txt( key )
    -- TXT
    --     tld|sub|view|type   value|ttl
    -- sadd aikaiyuan.com|txt|*|TXT txt.aikaiyuan.com|1200

    local redis_value = dns_get_key(key)
    ngx.log(ngx.DEBUG, "_txt key: ", key)

    for _, data in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, _g.key.qtype, " ", data)

        local info  = re.split(data, _g.separator)
        local value = info[1]
        local ttl   = info[2]
        ngx.log(ngx.DEBUG, "value: ", value, " ttl: ", ttl)

        -- create_txt_answer(self, name, ttl, txt)
        dns:create_txt_answer(_g.query.qname, ttl, value)
    end

end

local function txt()

    local key, num = dns_exist_key(_g.keys)
    if num == 1 then
        local res = _txt(key)
        return result()
    end

    local key, num = findsub(_g.keys)
    if num == 1 then
        local res = _txt(key)
        return result()
    end

    return result()

end

local function _srv( key )
    -- SRV
    --     tld|sub|view|type   priority|weight|port|value|ttl
    -- sadd aikaiyuan.com|srv|*|SRV 1|100|800|www.aikaiyuan.com|120

    local redis_value = dns_get_key(key)
    ngx.log(ngx.DEBUG, "_srv key: ", key)

    for _, data in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, _g.key.qtype, " ", data)

        local info     = re.split(data, _g.separator)
        local priority = info[1]
        local weight   = info[2]
        local port     = info[3]
        local value    = info[4]
        local ttl      = info[5]
        ngx.log(ngx.DEBUG, "priority: ", priority, " weight: ", weight, 
                " port: ", port, " value: ", value,  
                " ttl: ", ttl
        )

        -- create_srv_answer(self, name, ttl, priority, weight, port, target)
        dns:create_srv_answer(_g.query.qname, ttl, priority, weight, port, value)
    end

end

local function srv()

    local key, num = dns_exist_key(_g.keys)
    if num == 1 then
        local res = _srv(key)
        return result()
    end

    return result()

end

local function spf()
    -- TODO
end

local function any()

    _g.keys[4] = "CNAME"
    _cname(table_concat(_g.keys, _g.separator))

    _g.keys[4] = "A"
    _a(table_concat(_g.keys, _g.separator))

    _g.keys[4] = "AAAA"
    _aaaa(table_concat(_g.keys, _g.separator))

    _g.keys[4] = "NS"
    _ns(table_concat(_g.keys, _g.separator))

    _g.keys[4] = "SRV"
    _srv(table_concat(_g.keys, _g.separator))

    _g.keys[4] = "MX"
    _mx(table_concat(_g.keys, _g.separator))

    _g.keys[4] = "TXT"
    _txt(table_concat(_g.keys, _g.separator))

    return result()

end

local main = {
    A     = function() return a()       end,  -- 1
    NS    = function() return ns()      end,  -- 2
    CNAME = function() return cname()   end,  -- 5
    SOA   = function() return soa()     end,  -- 6
    PTR   = function() return ptr()     end,  -- 12 TODO
    MX    = function() return mx()      end,  -- 15
    TXT   = function() return txt()     end,  -- 16
    AAAA  = function() return aaaa()    end,  -- 28
    SRV   = function() return srv()     end,  -- 33
    SPF   = function() return spf()     end,  -- 99 TODO
    ANY   = function() return any()     end,  -- 255
}

local err = dnsserver()
if err then
    ngx.log(ngx.ERR, "failed to dnsserver: ", err)
    return ngx.exit(ngx.ERROR)
end

local err = sub_tld()
if not err then
    ngx.log(ngx.ERR, "failed to sub_tld:  11111:", err, ":")
    return result()
end

local err = ip_to_isp()
if err then
    ngx.log(ngx.ERR, "failed to ip_to_isp: ", err)
    return result()
end

-- _g.keys = {tld,              sub, view, qtype}
-- _g.keys = {"aikaiyuan.com", "lb", "DX", "A"}
for index, data in ipairs(_g.key_sort) do
    table_insert(_g.keys, _g.key[data])
end

main[_g.key.qtype]()






