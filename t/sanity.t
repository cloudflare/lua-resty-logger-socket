# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

repeat_each(1);

plan tests => repeat_each() * (blocks() * 4 - 3 + 6);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_package_cpath "/usr/local/openresty-debug/lualib/?.so;/usr/local/openresty/lualib/?.so;;";
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();

run_tests();

__DATA__

=== TEST 1: instant flush
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"
            if not logger.inited then
                local ok, err = logger.init{
                    host = "127.0.0.1", port = 29999, flush_limit = 1 }
            end

            local ok, err = logger.log(ngx.var.request_uri)
            if not ok then
                ngx.log(ngx.ERR, "log failed")
            end
        ';
    }
--- request
GET /t?a=1&b=2
--- wait: 0.1
--- tcp_listen: 29999
--- tcp_reply:
--- no_error_log
[error]
--- tcp_query: /t?a=1&b=2
--- response_body
foo



=== TEST 2: buffer log, no flush
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"
            if not logger.inited then
                local ok, err = logger.init{
                    host = "127.0.0.1", port = 29999, flush_limit = 500 }
            end

            local ok, err = logger.log(ngx.var.request_uri)
            if not ok then
                ngx.log(ngx.ERR, "log failed")
            end
        ';
    }
--- request
GET /t?a=1&b=2
--- wait: 0.1
--- tcp_listen: 29999
--- tcp_reply:
--- no_error_log
[error]
--- tcp_query:
--- response_body
foo



=== TEST 3: not inited
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
--- tcp_listen: 29999
--- tcp_reply:
--- error_log
not initialized
--- tcp_query:
--- response_body
foo



=== TEST 4: log subrequest
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
        if not logger.inited then
            local ok, err = logger.init{
                host = "127.0.0.1", port = 29999, flush_limit = 6 }
        end

        local ok, err = logger.log(ngx.var.uri)
        if not ok then
            ngx.log(ngx.ERR, "log failed")
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



=== TEST 5: do not log subrequest
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
        if not logger.inited then
            local ok, err = logger.init{
                host = "127.0.0.1", port = 29999, flush_limit = 1, log_subrequest = false }
        end

        local ok, err = logger.log(ngx.var.request_uri)
        if not ok then
            ngx.log(ngx.ERR, "log failed")
        end
    ';
--- request
GET /t?a=1&b=2
--- wait: 0.1
--- tcp_listen: 29999
--- tcp_reply:
--- no_error_log
[error]
--- tcp_query: /t?a=1&b=2
--- response_body
foo



=== TEST 6: connect timeout
--- http_config eval: $::HttpConfig
--- config
    resolver 8.8.8.8;
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"
            if not logger.inited then
                local ok, err = logger.init{
                    -- timeout 1ms
                    host = "agentzh.org", port = 12345, flush_limit = 1, timeout = 1 }
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
--- error_log
tcp socket connect timed out
--- tcp_query:
--- response_body
foo



=== TEST 7: partial flush
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"
            if not logger.inited then
                local ok, err = logger.init{
                    host = "127.0.0.1", port = 29999, flush_limit = 5 }
            end

            local ok, err = logger.log("aaa")
            if not ok then
                ngx.log(ngx.ERR, "log failed")
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
