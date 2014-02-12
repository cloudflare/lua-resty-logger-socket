-- Copyright (C) 2013 Jiale Zhi (calio), Cloudflare Inc.
--require "luacov"

local concat                = table.concat
local tcp                   = ngx.socket.tcp
local udp                   = ngx.socket.udp
local timer_at              = ngx.timer.at
local ngx_log               = ngx.log
local ngx_sleep             = ngx.sleep
local type                  = type
local pairs                 = pairs
local ipairs                = ipairs
local tostring              = tostring
local debug                 = ngx.config.debug

local DEBUG                 = ngx.DEBUG
local NOTICE                = ngx.NOTICE
local WARN                  = ngx.WARN
local ERR                   = ngx.ERR
local CRIT                  = ngx.CRIT


local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function (narr, nrec) return {} end
end

local ok, clear_tab = pcall(require, "table.clear")
if not ok then
    clear_tab = function(tab) for k, _ in pairs(tab) do tab[k] = nil end end
end

local _M = new_tab(0, 4)

local is_exiting

if not ngx.config or not ngx.config.ngx_lua_version
    or ngx.config.ngx_lua_version < 9003 then

    is_exiting = function() return false end

    ngx_log(CRIT, "lua-resty-logger-socket working with ngx_lua module < 0.9.3"
            .. " has a serious issue that some log messages may be lost when"
            .. " nginx reloads. We strongly recommend you update your ngx_lua"
            .. " module to at least 0.9.3")
else
    is_exiting = ngx.worker.exiting
end


_M._VERSION = '0.02'

-- user config
local flush_limit           = 4096         -- 4KB
local drop_limit            = 1048576      -- 1MB
local timeout               = 1000         -- 1 sec
local host
local port
local path
local datagram              = false

-- internal variables
local buffer_size           = 0
-- 1st level buffer, it stores incoming logs
local incoming_buffer       = new_tab(20000, 0)
local incoming_buffer_index = 0
-- 2nd level buffer, it stores logs ready to be sent out
local send_buffer           = new_tab(1000)
local send_buffer_index     = 0
local send_buffer_size      = 0

local last_error

local connecting
local connected
local exiting
local retry_connect         = 0
local retry_send            = 0
local max_retry_times       = 3
local retry_interval        = 100         -- 0.1s
local pool_size             = 10
local flushing
local logger_initted
local sock


local function _write_error(msg)
    last_error = msg
end

local function _do_connect()
    local ok, err

    if not connected then
        if datagram then
            sock, err = udp()
        else
            sock, err = tcp()
        end

        if not sock then
            _write_error(err)
            return nil, err
        end

        sock:settimeout(timeout)
    end

    -- host/port and path config have already been checked in init()
    if host and port then
        if datagram then
            ok, err =  sock:setpeername(host, port)
        else
            ok, err =  sock:connect(host, port)
        end
    elseif path then
        if datagram then
            ok, err =  sock:setpeername("unix:" .. path)
        else
            ok, err =  sock:connect("unix:" .. path)
        end
    end

    return ok, err
end

local function _connect()
    local ok, err

    if connecting then
        if debug then
            ngx_log(DEBUG, "previous connect not finished")
        end
        return true
    end

    connected = false
    connecting = true

    retry_connect = 0

    while retry_connect <= max_retry_times do
        ok, err = _do_connect()

        if ok then
            connected = true
            break
        end

        if debug then
            ngx_log(DEBUG, "retry to connect to the log server: ", err)
        end

        -- ngx.sleep use seconds to count time
        if not exiting then
            ngx_sleep(retry_interval / 1000)
        end

        retry_connect = retry_connect + 1
    end

    connecting = false
    if not connected then
        return nil, "try to connect to the log server failed after "
                    .. max_retry_times .. " retries: " .. err
    end

    return true
end

local function _prepare_send_buffer()
    for i=1, incoming_buffer_index do
        send_buffer_index = send_buffer_index + 1
        send_buffer[send_buffer_index] = incoming_buffer[i]
    end

    send_buffer_size = buffer_size
    incoming_buffer_index = 0
    clear_tab(incoming_buffer)
end

local function _reset_send_buffer()
    buffer_size = buffer_size - send_buffer_size
    send_buffer_index = 0
    send_buffer_size = 0
    clear_tab(send_buffer)
end

-- this is expensive and should only be used to tidy up in case of an error
local function _pop_send_buffer(count)
    for i=1, count do
        local packet = send_buffer.remove(i)
        send_buffer_index = send_buffer_index - 1
        send_buffer_size = send_buffer_size - #packet
    end
end

local function _do_stream_flush()
    local ok, err = _connect()
    if not ok then
        return nil, err
    end

    local bytes, err = sock:send(send_buffer)
    if not bytes then
        -- sock:send always close current connection on error
        return nil, err
    end

    _reset_send_buffer()

    if debug then
        ngx.update_time()
        ngx_log(DEBUG, ngx.now(), ":log flush:" .. bytes)
    end

    ok, err = sock:setkeepalive(0, pool_size)
    if not ok then
        return nil, err
    end

    return true
end

local function _do_datagram_flush()
    local ok, err = _connect()
    if not ok then
        return nil, err
    end

    for i, packet in ipairs(send_buffer) do
        local bytes, err = sock:send(packet)
        if not bytes then
            -- ensure we don't resend packets later that we've already sent
            _pop_send_buffer(i - 1)
            return nil, err
        end

        if debug then
            ngx.update_time()
            ngx_log(DEBUG, ngx.now(), ":log flush:" .. bytes)
        end
    end

    _reset_send_buffer()

    return true
end

local function _need_flush()
    if incoming_buffer_index > 0 or send_buffer_index > 0 then
        return true
    end

    return false
end

local function _flush_lock()
    if not flushing then
        flushing = true
        return true
    end
    return false
end

local function _flush_unlock()
    flushing = false
end

local function _flush()
    local ok, err

    -- pre check
    if not _flush_lock() then
        if debug then
            ngx_log(DEBUG, "previous flush not finished")
        end
        -- do this later
        return true
    end

    if not _need_flush() then
        if debug then
            ngx_log(DEBUG, "do not need to flush")
        end
        _flush_unlock()
        return true
    end

    -- start flushing
    retry_send = 0
    if debug then
        ngx_log(DEBUG, "start flushing")
    end

    while retry_send <= max_retry_times do
        if incoming_buffer_index > 0 then
            _prepare_send_buffer()
        end

        if datagram then
            ok, err = _do_datagram_flush()
        else
            ok, err = _do_stream_flush()
        end

        if ok then
            break
        end

        if debug then
            ngx_log(DEBUG, "retry to send log message to the log server: ", err)
        end

        -- ngx.sleep use seconds to count time
        if not exiting then
            ngx_sleep(retry_interval / 1000)
        end

        retry_send = retry_send + 1
    end

    _flush_unlock()

    if not ok then
        local err_msg = "try to send log message to the log server "
                        .. "failed after " .. max_retry_times .. " retries: "
                        .. err
        _write_error(err_msg)
        return nil, err_msg
    end

    return true
end

local function _flush_buffer()
    if (buffer_size >= flush_limit) then
        local ok, err = timer_at(0, _flush)
        if not ok then
            _write_error(err)
            return nil, err
        end
    end
end

local function _write_buffer(msg)
    incoming_buffer_index = incoming_buffer_index + 1
    incoming_buffer[incoming_buffer_index] = msg

    buffer_size = buffer_size + #msg

    return buffer_size
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
        elseif  k == "datagram" then
            datagram = v
        elseif k == "flush_limit" then
            flush_limit = v
        elseif k == "drop_limit" then
            drop_limit = v
        elseif k == "timeout" then
            timeout = v
        elseif k == "max_retry_times" then
            max_retry_times = v
        elseif k == "retry_interval" then
            -- ngx.sleep uses seconds to count sleep time
            retry_interval = v
        elseif k == "pool_size" then
            pool_size = v
        end
    end

    if not (host and port) and not path then
        return nil, "no logging server configured. Need host/port or path."
    end

    if (flush_limit >= drop_limit) then
        return nil, "flush_limit should < drop_limit"
    end

    flushing = false
    exiting = false
    connecting = false

    connected = false
    retry_connect = 0
    retry_send = 0

    logger_initted = true

    return logger_initted
end

function _M.log(msg)
    if not logger_initted then
        return nil, "not initialized"
    end

    local bytes

    if type(msg) ~= "string" then
        msg = tostring(msg)
    end

    if (debug) then
        ngx.update_time()
        ngx_log(DEBUG, ngx.now(), ":log message length: " .. #msg)
    end

    local msg_len = #msg

    -- return result of _flush_buffer is not checked, because it writes
    -- error buffer
    if (is_exiting()) then
        exiting = true
        _flush_buffer()
        if (debug) then
            ngx_log(DEBUG, "worker exixting, this log would be dropped")
        end
        bytes = 0
    elseif (msg_len + buffer_size < flush_limit) then
        _write_buffer(msg)
        bytes = msg_len
    elseif (msg_len + buffer_size <= drop_limit) then
        _write_buffer(msg)
        _flush_buffer()
        bytes = msg_len
    else
        _flush_buffer()
        if (debug) then
            ngx_log(DEBUG, "logger buffer is full, this log would be dropped")
        end
        bytes = 0
        --- this message does not fit in buffer, drop it
    end

    if last_error then
        local err = last_error
        last_error = nil
        return bytes, err
    end

    return bytes
end

function _M.initted()
    return logger_initted
end

return _M

