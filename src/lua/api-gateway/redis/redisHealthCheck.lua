--
-- Created by IntelliJ IDEA.
-- User: nramaswa
-- Date: 4/17/14
-- Time: 7:38 PM
-- To change this template use File | Settings | File Templates.
--


-- Base class for redis health check to get the healthy node

local base = require "api-gateway.validation.base"

local HealthCheck = {}
local DEFAULT_SHARED_DICT = "cachedkeys"

function HealthCheck:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    if ( o ~= nil ) then
        self.shared_dict = o.shared_dict or DEFAULT_SHARED_DICT
    end
    return o
end

-- Reused from the "resty.upstream.healthcheck" module to get the
-- status of the upstream nodes
local function gen_peers_status_info(peers, bits, idx)
    local npeers = #peers
    for i = 1, npeers do
        local peer = peers[i]
        bits[idx] = peer.name
        if peer.down then
            bits[idx + 1] = " DOWN\n"
        else
            bits[idx + 1] = " up\n"
        end
        idx = idx + 2
    end
    return idx
end

-- Pass the name of any upstream for which the health check is performed by the
-- "resty.upstream.healthcheck" module. This is only to get the results of the healthcheck
local function getHealthCheckForUpstream(upstreamName)
    local ok, upstream = pcall(require, "ngx.upstream")
    if not ok then
        error("ngx_upstream_lua module required")
    end

    local get_primary_peers = upstream.get_primary_peers
    local get_backup_peers = upstream.get_backup_peers

    local ok, new_tab = pcall(require, "table.new")
    if not ok or type(new_tab) ~= "function" then
        new_tab = function (narr, nrec) return {} end
    end

    local n = 1
    local bits = new_tab(n * 20, 0)
    local idx = 1

        local peers, err = get_primary_peers(upstreamName)
        if not peers then
            return "failed to get primary peers in upstream " .. upstreamName .. ": "
                    .. err
        end

        idx = gen_peers_status_info(peers, bits, idx)

        peers, err = get_backup_peers(upstreamName)
        if not peers then
            return "failed to get backup peers in upstream " .. upstreamName .. ": "
                    .. err
        end

        idx = gen_peers_status_info(peers, bits, idx)

    return bits
end

local function getHealthyRedisNodeFromCache(dict_name)
    local dict = ngx.shared[dict_name];
    local upstreamRedis
    if ( nil ~= dict ) then
        upstreamRedis = dict:get("healthy_redis_upstream")
    end
    return upstreamRedis
end

local function updateHealthyRedisNodeInCache(dict_name, upstreamRedis)
    local dict = ngx.shared[dict_name];
    if ( nil ~= dict ) then
        dict:set("healthy_redis_upstream", upstreamRedis, 5)
    end
end

local function getHostAndPortInUpstream(upstreamRedis)
    local p = {}
    p.host = upstreamRedis

    local idx = string.find(upstreamRedis, ":", 1, true)
    if idx then
        p.host = string.sub(upstreamRedis, 1, idx - 1)
        p.port = tonumber(string.sub(upstreamRedis, idx + 1))
    end
    return p.host, p.port
end

-- Get the redis node to use for read.
-- Returns 3 values: <upstreamName , host, port >
-- The difference between upstream and <host,port> is that the upstream may be just a string containing host:port
function HealthCheck:getHealthyRedisNodeForRead()

    -- get the Redis host and port from the local cache first
    local redisToUse = getHealthyRedisNodeFromCache(self.shared_dict)
    if ( nil ~= redisToUse) then
        local host, port = getHostAndPortInUpstream(redisToUse)
        return redisToUse, host, port
    end

    -- if the Redis host is not in the local cache get it from the upstream configuration
    local redisUpstreamHealthResult = self:getRedisUpstreamHealthStatus()

    if(redisUpstreamHealthResult == nil) then
        ngx.log(ngx.ERR, "\n No upstream results found for redis!!! ")
        return nil
    end

    for key,value in ipairs(redisUpstreamHealthResult) do
        if(value == " up\n") then
            redisToUse = redisUpstreamHealthResult[key-1]
            updateHealthyRedisNodeInCache(self.shared_dict, redisToUse)
            local host, port = getHostAndPortInUpstream(redisToUse)
            return redisToUse, host, port
        end
        if(value == " DOWN\n" and redisUpstreamHealthResult[key-1] ~= nil ) then
            ngx.log(ngx.WARN, "\n Redis node " .. tostring(redisUpstreamHealthResult[key-1]) .. " is down! Checking for backup nodes. ")
        end
    end

    ngx.log(ngx.ERR, "\n All Redis nodes are down!!! ")
    return nil -- No redis nodes are up
end

-- To get the health check results on all the nodes defined in the redis upstream.
-- The health check is performed by a worker using "resty.upstream.healthcheck" module.
-- The name of the redis read only upstream is used here.
function HealthCheck:getRedisUpstreamHealthStatus()
    -- TODO: make the name of the upstream configurable for reuse
    local redisUpstreamStatus = getHealthCheckForUpstream("cache_read_only_backend")
    return redisUpstreamStatus;
end



return HealthCheck