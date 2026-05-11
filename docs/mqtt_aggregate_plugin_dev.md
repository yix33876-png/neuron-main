# Neuron MQTT Aggregate 聚合插件开发文档

## 1. 背景

当前 Neuron 北向 MQTT 的实际上报粒度是 `driver + group`。

在 RK3506 当前数据模型里：

```text
DTU01 = 一个 DTU
th01  = 第一个传感器，例如温湿度传感器
th01 下的 tag = 温度、湿度
th02  = 第二个传感器
th02 下的 tag = 该传感器自己的属性
```

原始上报是每个传感器 group 单独一条 MQTT 消息：

```text
DTU01/th01 -> 一条 MQTT 消息
DTU01/th02 -> 一条 MQTT 消息
DTU01/th03 -> 一条 MQTT 消息
```

本次新增 `MQTT Aggregate` 北向插件，用于把同一个 DTU 下多个传感器 group 的数据按窗口进行批量或聚合上报。

## 2. 功能范围

插件支持三种聚合模式：

| 模式值 | 模式名 | 说明 |
| --- | --- | --- |
| `1` | `raw_batch` | 一个 DTU 下多个传感器原始数据批量上传 |
| `2` | `agg_single_sensor` | 单个传感器窗口聚合上传，计算 avg/max/min |
| `3` | `agg_multi_sensor` | 一个 DTU 下多个传感器窗口聚合上传，计算 avg/max/min |

另外保留：

| 模式值 | 模式名 | 说明 |
| --- | --- | --- |
| `0` | `disabled` | 关闭聚合，走原 MQTT 上报逻辑 |

## 3. 设计原则

### 3.1 不等待所有传感器强制到齐

工业现场里不同传感器可能有不同采集周期，也可能离线或采集失败。因此不能用“等所有传感器都到齐才发”的设计。

当前策略是：

```text
窗口到期就发
收到的传感器标记 ok
窗口内没收到但之前收到过的标记 stale
从未收到或超过超时时间的标记 missing
采集返回错误的标记 error
```

这样不会因为一个传感器异常而阻塞整个 DTU 的上报。

### 3.2 期望传感器列表来自订阅关系

插件通过当前北向节点的订阅表 `route_tbl` 判断一个 DTU 下有哪些传感器 group。

例如当前订阅：

```text
aggtest -> DTU01/th01
aggtest -> DTU01/th02
```

则 `DTU01` 的期望传感器列表就是：

```text
th01
th02
```

## 4. 输出格式

### 4.1 raw_batch

`raw_batch` 是一个 DTU 在一个窗口内的原始传感器快照集合。

示例：

```json
{
  "type": "raw_batch",
  "node": "DTU01",
  "timestamp": 1778042000000,
  "window": {
    "start": 1778041998000,
    "end": 1778042000000
  },
  "complete": false,
  "sensors": [
    {
      "sensor": "th01",
      "status": "ok",
      "timestamp": 1778041999100,
      "values": {
        "温度": 25.8,
        "湿度": 62.9
      }
    },
    {
      "sensor": "th02",
      "status": "missing"
    }
  ],
  "keylink": "HMAC-SHA256签名"
}
```

字段说明：

| 字段 | 说明 |
| --- | --- |
| `type` | 固定为 `raw_batch` |
| `node` | DTU 名称 |
| `window.start` | 当前批次窗口开始时间，毫秒 |
| `window.end` | 当前批次窗口结束时间，毫秒 |
| `complete` | 期望传感器是否全部在窗口内到达 |
| `sensors[].sensor` | 传感器 group 名称 |
| `sensors[].status` | `ok`、`stale`、`missing`、`error` |
| `sensors[].values` | 传感器最新原始属性值 |
| `keylink` | 可选，启用鉴权后追加 |

### 4.2 agg_single_sensor

`agg_single_sensor` 对单个传感器 group 下的数值 tag 做窗口聚合。

示例：

```json
{
  "type": "agg_single_sensor",
  "node": "DTU01",
  "sensor": "th01",
  "window": {
    "start": 1778041940000,
    "end": 1778042000000
  },
  "status": "ok",
  "metrics": {
    "温度": {
      "count": 60,
      "avg": 25.6,
      "max": 26.0,
      "min": 25.1
    },
    "湿度": {
      "count": 60,
      "avg": 62.5,
      "max": 63.0,
      "min": 61.9
    }
  },
  "keylink": "HMAC-SHA256签名"
}
```

### 4.3 agg_multi_sensor

`agg_multi_sensor` 对一个 DTU 下多个传感器 group 统一做窗口聚合。

示例：

```json
{
  "type": "agg_multi_sensor",
  "node": "DTU01",
  "window": {
    "start": 1778041940000,
    "end": 1778042000000
  },
  "complete": true,
  "sensors": {
    "th01": {
      "status": "ok",
      "last_timestamp": 1778041999100,
      "metrics": {
        "温度": {
          "count": 60,
          "avg": 25.6,
          "max": 26.0,
          "min": 25.1
        },
        "湿度": {
          "count": 60,
          "avg": 62.5,
          "max": 63.0,
          "min": 61.9
        }
      }
    },
    "th02": {
      "status": "ok",
      "last_timestamp": 1778041999300,
      "metrics": {
        "温度": {
          "count": 60,
          "avg": 26.4,
          "max": 26.9,
          "min": 26.0
        }
      }
    }
  },
  "keylink": "HMAC-SHA256签名"
}
```

## 5. 状态语义

| 状态 | 说明 |
| --- | --- |
| `ok` | 当前窗口内收到该传感器数据，且无错误 |
| `stale` | 当前窗口内没收到，但之前收到过，且未超过 `sensor-timeout-ms` |
| `missing` | 从未收到，或距离上次收到已超过 `sensor-timeout-ms` |
| `error` | 当前传感器数据中存在 Neuron tag error |

`complete` 的含义：

```text
true  = 当前窗口内所有已订阅传感器都到达
false = 至少一个已订阅传感器未在当前窗口内到达
```

## 6. 聚合计算规则

当前 `avg/max/min` 只计算数值类型：

```text
int8 / uint8
int16 / uint16 / word
int32 / uint32 / dword
int64 / uint64 / lword
float / double
```

不参与 avg/max/min 的类型：

```text
bool
string
bytes
array
custom json
error
```

非数值 tag：

- 在 `raw_batch` 中可以出现在 `values`。
- 在 `agg_single_sensor` 和 `agg_multi_sensor` 的 `metrics` 中会被跳过。

窗口结束后，统计值会清零，下一窗口重新累计：

```text
count = 0
sum = 0
min = 0
max = 0
```

传感器的 latest values 会保留，用于判断 `stale` 和 `missing`。

## 7. 配置项

新增配置项位于：

```text
plugins/mqtt/mqtt.json
plugins/mqtt/mqtt-aggregate.json
```

核心配置：

```json
{
  "aggregate-mode": 1,
  "aggregate-window-ms": 60000,
  "sensor-timeout-ms": 180000,
  "emit-partial": true,
  "aggregate-topic": "neuron/${node}/aggregate",
  "aggregate-sensor": "",
  "auth-enable": true,
  "keylink": "abcef13t6222t",
  "auth-secret": "abcef13t6222t"
}
```

字段说明：

| 字段 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `aggregate-mode` | map/int | `MQTT` 为 0，`MQTT Aggregate` 为 1 | 聚合模式 |
| `aggregate-window-ms` | int | `60000` | 聚合窗口长度，毫秒 |
| `sensor-timeout-ms` | int | `180000` | 传感器超时时间，毫秒 |
| `emit-partial` | bool | `true` | 是否允许不完整窗口上报 |
| `aggregate-topic` | string | `neuron/${node}/aggregate` | 聚合消息发布 topic，`${node}` 会替换成 DTU 名称 |
| `aggregate-sensor` | string | 空 | `agg_single_sensor` 模式下指定单个传感器 group；为空时使用第一个订阅 group |

`aggregate-mode` 取值：

| 值 | 模式 |
| --- | --- |
| `0` | `disabled` |
| `1` | `raw_batch` |
| `2` | `agg_single_sensor` |
| `3` | `agg_multi_sensor` |

## 8. 鉴权关系

聚合插件复用了 `mqtt_auth_add_fields()`。

如果配置：

```json
"auth-enable": true
```

聚合后的 payload 会继续追加：

```json
"keylink": "HMAC-SHA256签名"
```

不会追加 `id` 和 `v`。

执行顺序：

```text
trans_data
  -> 更新聚合缓存
  -> 窗口到期生成 raw_batch / agg payload
  -> mqtt_auth_add_fields()
  -> publish()
```

## 9. 源码改动

### 9.1 新增文件

```text
plugins/mqtt/mqtt_aggregate.c
plugins/mqtt/mqtt_aggregate.h
plugins/mqtt/mqtt_aggregate_plugin.c
plugins/mqtt/mqtt-aggregate.json
```

说明：

- `mqtt_aggregate.c`：聚合缓存、窗口 flush、payload 生成和发布。
- `mqtt_aggregate.h`：聚合模块对外接口。
- `mqtt_aggregate_plugin.c`：定义 `MQTT Aggregate` 插件模块。
- `mqtt-aggregate.json`：插件 schema。

### 9.2 修改文件

```text
plugins/mqtt/CMakeLists.txt
plugins/mqtt/mqtt_config.c
plugins/mqtt/mqtt_config.h
plugins/mqtt/mqtt_handle.c
plugins/mqtt/mqtt_plugin.h
plugins/mqtt/mqtt_plugin_intf.c
plugins/mqtt/mqtt.json
default_plugins.json
```

说明：

- `CMakeLists.txt`：新增 `plugin-mqtt-aggregate` 构建目标。
- `mqtt_config.c/h`：新增聚合配置解析和保存。
- `mqtt_handle.c`：聚合模式下拦截 `handle_trans_data()`，不再走原单 group publish。
- `mqtt_plugin.h`：新增 `aggregate_timer` 和 `aggregate_state`。
- `mqtt_plugin_intf.c`：插件 config/start/stop/uninit 时启动或停止聚合定时器、释放缓存。
- `mqtt.json`：原 MQTT 插件也可通过配置启用聚合，默认关闭。
- `default_plugins.json`：默认加载 `libplugin-mqtt-aggregate.so`。

## 10. 核心实现流程

### 10.1 数据输入

Neuron 北向插件收到的数据类型是：

```c
neu_reqresp_trans_data_t
```

关键字段：

```c
char *driver;  // DTU，例如 DTU01
char *group;   // 传感器，例如 th01
UT_array *tags; // 传感器属性，例如 温度、湿度
```

### 10.2 缓存结构

聚合缓存结构：

```text
aggregate_state
  window_start
  sensors hash

sensor key = driver + group
  last_ts
  latest_values
  latest_errors
  tags hash

tag key = tag name
  latest
  count
  sum
  min
  max
```

### 10.3 收到数据时

```text
mqtt_aggregate_handle_trans_data()
  -> update_sensor()
  -> 更新 latest_values/latest_errors
  -> 数值 tag 更新 count/sum/min/max
```

### 10.4 窗口到期时

聚合定时器按 `aggregate-window-ms` 周期触发：

```text
aggregate_timer_cb()
  -> flush_locked()
  -> raw_batch / agg_single_sensor / agg_multi_sensor
  -> publish_json()
```

`publish_json()` 内部会：

```text
json_dumps()
  -> 如果 auth-enable=true，调用 mqtt_auth_add_fields()
  -> 替换 ${node} 生成 topic
  -> publish()
```

## 11. 编译

RK3506 是 ARMHF/armv7l，使用：

```text
arm-linux-gnueabihf
```

编译命令：

```bash
cd /home/swlts/neuron-main
export STAGING=$HOME/neuron-staging/arm-linux-gnueabihf

cmake -S . -B build-armhf \
  -DCMAKE_TOOLCHAIN_FILE=cmake/arm-linux-gnueabihf.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DDISABLE_UT=ON \
  -DDISABLE_ASAN=ON \
  -DDISABLE_WERROR=ON \
  -DENABLE_DATALAYERS=OFF

cmake --build build-armhf \
  --target plugin-mqtt plugin-mqtt-auth plugin-mqtt-aggregate \
  -j"$(nproc)"
```

产物：

```text
build-armhf/plugins/libplugin-mqtt.so
build-armhf/plugins/libplugin-mqtt-auth.so
build-armhf/plugins/libplugin-mqtt-aggregate.so
build-armhf/plugins/schema/mqtt.json
build-armhf/plugins/schema/mqtt-auth.json
build-armhf/plugins/schema/mqtt-aggregate.json
```

检查架构：

```bash
file build-armhf/plugins/libplugin-mqtt-aggregate.so
```

预期：

```text
ELF 32-bit
ARM
EABI5
```

## 12. 部署到 RK3506

部署 `.so`：

```bash
sshpass -p root scp -o StrictHostKeyChecking=no \
  build-armhf/plugins/libplugin-mqtt.so \
  build-armhf/plugins/libplugin-mqtt-auth.so \
  build-armhf/plugins/libplugin-mqtt-aggregate.so \
  root@192.168.9.10:/opt/neuron/plugins/
```

部署 schema：

```bash
sshpass -p root scp -o StrictHostKeyChecking=no \
  plugins/mqtt/mqtt.json \
  plugins/mqtt/mqtt-auth.json \
  plugins/mqtt/mqtt-aggregate.json \
  root@192.168.9.10:/opt/neuron/plugins/schema/
```

部署默认插件列表：

```bash
sshpass -p root scp -o StrictHostKeyChecking=no \
  default_plugins.json \
  root@192.168.9.10:/opt/neuron/config/default_plugins.json
```

重启 Neuron：

```bash
sshpass -p root ssh -o StrictHostKeyChecking=no root@192.168.9.10

if pidof neuron >/dev/null 2>&1; then kill $(pidof neuron); fi

cd /opt/neuron
LD_LIBRARY_PATH=/opt/neuron/lib ./neuron \
  --config_dir /opt/neuron/config \
  --plugin_dir /opt/neuron/plugins \
  -d
```

检查插件是否加载：

```bash
grep -n "MQTT Aggregate\\|libplugin-mqtt-aggregate" /opt/neuron/logs/neuron.log
```

预期日志：

```text
add plugin, name: MQTT Aggregate, library: libplugin-mqtt-aggregate.so
load plugin success, lib:libplugin-mqtt-aggregate.so
```

## 13. 创建聚合北向节点

可以新建一个北向节点，例如：

```text
aggtest
```

插件选择：

```text
MQTT Aggregate
```

示例配置：

```json
{
  "version": 5,
  "client-id": "aggtest_client",
  "qos": 0,
  "format": 0,
  "upload_err": true,
  "host": "192.168.9.10",
  "port": 1883,
  "username": "",
  "password": "",
  "ssl": false,
  "auth-enable": true,
  "keylink": "abcef13t6222t",
  "auth-secret": "abcef13t6222t",
  "aggregate-mode": 1,
  "aggregate-window-ms": 2000,
  "sensor-timeout-ms": 5000,
  "emit-partial": true,
  "aggregate-topic": "neuron/${node}/aggregate",
  "enable_topic": false,
  "write-req-topic": "neuron/aggtest/write/req",
  "write-resp-topic": "neuron/aggtest/write/resp",
  "driver-topic-prefix": "neuron/aggtest",
  "upload_drv_state": false,
  "upload_drv_state_topic": "neuron/aggtest/state/update",
  "upload_drv_state_interval": 1,
  "offline-cache": false,
  "cache-sync-interval": 100
}
```

订阅 DTU 下的传感器 group：

```json
{
  "app": "aggtest",
  "driver": "DTU01",
  "group": "th01",
  "params": {
    "topic": "neuron/unused/th01"
  }
}
```

```json
{
  "app": "aggtest",
  "driver": "DTU01",
  "group": "th02",
  "params": {
    "topic": "neuron/unused/th02"
  }
}
```

注意：聚合模式下最终发布 topic 使用 `aggregate-topic`，订阅参数里的 `topic` 只是为了兼容 Neuron MQTT 订阅参数解析。

## 14. 验证

订阅聚合 topic：

```bash
mosquitto_sub -h 192.168.9.10 -p 1883 -t 'neuron/+/aggregate' -v
```

或订阅所有 Neuron topic：

```bash
mosquitto_sub -h 192.168.9.10 -p 1883 -t 'neuron/#' -v
```

检查节点状态：

```bash
curl -s "http://192.168.9.10:7000/api/v2/node/state?node=aggtest" \
  -H "Authorization: Bearer $TOKEN"
```

预期：

```json
{
  "running": 3,
  "link": 1,
  "sub_group_count": 2
}
```

检查配置日志：

```bash
tail -120 /opt/neuron/logs/aggtest.log | grep -E "aggregate|auth|route"
```

预期包含：

```text
config aggregate-mode  : 1
config aggregate-window-ms : 2000
config sensor-timeout-ms   : 5000
config aggregate-topic     : neuron/${node}/aggregate
route driver:DTU01 group:th01
route driver:DTU01 group:th02
```

## 15. 当前验证状态

已经完成：

- ARMHF 编译通过。
- `libplugin-mqtt-aggregate.so` 部署到 RK3506。
- Neuron 重启后成功加载 `MQTT Aggregate` 插件。
- 临时创建 `aggtest` 节点后，配置解析成功。
- 临时订阅 `DTU01/th01` 和 `DTU01/th02` 成功。
- 验证后已删除临时 `aggtest` 节点，未保留测试节点。

注意：

现场 DTU 在验证时没有持续吐出新的 MQTT 周期上报，因此未完成真实传感器数据的端到端聚合 payload 抓包。代码层面和插件加载层面已经验证通过。

## 16. 使用建议

建议按以下顺序上线：

1. 新建独立 `MQTT Aggregate` 北向节点，不直接改现有 `nanomq`。
2. 先使用 `raw_batch`，窗口设置为 `2000` 到 `5000` ms，确认 DTU 级批量消息格式。
3. 再切换 `agg_multi_sensor`，窗口设置为 `60000` ms，确认 avg/max/min。
4. 最后按需要启用 `agg_single_sensor`，指定 `aggregate-sensor`。
5. 保持 `emit-partial=true`，避免单个传感器离线阻塞整个 DTU 上报。
6. 生产环境配置 `auth-secret`，让聚合 payload 继续带 `keylink`。



sshpass -p root scp \
  build-arm64/plugins/libplugin-mqtt-auth.so \
  build-arm64/plugins/libplugin-mqtt-aggregate.so \
  root@192.168.9.10:/opt/neuron/plugins/

scp /home/swlts/nanomq-master/build-rk3506/nanomq/nanomq root@192.168.142.159:/usr/local/bin/
scp -r /home/swlts/nanomq-master/etc mqtt@192.168.142.159:/etc/nanomq







ssh mqtt@192.168.142.159 'mkdir -p /home/mqtt/nanomq/bin /home/mqtt/nanomq/etc /home/mqtt/nanomq/log /home/mqtt/nanomq/data'

scp /home/swlts/nanomq-master/build-rpi-cm4/nanomq/nanomq \
  mqtt@192.168.142.159:/home/mqtt/nanomq/bin/

scp -r /home/swlts/nanomq-master/etc \
  mqtt@192.168.142.159:/home/mqtt/nanomq/etc/


chmod +x /home/mqtt/nanomq/bin/nanomq
/home/mqtt/nanomq/bin/nanomq start --conf /home/mqtt/nanomq/etc/nanomq.conf