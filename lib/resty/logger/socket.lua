-- Copyright (C) 2013 Jiale Zhi (calio), Cloudflare Inc.


local _G = _G
local tcp = ngx.socket.tcp


module("resty.logger.socket", package.seeall)

_VERSION = '0.01'

local  config = {
    buffer              = { size = 0, data = {} },
    flush_limit         = 4096,         -- 4KB
    drop_limit          = 1048576,      -- 1MB
    timeout             = 1000,         -- 1 sec
}


local function _connect()
    local ok, err, sock

    sock, err = tcp()
    if not sock then
        ngx.log(ngx.ERROR, err)
        return nil, err
    end


    config.connecting = true

    -- host/port and path config have already been checked in init()
    if config.host and config.port then
        ok, err =  sock:connect(config.host, config.port)
    elseif config.path then
        ok, err =  sock:connect(config.path)
    end

    if not ok then
        return nil, err
    end

    sock:settimeout(config.timeout)

    config.sock = sock
    config.connecting = false
    config.connected = true
    return true
end

local function _write_buffer(msg)
    local buf = config.buffer

    table.insert(buf.data, msg)
    buf.size = buf.size + string.len(msg)

    return buf.size
end

local function _flush()

    local ok, err = _connect()
    if not ok then
        ngx.log(ngx.ERR, err)
        return nil, err
    end

    local sock  = config.sock
    local buf   = config.buffer

    -- TODO If send failed, these logs would be lost
    local packet = table.concat(buf.data)
    for i, v in ipairs(buf.data) do
        buf.data[i] = nil
    end

    buf.size = 0

    local bytes, err = sock:send(packet)
    if not bytes then
        -- sock:send always close current connection on error
        config.connected = false
        ngx.log(ngx.ERR, err)
        return nil, err
    end


    config.flushing = false

    return sock:setkeepalive(0, 10)
    --return bytes
end

function init(user_config)
    if (type(user_config) ~= "table") then
        return nil, "user_config must be a table"
    end

    for k, v in pairs(user_config) do
        config[k] = v
    end

    if not (config.host and config.port) and not config.host then
        return nil, "no logging server configured. Need host/port or path."
    end


    if (config.flush_limit >= config.drop_limit) then
        return nil, "flush_limit should < drop_limit"
    end

    config.flushing = false
    config.connecting = false

    config.connected = false
    config.inited = true

    --ngx.timer.at(0, _connect)
    return config.inited
end

function log(msg)
    if not config.inited then
        return nil, "not initialized"
    end

    if (config.buffer.size + string.len(msg) > config.drop_limit) then
        return nil, "logger buffer is full, this log would be dropped"
    end

    local ok, err = _write_buffer(msg)
    if not ok then
        return nil, err
    end

    if (config.buffer.size > config.flush_limit and not config.flushing) then
        config.flushing = true
        ngx.timer.at(0, _flush)
    end

    return true
end
