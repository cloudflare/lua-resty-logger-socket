# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(2);

use Test::Nginx::Socket "no_plan";
our $HtmlDir = html_dir;

our $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_package_cpath "/usr/local/openresty-debug/lualib/?.so;/usr/local/openresty/lualib/?.so;;";
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';
$ENV{TEST_NGINX_HTML_DIR} = $HtmlDir;

no_long_string();

log_level('debug');

run_tests();

__DATA__

=== TEST 1: create 2 logger_socket oblects
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua 'ngx.say("foo")';
        log_by_lua '
            collectgarbage()  -- to help leak testing

            local logger_socket = require "resty.logger.socket"
            local logger = logger_socket:new()
            if not logger:initted() then
                local ok, err = logger:init{
                    host = "127.0.0.1",
                    port = 29999,
                    flush_limit = 1,
                }

                local bytes, err = logger:log(ngx.var.request_uri)
                if err then
                    ngx.log(ngx.ERR, err)
                end
            end
        ';
    }
--- request eval
["GET /t?a=1&b=2", "GET /t?c=3&d=4"]
--- wait: 0.1
--- tcp_listen: 29999
--- tcp_reply:
--- no_error_log
[error]
--- tcp_query eval: "/t?a=1&b=2/t?c=3&d=4"
--- tcp_query_len: 20
--- response_body eval
["foo\n", "foo\n"]
