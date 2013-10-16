-- Copyright (C) 2013 Jiale Zhi (calio), Cloudflare Inc.


local tcp = ngx.socket.tcp
local timer_at = ngx.timer.at
local ngx_log = ngx.log

local _M = {}


_M._VERSION = '0.01'

local buffer                = { size = 0, data = {}, index = 0 }
local flush_limit           = 4096         -- 4KB
local drop_limit            = 1048576      -- 1MB
local timeout               = 1000         -- 1 sec
local flush_interval        = 60           -- 5 sec
local host
local port
local path

local connecting
local connected
local flushing
local inited
local sock


local function _connect()
    local ok, err

    if not connected then
        sock, err = tcp()
        if not sock then
            ngx_log(ngx.ERROR, err)
            return nil, err
        end

        sock:settimeout(timeout)
    end

    connecting = true

    ngx.log(ngx.NOTICE, "_connect started")
    -- host/port and path config have already been checked in init()
    if host and port then
        ok, err =  sock:connect(host, port)
    elseif path then
        ok, err =  sock:connect(path)
    end

    if not ok then
        return nil, err
    end

    ngx.log(ngx.NOTICE, "_connect connected")

    connecting = false
    connected = true
    return true
end

local function _write_buffer(msg)
    local buf = buffer
    local string_msg = msg

    if type(msg) ~= "string" then
        string_msg = tostring(msg)
    end

    table.insert(buf.data, string_msg)
    buf.size = buf.size + #string_msg

    return buf.size
end

local function _do_flush()
    local ok, err = _connect()
    if not ok then
        ngx_log(ngx.ERR, err)
        return nil, err
    end

    local buf   = buffer

    -- TODO If send failed, these logs would be lost
    local packet = table.concat(buf.data)
    for i, v in ipairs(buf.data) do
        buf.data[i] = nil
    end

    buf.size = 0

    ngx.log(ngx.NOTICE, "_flush:", packet)
    local bytes, err = sock:send(packet)
    if not bytes then
        -- sock:send always close current connection on error
        connected = false
        ngx_log(ngx.ERR, err)
        return nil, err
    end
    ngx.log(ngx.NOTICE, "flush ok")
end

local function _flush()
    ngx.log(ngx.NOTICE, "_flush")
    if flushing then
        -- do this later
        ngx.log(ngx.NOTICE, "_flush later")
        ngx.timer.at(flush_interval, _flush)
        return true
    end

    flushing = true
    local ok, err = _do_flush()
    if not ok then
        return nil, err
    end


    sock:setkeepalive(0, 10)
    flushing = false
    return true
end

function _M.init(user_config)
    if (type(user_config) ~= "table") then
        return nil, "user_config must be a table"
    end

    for k, v in pairs(user_config) do
        if k == "host" then
            host = v
        elseif k == "port" then
            port = v
        elseif k == "path" then
            path = v
        elseif k == "flush_limit" then
            flush_limit = v
        elseif k == "drop_limit" then
            drop_limit = v
        elseif k == "timeout" then
            timeout = v
        end
    end

    if not (host and port) and not host then
        return nil, "no logging server configured. Need host/port or path."
    end


    if (flush_limit >= drop_limit) then
        return nil, "flush_limit should < drop_limit"
    end

    flushing = false
    connecting = false

    connected = false
    inited = true

    --ngx.timer.at(0, _connect)
    return inited
end

function _M.log(msg)
    if not inited then
        return nil, "not initialized"
    end

    ngx.log(ngx.NOTICE, "log message " .. msg)

    if (buffer.size + string.len(msg) > drop_limit) then
        return nil, "logger buffer is full, this log would be dropped"
    end

    local ok, err = _write_buffer(msg)
    if not ok then
        return nil, err
    end

    if (buffer.size > flush_limit) then
        ngx.log(ngx.NOTICE, "start flushing")
        timer_at(0, _flush)
    end

    return true
end

return _M
