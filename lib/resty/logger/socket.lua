--An Object-oriented socket that one can create multiple socket object for different server connection
--Modified the original template: resty.socket.lua(written by Jiale Zhi (calio), CloudFlare Inc) for object-oriented
--Modified by whuben(https://github.com/whuben)
--require "luacov"
local concat                = table.concat
local tcp                   = ngx.socket.tcp
local udp                   = ngx.socket.udp
local timer_at              = ngx.timer.at
local ngx_log               = ngx.log
local ngx_sleep             = ngx.sleep
local type                  = type
local pairs                 = pairs
local tostring              = tostring
local debug                 = ngx.config.debug

local DEBUG                 = ngx.DEBUG
local CRIT                  = ngx.CRIT

local MAX_PORT              = 65535

-- table.new(narr, nrec)
local succ, new_tab = pcall(require, "table.new")
if not succ then
    new_tab = function () return {} end
end

local _M = new_tab(0, 5)

local is_exiting

if not ngx.config or not ngx.config.ngx_lua_version
    or ngx.config.ngx_lua_version < 9003 then

    is_exiting = function() return false end

    ngx_log(CRIT, "We strongly recommend you to update your ngx_lua module to "
            .. "0.9.3 or above. lua-resty-logger-socket will lose some log "
            .. "messages when Nginx reloads if it works with ngx_lua module "
            .. "below 0.9.3")
else
    is_exiting = ngx.worker.exiting
end

local _M = {
    _VERSION = "0.04"
}
local mt = {__index=_M}


local last_error

local ssl_session

local function _write_error(msg)
    last_error = msg
end

local function _do_connect(socket_obj)
    local ok, err, sock

    if not socket_obj.connected then
        if (socket_obj.sock_type == 'udp') then
            sock, err = udp()
        else
            sock, err = tcp()
        end

        if not sock then
            _write_error(err)
            return nil, err
        end

        sock:settimeout(socket_obj.timeout)
    end

    -- "host"/"port" and "path" have already been checked in init()
    if socket_obj.host and socket_obj.port then
        if (socket_obj.sock_type == 'udp') then
            ok, err = sock:setpeername(socket_obj.host, socket_obj.port)
        else
            ok, err = sock:connect(socket_obj.host, socket_obj.port)
        end
    elseif socket_obj.path then
        ok, err = sock:connect("unix:" .. socket_obj.path)
    end

    if not ok then
        return nil, err
    end

    return sock
end

local function _do_handshake(sock,socket_obj)
    if not ssl then
        return sock
    end

    local session, err = sock:sslhandshake(ssl_session, socket_obj.sni_host or socket_obj.host,
                                           socket_obj.ssl_verify)
    if not session then
        return nil, err
    end

    ssl_session = session
    return sock
end

local function _connect(socket_obj)
    local err, sock

    if socket_obj.connecting then
        if debug then
            ngx_log(DEBUG, "previous connection not finished")
        end
        return nil, "previous connection not finished"
    end

    socket_obj.connected = false
    socket_obj.connecting = true

    socket_obj.retry_connect = 0

    while socket_obj.retry_connect <= socket_obj.max_retry_times do
        sock, err = _do_connect(socket_obj)

        if sock then
            sock, err = _do_handshake(sock,socket_obj)
            if sock then
                socket_obj.connected = true
                break
            end
        end

        if debug then
            ngx_log(DEBUG, "reconnect to the log server: ", err)
        end

        -- ngx.sleep time is in seconds
        if not socket_obj.exiting then
            ngx_sleep(socket_obj.retry_interval / 1000)
        end

        socket_obj.retry_connect = socket_obj.retry_connect + 1
    end

    socket_obj.connecting = false
    if not socket_obj.connected then
        return nil, "try to connect to the log server failed after "
                    .. socket_obj.max_retry_times .. " retries: " .. err
    end

    return sock
end

local function _prepare_stream_buffer(socket_obj)
    local packet = concat(socket_obj.log_buffer_data, "", 1, socket_obj.log_buffer_index)
    socket_obj.send_buffer = socket_obj.send_buffer .. packet

    socket_obj.log_buffer_index = 0
    socket_obj.counter = socket_obj.counter + 1
    if socket_obj.counter > socket_obj.max_buffer_reuse then
        socket_obj.log_buffer_data = new_tab(20000, 0)
        socket_obj.counter = 0
        if debug then
            ngx_log(DEBUG, "log buffer reuse limit (" .. socket_obj.max_buffer_reuse
                    .. ") reached, create a new \"log_buffer_data\"")
        end
    end
end

local function _do_flush(socket_obj)
    local ok, err, sock, bytes
    local packet = socket_obj.send_buffer

    sock, err = _connect(socket_obj)
    if not sock then
        return nil, err
    end

    bytes, err = sock:send(packet)
    if not bytes then
        -- "sock:send" always closes current connection on error
        return nil, err
    end

    if debug then
        ngx.update_time()
        ngx_log(DEBUG, ngx.now(), ":log flush:" .. bytes .. ":" .. packet)
    end

    if (socket_obj.sock_type ~= 'udp') then
        ok, err = sock:setkeepalive(0, socket_obj.pool_size)
        if not ok then
            return nil, err
        end
    end

    return bytes
end

local function _need_flush(socket_obj)
    if socket_obj.buffer_size > 0 then
        return true
    end

    return false
end

local function _flush_lock(socket_obj)
    if not socket_obj.flushing then
        if debug then
            ngx_log(DEBUG, "flush lock acquired")
        end
        socket_obj.flushing = true
        return true
    end
    return false
end

local function _flush_unlock(socket_obj)
    if debug then
        ngx_log(DEBUG, "flush lock released")
    end
    socket_obj.flushing = false
end

local function _flush(premature,socket_obj)
    local err
    --pre check
    if not _flush_lock(socket_obj) then
        if debug then
            ngx_log(DEBUG, "previous flush not finished")
        end
        -- do this later
        return true
    end

    if not _need_flush(socket_obj) then
        if debug then
            ngx_log(DEBUG, "no need to flush:", socket_obj.log_buffer_index)
        end
        _flush_unlock(socket_obj)
        return true
    end

    -- start flushing
    socket_obj.retry_send = 0
    if debug then
        ngx_log(DEBUG, "start flushing")
    end

    local bytes
    while socket_obj.retry_send <= socket_obj.max_retry_times do
        if socket_obj.log_buffer_index > 0 then
            _prepare_stream_buffer(socket_obj)
        end

        bytes, err = _do_flush(socket_obj)

        if bytes then
            break
        end

        if debug then
            ngx_log(DEBUG, "resend log messages to the log server: ", err)
        end

        -- ngx.sleep time is in seconds
        if not socket_obj.exiting then
            ngx_sleep(socket_obj.retry_interval / 1000)
        end

        socket_obj.retry_send = socket_obj.retry_send + 1
    end

    _flush_unlock(socket_obj)

    if not bytes then
        local err_msg = "try to send log messages to the log server "
                        .. "failed after " .. socket_obj.max_retry_times .. " retries: "
                        .. err
        _write_error(err_msg)
        return nil, err_msg
    else
        if debug then
            ngx_log(DEBUG, "send " .. bytes .. " bytes")
        end
    end

    socket_obj.buffer_size = socket_obj.buffer_size - #socket_obj.send_buffer
    socket_obj.send_buffer = ""

    return bytes
end

local function _periodic_flush(premature,socket_obj)
    if premature then
        socket_obj.exiting = true
    end

    if socket_obj.need_periodic_flush or socket_obj.exiting then
        -- no regular flush happened after periodic flush timer had been set
        if debug then
            ngx_log(DEBUG, "performing periodic flush")
        end
        _flush(nil,socket_obj)
    else
        if debug then
            ngx_log(DEBUG, "no need to perform periodic flush: regular flush "
                    .. "happened before")
        end
        socket_obj.need_periodic_flush = true
    end

    timer_at(socket_obj.periodic_flush, _periodic_flush,socket_obj)
end

function _M:_flush_buffer()
    local ok, err = timer_at(0, _flush,self)

    self.need_periodic_flush = false

    if not ok then
        _write_error(err)
        return nil, err
    end
end

function _M:_write_buffer(msg, len)
    self.log_buffer_index = self.log_buffer_index + 1
    self.log_buffer_data[self.log_buffer_index] = msg

    self.buffer_size = self.buffer_size + len


    return self.buffer_size
end

function _M:init(user_config)
    if (type(user_config) ~= "table") then
        return nil, "user_config must be a table"
    end
    local socket_instance = {}
    socket_instance.timeout = 1000
    socket_instance.drop_limit = 1048576
    socket_instance.flush_limit = 4096
    socket_instance.max_buffer_reuse = 10000
    socket_instance.max_retry_times = 3
    socket_instance.pool_size = 10
    socket_instance.retry_interval = 100
    socket_instance.sock_type = "tcp"
    socket_instance.ssl = false
    socket_instance.ssl_verify = true
    socket_instance.counter = 0
    for k, v in pairs(user_config) do
        if k == "host" then
            if type(v) ~= "string" then
                return nil, '"host" must be a string'
            end
            socket_instance.host = v
        elseif k == "port" then
            if type(v) ~= "number" then
                return nil, '"port" must be a number'
            end
            if v < 0 or v > MAX_PORT then
                return nil, ('"port" out of range 0~%s'):format(MAX_PORT)
            end
            socket_instance.port = v
        elseif k == "path" then
            if type(v) ~= "string" then
                return nil, '"path" must be a string'
            end
            socket_instance.path = v
        elseif k == "sock_type" then
            if type(v) ~= "string" then
                return nil, '"sock_type" must be a string'
            end
            if v ~= "tcp" and v ~= "udp" then
                return nil, '"sock_type" must be "tcp" or "udp"'
            end
            socket_instance.sock_type = v
        elseif k == "flush_limit" then
            if type(v) ~= "number" or v < 0 then
                return nil, 'invalid "flush_limit"'
            end
            socket_instance.flush_limit = v
        elseif k == "drop_limit" then
            if type(v) ~= "number" or v < 0 then
                return nil, 'invalid "drop_limit"'
            end
            socket_instance.drop_limit = v
        elseif k == "timeout" then
            if type(v) ~= "number" or v < 0 then
                return nil, 'invalid "timeout"'
            end
            socket_instance.timeout = v
        elseif k == "max_retry_times" then
            if type(v) ~= "number" or v < 0 then
                return nil, 'invalid "max_retry_times"'
            end
            socket_instance.max_retry_times = v
        elseif k == "retry_interval" then
            if type(v) ~= "number" or v < 0 then
                return nil, 'invalid "retry_interval"'
            end
            -- ngx.sleep time is in seconds
            socket_instance.retry_interval = v
        elseif k == "pool_size" then
            if type(v) ~= "number" or v < 0 then
                return nil, 'invalid "pool_size"'
            end
            socket_instance.pool_size = v
        elseif k == "max_buffer_reuse" then
            if type(v) ~= "number" or v < 0 then
                return nil, 'invalid "max_buffer_reuse"'
            end
            socket_instance.max_buffer_reuse = v
        elseif k == "periodic_flush" then
            if type(v) ~= "number" or v < 0 then
                return nil, 'invalid "periodic_flush"'
            end
            socket_instance.periodic_flush = v
        elseif k == "ssl" then
            if type(v) ~= "boolean" then
                return nil, '"ssl" must be a boolean value'
            end
            socket_instance.ssl = v
        elseif k == "ssl_verify" then
            if type(v) ~= "boolean" then
                return nil, '"ssl_verify" must be a boolean value'
            end
            socket_instance.ssl_verify = v
        elseif k == "sni_host" then
            if type(v) ~= "string" then
                return nil, '"sni_host" must be a string'
            end
            socket_instance.sni_host = v
        end
    end

    if not (socket_instance.host and socket_instance.port) and not socket_instance.path then
        return nil, "no logging server configured. \"host\"/\"port\" or "
                .. "\"path\" is required."
    end
    if (socket_instance.flush_limit >= socket_instance.drop_limit) then
        return nil, "\"flush_limit\" should be < \"drop_limit\""
    end
    socket_instance.flushing       = false
    socket_instance.exiting        = false
    socket_instance.connecting     = false
    socket_instance.connected      = false
    socket_instance.retry_connect  = 0
    socket_instance.retry_send     = 0
    socket_instance.logger_initted = true
    socket_instance.send_buffer = ""
    socket_instance.log_buffer_index = 0
    socket_instance.log_buffer_data = new_tab(20000, 0)
    socket_instance.buffer_size = 0
    if socket_instance.periodic_flush then
        if debug then
            ngx_log(DEBUG, "periodic flush enabled for every "
                    .. socket_instance.periodic_flush .. " seconds")
        end
        socket_instance.need_periodic_flush = true
        timer_at(socket_instance.periodic_flush,_periodic_flush,setmetatable(socket_instance,mt))
    end
    return setmetatable(socket_instance,mt)
end

function _M:log(msg)
    if not self.logger_initted then
        return nil, "not initialized"
    end
    local bytes
    if type(msg) ~= "string" then
        msg = tostring(msg)
    end
    local msg_len = #msg
    if (debug) then
        ngx.update_time()
        ngx_log(DEBUG, ngx.now(), ":log message length: " .. msg_len)
    end
    -- response of "_flush_buffer" is not checked, because it writes
    -- error buffer
    if (is_exiting()) then
        exiting = true
        self:_write_buffer(msg, msg_len)
        self:_flush_buffer()
        if (debug) then
            ngx_log(DEBUG, "Nginx worker is exiting")
        end
        bytes = 0
    elseif (msg_len + self.buffer_size < self.flush_limit) then
        self:_write_buffer(msg, msg_len)
        bytes = msg_len
    elseif (msg_len + self.buffer_size <= self.drop_limit) then
        self:_write_buffer(msg, msg_len)
        self:_flush_buffer()
        bytes = msg_len
    else
        self:_flush_buffer()
        if (debug) then
            ngx_log(DEBUG, "logger buffer is full, this log message will be "
                    .. "dropped")
        end
        bytes = 0
        --- this log message doesn't fit in buffer, drop it
    end

    if last_error then
        local err = last_error
        last_error = nil
        return bytes, err
    end

    return bytes
end

function _M:initted()
    return self.logger_initted
end

function _M:close()
    if self.logger_initted == true then
        _flush(nil,self)
        self.logger_initted = false
    end
end

return _M
