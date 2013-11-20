# vim:set ft= ts=4 sw=4 et:

BEGIN {
    if (!defined $ENV{LD_PRELOAD}) {
        $ENV{LD_PRELOAD} = '';
    }

    if ($ENV{LD_PRELOAD} !~ /\bmockeagain\.so\b/) {
        $ENV{LD_PRELOAD} = "mockeagain.so $ENV{LD_PRELOAD}";
    }

    $ENV{MOCKEAGAIN} = 'w';

    $ENV{MOCKEAGAIN_VERBOSE} = 1;
    $ENV{TEST_NGINX_EVENT_TYPE} = 'poll';
    $ENV{MOCKEAGAIN_WRITE_TIMEOUT_PATTERN} = 'hello';
    $ENV{TEST_NGINX_POSTPONE_OUTPUT} = 1;
}

use Test::Nginx::Socket;
use Cwd qw(cwd);

repeat_each(1);

plan tests => repeat_each() * (blocks() * 3 + 2);
our $HtmlDir = html_dir;

my $pwd = cwd();

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

=== TEST 1: small flush_limit, instant flush
--- http_config eval: $::HttpConfig
--- config
    log_subrequest on;
    location /log {
        content_by_lua 'ngx.print("foo")';
        log_by_lua '
            local logger = require "resty.logger.socket"
            if not logger.initted() then
                local ok, err = logger.init{
                    host = "127.0.0.1",
                    port = 29999,
                    flush_limit = 5,
                    drop_limit = 11,
                    pool_size = 5,
                    retry_interval = 1,
                    max_retry_times = 0,
                    timeout = 10,
                }
            end

            local ok, err = logger.log(ngx.var.arg_log)
        ';

    }
    location /t {
        content_by_lua '
            local res = ngx.location.capture("/log?log=helloworld")
            ngx.say(res.body)
            ngx.sleep(0.05)

            res = ngx.location.capture("/log?log=bb")
            ngx.say(res.body)
            ngx.sleep(0.05)

            res = ngx.location.capture("/log?log=bb")
            ngx.say(res.body)
        ';
    }
--- request
GET /t?a=1&b=2
--- wait: 0.1
--- tcp_listen: 29999
--- tcp_reply:
--- tcp_no_close
--- ordered_error_log
retry to send log message to the log server: timeout
retry to send log message to the log server: timeout
retry to send log message to the log server: timeout
--- response_body
foo
foo
foo

