Name
====

lua-resty-logger-socket - nonblocking remote logging for the ngx_lua

Status
======

This library is under heavy development.

Description
===========


Synopsis
========


    # you do not need the following line if you are using
    # the ngx_openresty bundle:
    lua_package_path "/path/to/lua-resty-logger-socket/lib/?.lua;;";

    server {
        location /test {
            log_by_lua '
                log_by_lua '
                    local logger = require "resty.logger.socket"
                    if not logger.initted then
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

init
----
`syntax: ok, err = logger.init(user_config)`

Initialize logger with user config.

log
---
`syntax: ok, err = logger.log(msg)`

Log message to remote log server.

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
