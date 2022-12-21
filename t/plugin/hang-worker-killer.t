use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    my $yaml_config = $block->yaml_config // <<_EOC_;
apisix:
    node_listen: 1984
    admin_key: null
plugins:
  - cpu-burn
  - hang-worker-killer
_EOC_

    $block->set_value("yaml_config", $yaml_config);

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }

    # if (!$block->error_log && !$block->no_error_log) {
    #     $block->set_value("no_error_log", "[error]\n[alert]");
    # }
});

run_tests;

__DATA__

=== TEST 1: set plugin metadata
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/plugin_metadata/hang-worker-killer',
                ngx.HTTP_PUT,
                [[{
                    "enabled": true,
                    "interval": 3,
                    "continuous": 3
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 2: set route
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "cpu-burn": {},
                        "hang-worker-killer": {}
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/hello"
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 3: origin not match
--- timeout: 20
--- request
GET /hello?burn_sec=11 HTTP/1.1
--- response_body
hello world
