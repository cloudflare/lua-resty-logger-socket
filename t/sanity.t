# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * (blocks() * 4 - 1 + 2);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_package_cpath "/usr/local/openresty-debug/lualib/?.so;/usr/local/openresty/lualib/?.so;;";
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();

log_level('debug');

run_tests();

__DATA__

=== TEST 1: instant flush
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"
            if not logger.initted() then
                local ok, err = logger.init{
                    host = "127.0.0.1", port = 29999, flush_limit = 1,
                    pool_size = 5,
                }
            end

            local ok, err = logger.log(ngx.var.request_uri)
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        ';
    }
--- request
GET /t?a=1&b=2
--- wait: 0.5
--- tcp_listen: 29999
--- tcp_reply:
--- no_error_log
[error]
--- tcp_query: /t?a=1&b=2
--- response_body
foo



=== TEST 2: instant flush, unix domain socket
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"
            if not logger.initted() then
                local ok, err = logger.init{
                    flush_limit = 1,
                    path = "logger_test.sock" }
                if not ok then
                    ngx.log(ngx.ERR, err)
                    return
                end
            end

            local ok, err = logger.log(ngx.var.request_uri)
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        ';
    }
--- request
GET /t?a=1&b=2
--- wait: 1
--- tcp_listen: logger_test.sock
--- tcp_reply:
--- no_error_log
[error]
--- tcp_query: /t?a=1&b=2
--- response_body
foo



=== TEST 3: log number
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"
            if not logger.initted() then
                local ok, err = logger.init{
                    host = "127.0.0.1", port = 29999, flush_limit = 1 }
            end

            local ok, err = logger.log(10)
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        ';
    }
--- request
GET /t?a=1&b=2
--- wait: 0.5
--- tcp_listen: 29999
--- tcp_reply:
--- no_error_log
[error]
--- tcp_query: 10
--- response_body
foo



=== TEST 4: buffer log, no flush
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"
            if not logger.initted() then
                local ok, err = logger.init{
                    host = "127.0.0.1", port = 29999, flush_limit = 500 }
            end

            local ok, err = logger.log(ngx.var.request_uri)
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        ';
    }
--- request
GET /t?a=1&b=2
--- wait: 0.5
--- tcp_listen: 29999
--- tcp_reply:
--- no_error_log
[error]
--- tcp_query:
--- response_body
foo



=== TEST 5: not initted()
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"

            local ok, err = logger.log(ngx.var.request_uri)
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        ';
    }
--- request
GET /t?a=1&b=2
--- wait: 0.5
--- tcp_listen: 29999
--- tcp_reply:
--- error_log
not initialized
--- tcp_query:
--- response_body
foo



=== TEST 6: log subrequest
--- http_config eval: $::HttpConfig
--- config
    log_subrequest on;
    location /t {
        content_by_lua '
            local res = ngx.location.capture("/main?c=1&d=2")
            if res.status ~= 200 then
                ngx.log(ngx.ERR, "capture /main failed")
            end
            ngx.print(res.body)
        ';
    }

    location /main {
        content_by_lua '
        ngx.say("foo")';
    }

    log_by_lua '
        local logger = require "resty.logger.socket"
        if not logger.initted() then
            local ok, err = logger.init{
                host = "127.0.0.1", port = 29999, flush_limit = 6 }
        end

        local ok, err = logger.log(ngx.var.uri)
        if not ok then
            ngx.log(ngx.ERR, err)
        end
    ';
--- request
GET /t?a=1&b=2
--- wait: 1
--- tcp_listen: 29999
--- tcp_reply:
--- no_error_log
[error]
--- tcp_query: /main/t
--- response_body
foo



=== TEST 7: log subrequest, flush twice
--- http_config eval: $::HttpConfig
--- config
    log_subrequest on;
    location /t {
        content_by_lua '
            local res = ngx.location.capture("/main?c=1&d=2")
            if res.status ~= 200 then
                ngx.log(ngx.ERR, "capture /main failed")
            end
            ngx.print(res.body)
        ';
    }

    location /main {
        content_by_lua '
        ngx.say("foo")';
    }

    log_by_lua '
        local logger = require "resty.logger.socket"
        if not logger.initted() then
            local ok, err = logger.init{
                host = "127.0.0.1", port = 29999, flush_limit = 1 }
        end

        local ok, err = logger.log(ngx.var.uri)
        if not ok then
            ngx.log(ngx.ERR, err)
        end
    ';
--- request
GET /t?a=1&b=2
--- wait: 1
--- tcp_listen: 29999
--- tcp_reply:
--- no_error_log
[error]
--- tcp_query: /main/t
--- tcp_query_len: 7
--- response_body
foo



=== TEST 8: do not log subrequest
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local res = ngx.location.capture("/main?c=1&d=2")
            if res.status ~= 200 then
                ngx.log(ngx.ERR, "capture /main failed")
            end
            ngx.print(res.body)
        ';
    }

    location /main {
        content_by_lua 'ngx.say("foo")';
    }

    log_by_lua '
        ngx.log(ngx.NOTICE, "enter log_by_lua")
        local logger = require "resty.logger.socket"
        if not logger.initted() then
            local ok, err = logger.init{
                host = "127.0.0.1", port = 29999, flush_limit = 1, log_subrequest = false }
        end

        local ok, err = logger.log(ngx.var.request_uri)
        if not ok then
            ngx.log(ngx.ERR, err)
        end
    ';
--- request
GET /t?a=1&b=2
--- wait: 0.5
--- tcp_listen: 29999
--- tcp_reply:
--- no_error_log
[error]
--- tcp_query: /t?a=1&b=2
--- response_body
foo



=== TEST 9: partial flush
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"
            if not logger.initted() then
                local ok, err = logger.init{
                    host = "127.0.0.1", port = 29999, flush_limit = 5 }
            end

            local ok, err = logger.log("aaa")
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        ';
    }
--- request eval
["GET /t","GET /t","GET /t"]
--- wait: 1
--- tcp_listen: 29999
--- tcp_reply:
--- no_error_log
[error]
--- tcp_query: aaaaaa
--- response_body eval
["foo\n","foo\n","foo\n"]



=== TEST 10: bad user config
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"
            if not logger.initted() then
                local ok, err = logger.init("hello")
                if not ok then
                    ngx.log(ngx.ERR, err)
                    return
                end

            end

            local ok, err = logger.log(ngx.var.request_uri)
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        ';
    }
--- request
GET /t?a=1&b=2
--- wait: 0.5
--- error_log
user_config must be a table
--- response_body
foo



=== TEST 11: bad user config: no host/port or path
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"
            if not logger.initted() then
                local ok, err = logger.init{
                    flush_limit = 1,
                    drop_limit = 2,
                }
                if not ok then
                    ngx.log(ngx.ERR, err)
                    return
                end
            end

            local ok, err = logger.log(ngx.var.request_uri)
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        ';
    }
--- request
GET /t?a=1&b=2
--- wait: 0.5
--- error_log
no logging server configured. Need host/port or path.
--- response_body
foo



=== TEST 12: bad user config: flush_limit > drop_limit
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"
            if not logger.initted() then
                local ok, err = logger.init{
                    flush_limit = 2,
                    drop_limit = 1,
                    path = "logger_test.sock",
                }
                if not ok then
                    ngx.log(ngx.ERR, err)
                    return
                end
            end

            local ok, err = logger.log(ngx.var.request_uri)
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        ';
    }
--- request
GET /t?a=1&b=2
--- wait: 0.5
--- error_log
flush_limit should < drop_limit
--- response_body
foo



=== TEST 13: drop log test
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"
            if not logger.initted() then
                local ok, err = logger.init{
                    path = "logger_test.sock",
                    drop_limit = 5,
                    flush_limit = 3,
                }
            end

            local ok, err = logger.log("000")
            if not ok then
                ngx.log(ngx.ERR, err)
            end

            local ok, err = logger.log("aaaaa")
            if not ok then
                ngx.log(ngx.ERR, err)
            end

            local ok, err = logger.log("bbb")
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        ';
    }
--- request
GET /t?a=1&b=2
--- wait: 0.5
--- tcp_listen: logger_test.sock
--- tcp_query: 000bbb
--- tcp_query_len: 6
--- tcp_reply:
--- error_log
logger buffer is full, this log would be dropped
--- response_body
foo
