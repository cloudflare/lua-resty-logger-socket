# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * (3 * blocks()) + 4;

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
                local ok, err = logger.init{ host = "127.0.0.1", port = 29999, flush_limit = 1 }
            end

            local ok, err = logger.log(ngx.var.request_uri)
            if not ok then
                ngx.log(ngx.ERR, "log failed")
            end
        ';
    }
--- request
GET /t?a=1&b=2
--- wait: 1
--- tcp_listen: 29999
--- tcp_reply:
--- no_error_log
[error]
--- tcp_query: /t?a=1&b=2
--- tcp_query_len: 10
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
                local ok, err = logger.init{ host = "127.0.0.1", port = 29999, flush_limit = 500 }
            end

            local ok, err = logger.log(ngx.var.request_uri)
            if not ok then
                ngx.log(ngx.ERR, "log failed")
            end
        ';
    }
--- request
GET /t?a=1&b=2
--- wait: 1
--- tcp_listen: 29999
--- tcp_reply:
--- no_error_log
[error]
--- tcp_query:
--- tcp_query_len: 10
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
--- wait: 1
--- tcp_listen: 29999
--- tcp_reply:
--- error_log
not initialized
--- tcp_query:
--- tcp_query_len: 10
--- response_body
foo
