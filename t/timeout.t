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

plan tests => repeat_each() * (blocks() * 4 );

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_package_cpath "/usr/local/openresty-debug/lualib/?.so;/usr/local/openresty/lualib/?.so;;";
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();

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
retry connect
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
            if not logger.inited then
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
retry send
--- tcp_query:
--- response_body
foo
