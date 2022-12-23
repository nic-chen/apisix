use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    # setup plugins
    my $extra_yaml_config = $block->extra_yaml_config // <<_EOC_;
plugins:
  - hang-worker-killer
  - cpu-burn
_EOC_

    $block->set_value("extra_yaml_config", $extra_yaml_config);

    # setup plugin sharedict
    my $extra_http_config = $block->http_config // '';
    $extra_http_config .= <<_EOC_;
    lua_shared_dict plugin-hang-worker-killer-qps 1m;
    lua_shared_dict plugin-hang-worker-killer-pids 1m;
_EOC_

    $block->set_value("http_config", $extra_http_config);

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }

    if (!$block->error_log && !$block->no_error_log) {
        $block->set_value("no_error_log", "[error]\n[alert]");
    }
});

run_tests;

__DATA__

=== TEST 1: setup route with plugin hang-worker-killer
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
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



=== TEST 2: verify metadata not configurated
--- timeout: 3s
--- config
    location /t {
        content_by_lua_block {
            ngx.sleep(2)
            ngx.say("hello world")
        }
    }
--- response_body
hello world
--- request
GET /t
--- error_log
please set the correct plugin_metadata for hang-worker-killer



=== TEST 3: set plugin metadata
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/plugin_metadata/hang-worker-killer',
                ngx.HTTP_PUT,
                [[{
                    "enabled": true,
                    "interval": 2,
                    "continuous": 2,
                    "max_cpu_percent": 0.6
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



=== TEST 4: hit the route to verify QPS collecting
--- timeout: 3s
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            t('/hello')
            t('/hello')
            t('/hello')

            -- sleep for counter sync
            ngx.sleep(0.1)

            local shared_qps = ngx.shared["plugin-hang-worker-killer-qps"]
            local keys = shared_qps:get_keys()
            for _, key in ipairs(keys) do
                ngx.say(shared_qps:get(key))
            end
        }
    }
--- response_body
3



=== TEST 5: test split_proc_stat
--- config
    location /t {
        content_by_lua_block {
            local cpu = require("apisix.plugins.hang-worker-killer.cpu")
            local t = require("lib.test_admin")
            local data = t.read_file("t/testdata/cpu/first/4842/stat")
            local arr = cpu.split_proc_stat(data)

            ngx.say("pid:" .. arr[1] .. " name:" .. arr[2] .. " utime:" .. arr[14] .. " stime:" .. arr[15])
        }
    }
--- request
GET /t
--- response_body
pid:4842  name:openresty utime:0 stime:11



=== TEST 6: test worker_cpu_times
--- config
    location /t {
        content_by_lua_block {
            local cpu = require("apisix.plugins.hang-worker-killer.cpu")
            cpu.proc_path = "t/testdata/cpu/first"
            local t, err = cpu.worker_cpu_times("4842")
            if err then
                ngx.say("failed: ", err)
            end

            ngx.say(t)
        }
    }
--- request
GET /t
--- response_body
11



=== TEST 7: test cpu_times
--- config
    location /t {
        content_by_lua_block {
            local cpu = require("apisix.plugins.hang-worker-killer.cpu")
            cpu.proc_path = "t/testdata/cpu/first"
            local t, err = cpu.cpu_times()
            if err then
                ngx.say("failed: ", err)
            end

            ngx.say(t)
        }
    }
--- request
GET /t
--- response_body
83861044



=== TEST 8: check CPU monitor
--- timeout: 6s
--- config
    location /t {
        content_by_lua_block {
            ngx.sleep(5)
            ngx.say("hello world")
        }
    }
--- response_body
hello world
--- request
GET /t
--- error_log
first init monitor time is
not reach the next monitor time
check worker hang, worker pid
count of workers that exceed cpu limit



=== TEST 9: set plugin metadata
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/plugin_metadata/hang-worker-killer',
                ngx.HTTP_PUT,
                [[{
                    "enabled": true,
                    "interval": 2,
                    "continuous": 2,
                    "max_cpu_percent": 0.6
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



=== TEST 10: set plugin metadata
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/plugin_metadata/hang-worker-killer',
                ngx.HTTP_PUT,
                [[{
                    "enabled": true,
                    "interval": 3,
                    "continuous": 3,
                    "max_cpu_percent": 0.6
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



=== TEST 11: set route
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



=== TEST 12: hit the route, trigger high CPU usage and kill the worker
--- timeout: 20
--- request
GET /hello?burn_sec=11 HTTP/1.1
--- response_body
hello world
--- error_log
send TERM signal to worker process



=== TEST 13: update plugin metadata to test (exceed CPU usage limit but reach min QPS at the same time)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/plugin_metadata/hang-worker-killer',
                ngx.HTTP_PUT,
                [[{
                    "enabled": true,
                    "interval": 1,
                    "continuous": 2,
                    "max_cpu_percent": 0,
                    "min_qps": 5
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



=== TEST 14: hit the route, trigger high CPU usage but not kill the worker
--- timeout: 5s
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            ngx.update_time()
            local stop_time = ngx.time() + 4

            while true do
                ngx.update_time()
                local now_time = ngx.time()
                if now_time > stop_time then
                    break
                end

                t('/hello')
                ngx.sleep(0.02)
            end

            ngx.say("done")
        }
    }
--- response_body
done
--- error_log
determined non-hang process, because QPS reached the set min_qps



=== TEST 15: update plugin metadata to disabled monitor
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/plugin_metadata/hang-worker-killer',
                ngx.HTTP_PUT,
                [[{
                    "enabled": false
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



=== TEST 16: hit the route to verify monitor disabled
--- timeout: 2s
--- config
    location /t {
        content_by_lua_block {
            ngx.sleep(1)
            ngx.say("hello world")
        }
    }
--- response_body
hello world
--- request
GET /t
--- error_log
hang worker monitor disabled
