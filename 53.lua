
local DEBUG = false

require 'resty.core.regex'

local bit    = require 'bit'
local re     = require "ngx.re"
local cjson  = require "cjson"
local redis  = require "redis_iresty"
local sipdb  = require "ngx.stream.ipdb"
local server = require 'resty.dns.server'

local ssub     = string.sub    -- yes
local strlower = string.lower -- 2.1
local byte     = string.byte
local char     = string.char
local find     = ngx.re.find
local sub      = ngx.re.sub
local split    = re.split
local utctime  = ngx.utctime

local lshift = bit.lshift
local rshift = bit.rshift
local band   = bit.band


local table_concat = table.concat   -- 2.1
local table_remove = table.remove   -- 2.1

local cjson_encode = cjson.encode
local cjson_decode = cjson.decode


local request_remote_addr = ngx.var.remote_addr



local _M = {
    _VERSION        = '1.2',
}

local mt = { __index = _M }

function _M.new(self, opts)

    local red = redis:new({
        host = opts.redis_host or "127.0.0.1",
        port = opts.redis_port or 6379,
        timeout = opts.redis_timeout or 60,
    })

    local _g = {

        sock        = nil,
        dns         = nil,
        request     = "",
        query       = "",
        view        = "",

        red         = red,
        tcp         = opts.tcp or nil,

        separator   = '/',
        request_remote_addr = request_remote_addr,
        eip                 = request_remote_addr,

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
            time      = utctime(),
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

    return setmetatable(_g, mt)

end

local function redis_exist_key( self, key )

    local ver, err = self.red:exists(key)
    return ver

end

local function dns_exist_key( self, keys )

    -- keys = {"aikaiyuan.com", "lb", "DX", "A"}
    local k = keys
    local view_tmp = k[3]
    local key = table_concat(k, self.separator)
    local value, err = cache:get("_exist_" .. key, nil, redis_exist_key, self, key)

    if value == 1 then
        return key, value
    else
        k[3] = "*"
        local key = table_concat(k, self.separator)
        local value, err = cache:get("_exist_" .. key, nil, redis_exist_key, self, key)
        k[3] = view_tmp

        return key, value
    end

end



local function redis_get_key( self, key )

    local ver, err = self.red:get(key)
    return cjson_encode(ver)

end

local function dns_get_key( self, key )

    self.log.redis_key = key
    local value, err = cache:get(key, nil, redis_get_key, self, key)
    return cjson_decode(value), _

end

local function redis_smembers_key( self, key )

    local ver, err = self.red:smembers(key)
    return cjson_encode(ver)

end

local function dns_smembers_key( self, key )

    self.log.redis_key = key
    local value, err = cache:get(key, nil, redis_smembers_key, self, key)
    return cjson_decode(value), _

end

local function findsub( self, key )

    -- keys = {"aikaiyuan.com", "lb", "DX", "A"}
    local sub = split(key[2], "\\.")
    if #sub == 1 then
        return key, 0
    end

    for index, _ in ipairs(sub) do
        sub[index] = "*"
        key[2] = table_concat(sub, ".", index)

        local new_key, num = dns_exist_key(self, key)
        if num == 1 then
            return new_key, num
        end
    end

    return key, 0

end

function _M.server_udp(self)

    local sock, err = ngx.req.socket()
    if not sock then
        ngx.log(ngx.ERR, "failed to get the request socket: ", err)
        return ngx.exit(ngx.ERROR)
    end
    self.sock = sock

    local req, err = sock:receive()
    if not req then
        ngx.log(ngx.ERR, "failed to receive: ", err)
        return ngx.exit(ngx.ERROR)
    end

    self.dns = server:new()

    local request, err = self.dns:decode_request(req)
    if not request then
        ngx.log(ngx.ERR, "failed to decode request: ", err)
        return ngx.exit(ngx.ERROR)
    end
    self.request = request

    return _

end


function _M.server_tcp(self)

    local sock, err = ngx.req.socket()
    if not sock then
        ngx.log(ngx.ERR, "failed to get the request socket: ", err)
        return ngx.exit(ngx.ERROR)
    end
    self.sock = sock

    local req, err = sock:receive(2)
    if not req then
        ngx.log(ngx.ERR, "failed to receive: ", err)
        return ngx.exit(ngx.ERROR)
    end

    local len_hi = byte(req, 1)
    local len_lo = byte(req, 2)
    local len = lshift(len_hi, 8) + len_lo
    local data, err = sock:receive(len)
    if not data then
        ngx.log(ngx.ERR, "failed to receive: ", err)
        return ngx.exit(ngx.ERROR)
    end

    self.dns = server:new()

    local request, err = self.dns:decode_request(data)
    if not request then
        ngx.log(ngx.ERR, "failed to decode request: ", err)
        return err
    end
    self.request = request

    return _

end


local function result(self)

    local nsort = 0
    for _, data in ipairs(self.log_sort) do
        nsort = nsort + 1
        self.logs[nsort] = self.log[data]
    end
    ngx.ctx.log = table_concat(self.logs, " ")
    ngx.log(ngx.DEBUG, "query log: ", ngx.ctx.log)

    local resp = self.dns:encode_response()

    if self.tcp then
        local len    = #resp
        local len_hi = char(rshift(len, 8))
        local len_lo = char(band(len, 0xff))

        local ok, err = self.sock:send({len_hi, len_lo, resp})
    else
        local ok, err = self.sock:send(resp)
    end

end

function _M.sub_tld(self)

    local query = self.request.questions
    if #query == 1 then
        self.query = query[1]
    else
        return "failed to query"
    end
    local qname = strlower(self.query.qname)

    local subnet = self.request.subnet
    if subnet and #subnet == 1 then
        self.eip = subnet[1].address or request_remote_addr
    end

    ngx.log(ngx.DEBUG, " qname: ", qname, " qclass: ", self.query.qclass,
            " qtype: ", self.query.qtype,  " ngx.var.remote_addr: ", request_remote_addr,
            " subnet.ipaddr: ", self.eip
    )

    self.key["qtype"] = _G.DNSTYPES[self.query.qtype] or "SOA"

    local m, _, err = find(qname, _G.zone, "ijo")
    if m then
        if m == 1 then
            self.key["sub"] = "@"
            self.key["tld"] = qname
        else
            self.key["sub"] = ssub(qname, 1, m - 2)
            self.key["tld"] = ssub(qname, m, -1)
        end
        ngx.log(ngx.DEBUG, "sub: ", self.key["sub"])
        ngx.log(ngx.DEBUG, "tld: ", self.key["tld"])
    else
        ngx.log(ngx.DEBUG, "not find tld: ", err)
        ngx.log(ngx.DEBUG, "self.zone: ", _G.zone)
        return err
    end

    self.log.subnet_ip = self.eip
    self.log.domain    = self.query.qname
    self.log.tld       = self.key.tld
    self.log.sub       = self.key.sub
    self.log.qtype     = self.key.qtype

    return _

end

function _M.ip_to_isp (self)

    local view = ""
    ngx.log(ngx.DEBUG, "self.eip: ", self.eip)
    local raw = sipdb.get_raw(self.eip)
    ngx.log(ngx.DEBUG, "raw: ", raw)
    local ipdb = split(raw, '\t')

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

    self.key["view"] = view
    self.log.view = view

    return _

end

------------------------------------------------------------------

local function _cname( self, key )
    -- CNAME
    --     tld/sub/view/type   value/ttl
    -- sadd aikaiyuan.com/www/*/CNAME   aikaiyuan.appchizi.com./3600

    local redis_value = dns_smembers_key(self, key)
    ngx.log(ngx.DEBUG, "_cname key: ", key)

    for _, data in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, self.key.qtype, " ", data)

        local info  = split(data, self.separator)
        local value = info[1]
        local ttl   = info[2]
        ngx.log(ngx.DEBUG, "value: ", value, " ttl: ", ttl)

        -- create_cname_answer(self, name, ttl, cname)
        self.dns:create_cname_answer(self.query.qname, ttl, value)
    end

end




local function cname(self)

    local key, num = dns_exist_key(self, self.keys)
    if num == 1 then
        local res = _cname(self, key)
        return result(self)
    end

    local key, num = findsub(self, self.keys)
    if num == 1 then
        local res = _cname(self, key)
        return result(self)
    end

    return result(self)

end

local function _a( self, key )
    -- A
    --     tld/sub/view/type   value/ttl
    -- sadd aikaiyuan.com/lb/*/A 220.181.136.165/3600 220.181.136.166/3600

    local redis_value = dns_smembers_key(self, key)
    ngx.log(ngx.DEBUG, "_a key: ", key)

    for _, data in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, self.key.qtype, " ", data)

        local info  = split(data, self.separator)
        local value = info[1]
        local ttl   = info[2]
        ngx.log(ngx.DEBUG, "value: ", value, " ttl: ", ttl)

        -- create_a_answer(self, name, ttl, ipv4)
        self.dns:create_a_answer(self.query.qname, ttl, value)
    end

end

local function a(self)

    local key, num = dns_exist_key(self, self.keys)
    if num == 1 then
        local res = _a(self, key)
        return result(self)
    end

    local key, num = findsub(self, self.keys)
    if num == 1 then
        local res = _a(self, key)
        return result(self)
    end

    self.keys[4] = "CNAME"
    return cname(self)

end

local function _full_aaaa(self, ipv6)

    local n = split(ipv6, ':')
    return sub(ipv6, "::", table_concat(self.ipv6[#n], "0"))

end

local function _aaaa( self, key )
    -- AAAA
    --     tld/sub/view/type   value/ttl
    -- sadd aikaiyuan.com/ipv6/*/AAAA 2400:89c0:1022:657::152:150/86400 2400:89c0:1032:157::31:1201/86400

    local redis_value = dns_smembers_key(self, key)
    ngx.log(ngx.DEBUG, "_aaaa key: ", key)

    for _, data in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, self.key.qtype, " ", data)

        local info  = split(data, self.separator)
        local value = info[1]
        if find(value, '::') then
            value = _full_aaaa(self, value)
        end
        local ttl   = info[2]
        ngx.log(ngx.DEBUG, "value: ", value, " ttl: ", ttl)

        -- create_aaaa_answer(self, name, ttl, ipv6)
        self.dns:create_aaaa_answer(self.query.qname, ttl, value)
    end

end

local function aaaa(self)

    local key, num = dns_exist_key(self, self.keys)
    if num == 1 then
        local res = _aaaa(self, key)
        return result(self)
    end

    local key, num = findsub(self, self.keys)
    if num == 1 then
        local res = _aaaa(self, key)
        return result(self)
    end

    return result(self)

end

local function _ns( self, key )
    -- NS
    --     tld/sub/view/type   value/ttl
    -- sadd aikaiyuan.com/ns/*/NS ns10.aikaiyuan.com./86400

    local redis_value = dns_smembers_key(self, key)
    ngx.log(ngx.DEBUG, "_ns key: ", key)

    for _, data in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, self.key.qtype, " ", data)

        local info  = split(data, self.separator)
        local value = info[1]
        local ttl   = info[2]
        ngx.log(ngx.DEBUG, "value: ", value, " ttl: ", ttl)

        -- create_ns_answer(self, name, ttl, nsdname)
        self.dns:create_ns_answer(self.query.qname, ttl, value)
    end

end

local function ns(self)

    local key, num = dns_exist_key(self, self.keys)
    if num == 1 then
        local res = _ns(self, key)
        return result(self)
    end

    local key, num = findsub(self, self.keys)
    if num == 1 then
        local res = _ns(self, key)
        return result(self)
    end

    return result(self)

end

local function soa(self)

    local key = self.key.tld .. "/SOA"

    local value, err = cache:get("_exist_" .. key, nil, redis_exist_key, self, key)
    if value == 1 then
        local redis_value = dns_get_key(self, key)
        ngx.log(ngx.DEBUG, "soa key: ", key)

        local info  = split(redis_value, self.separator)
        local mname = info[1]
        local rname = info[2]
        local serial = info[3]
        local refresh = info[4]
        local retry = info[5]
        local expire = info[6]
        local minimum = info[7]
        local ttl = info[8]

        ngx.log(ngx.DEBUG, "value: ", redis_value, " ttl: ", ttl)

        -- function _M.create_soa_answer(self, name, ttl, mname, rname, serial, refresh, retry, expire, minimum)
        self.dns:create_soa_answer(self.key.tld, ttl, mname, rname,
                        serial, refresh, retry, expire, minimum)

    else
        self.dns:create_soa_answer(self.key.tld, 600, key, key,
                          1558348800, 1800, 900, 604800, 86400)
    end

    return result(self)

end

local function ptr( k, t )
    -- TODO
end

local function _mx( self, key )
    -- MX
    --     tld/sub/view/type   value/ttl/preference
    -- sadd aikaiyuan.com/@/*/MX smtp1.qq.com./720/10 smtp2.qq.com./720/10

    local redis_value = dns_smembers_key(self, key)
    ngx.log(ngx.DEBUG, "_mx key: ", key)

    for _, data in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, self.key.qtype, " ", data)

        local info  = split(data, self.separator)
        local value = info[1]
        local ttl   = info[2]
        local preference = info[3]

        ngx.log(ngx.DEBUG, "value: ", value, " ttl: ", ttl, " preference: ", preference)

        -- create_mx_answer(self, name, ttl, preference, exchange)
        self.dns:create_mx_answer(self.query.qname, ttl, preference, value)
    end

end

local function mx(self)

    local key, num = dns_exist_key(self, self.keys)
    if num == 1 then
        local res = _mx(self, key)
        return result(self)
    end

    local key, num = findsub(self, self.keys)
    if num == 1 then
        local res = _mx(self, key)
        return result(self)
    end

    return result(self)

end

local function _txt( self, key )
    -- TXT
    --     tld/sub/view/type   value/ttl
    -- sadd aikaiyuan.com/txt/*/TXT txt.aikaiyuan.com/1200

    local redis_value = dns_smembers_key(self, key)
    ngx.log(ngx.DEBUG, "_txt key: ", key)

    for _, data in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, self.key.qtype, " ", data)

        local info  = split(data, self.separator)
        local value = info[1]
        local ttl   = info[2]
        ngx.log(ngx.DEBUG, "value: ", value, " ttl: ", ttl)

        -- create_txt_answer(self, name, ttl, txt)
        self.dns:create_txt_answer(self.query.qname, ttl, value)
    end

end

local function txt(self)

    local key, num = dns_exist_key(self, self.keys)
    if num == 1 then
        local res = _txt(self, key)
        return result(self)
    end

    local key, num = findsub(self, self.keys)
    if num == 1 then
        local res = _txt(self, key)
        return result(self)
    end

    return result(self)

end

local function _srv( self, key )
    -- SRV
    --     tld/sub/view/type   priority/weight/port/value/ttl
    -- sadd aikaiyuan.com/srv/*/SRV 1/100/800/www.aikaiyuan.com/120

    local redis_value = dns_smembers_key(self, key)
    ngx.log(ngx.DEBUG, "_srv key: ", key)

    for _, data in ipairs(redis_value) do
        ngx.log(ngx.DEBUG, self.key.qtype, " ", data)

        local info     = split(data, self.separator)
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
        self.dns:create_srv_answer(self.query.qname, ttl, priority, weight, port, value)
    end

end

local function srv(self)

    local key, num = dns_exist_key(self, self.keys)
    if num == 1 then
        local res = _srv(self, key)
        return result(self)
    end

    return result(self)

end

local function spf()
    -- TODO
end

local function any(self)

    self.keys[4] = "CNAME"
    _cname(self, table_concat(self.keys, self.separator))

    self.keys[4] = "A"
    _a(self, table_concat(self.keys, self.separator))

    self.keys[4] = "AAAA"
    _aaaa(self, table_concat(self.keys, self.separator))

    self.keys[4] = "NS"
    _ns(self, table_concat(self.keys, self.separator))

    self.keys[4] = "SRV"
    _srv(self, table_concat(self.keys, self.separator))

    self.keys[4] = "MX"
    _mx(self, table_concat(self.keys, self.separator))

    self.keys[4] = "TXT"
    _txt(self, table_concat(self.keys, self.separator))

    return result(self)

end

local main = {
    A     = function(self) return a(self)       end,  -- 1
    NS    = function(self) return ns(self)      end,  -- 2
    CNAME = function(self) return cname(self)   end,  -- 5
    SOA   = function(self) return soa(self)     end,  -- 6
    PTR   = function(self) return ptr(self)     end,  -- 12 TODO
    MX    = function(self) return mx(self)      end,  -- 15
    TXT   = function(self) return txt(self)     end,  -- 16
    AAAA  = function(self) return aaaa(self)    end,  -- 28
    SRV   = function(self) return srv(self)     end,  -- 33
    SPF   = function(self) return spf(self)     end,  -- 99 TODO
    ANY   = function(self) return any(self)     end,  -- 255
}

function _M.run_udp(self)

    local err = _M.server_udp(self)
    if err then
        ngx.log(ngx.ERR, "failed to dnsserver: ", err)
        return ngx.exit(ngx.ERROR)
    end


    local err = _M.sub_tld(self)
    if not err then
        ngx.log(ngx.ERR, "failed to sub_tld: ", err, ":")
        return result()
    end

    local err = _M.ip_to_isp(self)
    if err then
        ngx.log(ngx.ERR, "failed to ip_to_isp: ", err)
        return result()
    end

    local nkeys = 0
    for _, data in ipairs(self.key_sort) do
        nkeys = nkeys + 1
        self.keys[nkeys] = self.key[data]
    end

    main[self.key.qtype](self)

end

function _M.run_tcp(self)

    local err = _M.server_tcp(self)
    if err then
        ngx.log(ngx.ERR, "failed to dnsserver: ", err)
        return ngx.exit(ngx.ERROR)
    end


    local err = _M.sub_tld(self)
    if not err then
        ngx.log(ngx.ERR, "failed to sub_tld:  11111:", err, ":")
        return result()
    end

    local err = _M.ip_to_isp(self)
    if err then
        ngx.log(ngx.ERR, "failed to ip_to_isp: ", err)
        return result()
    end

    local nkeys = 0
    for _, data in ipairs(self.key_sort) do
        nkeys = nkeys + 1
        self.keys[nkeys] = self.key[data]
    end

    main[self.key.qtype](self)

end

return _M






