#!/usr/bin/env bash

#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

. ./t/cli/common.sh

# apisix test
git checkout conf/config.yaml

out=$(./bin/apisix test 2>&1 || true)
if ! echo "$out" | grep "configuration test is successful"; then
    echo "failed: configuration test should be successful"
    exit 1
fi

echo "pass: apisix test"

echo '
nginx_config:
    main_configuration_snippet: |
        notexist on;
' > conf/config.yaml

out=$(./bin/apisix test 2>&1 || true)
if ! echo "$out" | grep "configuration test failed"; then
    echo "failed: should test failed when configuration invalid"
    exit 1
fi

echo "passed: apisix test(failure scenario)"

# apisix stop and restart
git checkout conf/config.yaml

./bin/apisix start
sleep 1 # wait for apisix starts

echo '
nginx_config:
    main_configuration_snippet: |
        notexist on;
' > conf/config.yaml

out=$(./bin/apisix stop 2>&1 || true)
if ! echo "$out" | grep "[emerg] unknown directive \"notexist\""; then
    echo "failed: should stop failed when configuration invalid"
    exit 1
fi

echo "passed: apisix stop"


out=$(./bin/apisix stop 2>&1 || true)
if ! (echo "$out" | grep "[emerg] unknown directive \"notexist\"") && ! (echo "$out" | grep "APISIX is running"); then
    echo "failed: should restart failed when configuration invalid"
    exit 1
fi

echo "passed: apisix restart"

git checkout conf/config.yaml
./bin/apisix stop
