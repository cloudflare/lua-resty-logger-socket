# vim:set ft= ts=4 sw=4 et:
BEGIN {
    if (!defined $ENV{LD_PRELOAD}) {
        $ENV{LD_PRELOAD} = '';
    }

    if ($ENV{LD_PRELOAD} !~ /\bmockeagain\.so\b/) {
        $ENV{LD_PRELOAD} = "./mockeagain.so $ENV{LD_PRELOAD}";
    }

    if ($ENV{MOCKEAGAIN} eq 'r') {
        $ENV{MOCKEAGAIN} = 'rw';

    } else {
        $ENV{MOCKEAGAIN} = 'w';
    }

    $ENV{TEST_NGINX_EVENT_TYPE} = 'poll';
    $ENV{MOCKEAGAIN_WRITE_TIMEOUT_PATTERN} = 'hello, world';
    $ENV{TEST_NGINX_POSTPONE_OUTPUT} = 1;
}

use Test::Nginx::Socket;
use Cwd qw(cwd);

repeat_each(1);

plan tests => repeat_each() * (blocks() * 4 + 3);

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

=== TEST 1: connect timeout
--- http_config eval: $::HttpConfig
--- config
    resolver 8.8.8.8;
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"
            if not logger.initted() then
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
try to connect to the log server
--- tcp_query:
--- response_body
foo



=== TEST 2: send timeout
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"
            if not logger.initted() then
                local ok, err = logger.init{
                    host = "127.0.0.1", port = 29999, flush_limit = 1, timeout = 100 }
            end

            local ok, err = logger.log("hello, worldaaa")
            if not ok then
                ngx.log(ngx.ERR, "log failed")
            end
        ';
    }
--- request
GET /t?a=1&b=2
--- wait: 0.5
--- tcp_listen: 29999
--- tcp_reply:
--- tcp_query_len: 15
--- error_log
lua tcp socket write timed out
retry to send log message to the log server: timeout
--- tcp_query:
--- response_body
foo



=== TEST 3: risk condition
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

            local ok, err = logger.log("1234567891011121314151617181920212223242526272829303132333435363738394041424344454647484950")
            local ok, err = logger.log("1234567891011121314151617181920212223242526272829303132333435363738394041424344454647484950")
            if not ok then
                ngx.log(ngx.ERR, "log failed")
            end
        ';
    }
--- request
GET /t
--- wait: 0.5
--- tcp_listen: 29999
--- tcp_reply:
--- tcp_query_len: 15
--- no_error_log
[error]
[warn]
--- tcp_query: 12345678910111213141516171819202122232425262728293031323334353637383940414243444546474849501234567891011121314151617181920212223242526272829303132333435363738394041424344454647484950
--- tcp_query_len: 182
--- response_body
foo



=== TEST 4: return previous log error
--- http_config eval: $::HttpConfig
--- config
    resolver 8.8.8.8;
    log_subrequest on;
    location /main {
        content_by_lua '
            local res1 = ngx.location.capture("/t?a=1&b=2")
            if res1.status == 200 then
                ngx.print(res1.body)
            end

            ngx.sleep(1)
            ngx.say("bar")

            local res3 = ngx.location.capture("/t?a=1&b=2")
            if res3.status == 200 then
                ngx.print(res3.body)
            end

            ngx.sleep(1)
            ngx.say("bar")

            local res3 = ngx.location.capture("/t?a=1&b=2")
            if res3.status == 200 then
                ngx.print(res3.body)
            end
        ';
    }
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            require("luacov")
            local logger = require "resty.logger.socket"
            if not logger.initted() then
                local ok, err = logger.init{
                    -- timeout 1ms
                    host = "agentzh.org", port = 12345, flush_limit = 1, timeout = 1, max_error = 2 }
            end

            local ok, err = logger.log(ngx.var.request_uri)
            if not ok then
                ngx.log(ngx.ERR, "log error:" .. err)
            end
        ';
    }
--- request
GET /main
--- wait: 2
--- tcp_listen: 29999
--- tcp_reply:
--- error_log
lua tcp socket connect timed out
retry to connect to the log server: timeout
try to send log message to the log server failed after 3 retries
--- tcp_query:
--- response_body
foo
bar
foo
bar
foo
