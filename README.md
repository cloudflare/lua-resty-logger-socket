Name
====

lua-resty-logger-socket - nonblocking remote logging for the ngx_lua

Status
======

This library is under heavy development.

Description
===========

This lua library is a remote logging module for ngx_lua:

http://wiki.nginx.org/HttpLuaModule

This Lua library takes advantage of ngx_lua's cosocket API, which ensures
100% nonblocking behavior.

Note that at least [ngx_lua 0.8.0](https://github.com/chaoslawful/lua-nginx-module/tags).

Synopsis
========


    lua_package_path "/path/to/lua-resty-logger-socket/lib/?.lua;;";

    server {
        location /test {
            log_by_lua '
                log_by_lua '
                    local logger = require "resty.logger.socket"
                    if not logger.initted() then
                        local ok, err = logger.init{
                            host = 'xxx',
                            port = 1234,
                            flush_limit = 1234,
                            drop_limit = 5678,
                        }
                    end
                    local ok, err = logger.log(msg)
                    ...
                ';
            ';
        }
    }

Methods
=======

Logger module is designed to be shared inside an nginx worker process by different threads. So currently, only one remote logging server is suppered. All thread should use the same remote logging server.

init
----
`syntax: ok, err = logger.init(user_config)`

Initialize logger with user config. Logger must be inited before use. If you does not initialize logger before, you would get an error message.

Available user configurations are listed as follows:

`flush_limit`

If buffered log size plus current log size reaches(>=) this limit, buffered log would be written to logging server. Default flush_limit is 4096(4KB).

`drop_limit`

If buffered log size plush current log size is larger than this limit, current log would be dropped because of limited buffer size. Default drop_limit is
1048576(1MB).

`timeout`

Sets the timeout (in ms) protection for subsequent operations, including the *connect* method. Default value is 1000(1 sec).

`host`

logging server host.

`port`

logging server port.

`path`

If logging server uses unix domain socket, path is the socket path. Note that host/port and path can't both be empty. At least one must be supplied.

inited()
--------
`syntax: inited = logger.inited()`
Get a value describing whether this module has been inited.

log
---
`syntax: ok, err = logger.log(msg)`

Log message to remote logging server.

TODO
====

Author
======
Jiale Zhi <vipcalio@gmail.com>, CloudFlare Inc.


Copyright and License
=====================

This module is licensed under the BSD license.

Copyright (C) 2013, by Jiale Zhi <vipcalio@gmail.com>, CloudFlare Inc.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
