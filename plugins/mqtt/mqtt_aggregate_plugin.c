/**
 * NEURON IIoT System for Industry 4.0
 * Copyright (C) 2020-2024 EMQ Technologies Co., Ltd All rights reserved.
 **/

#include "mqtt_plugin_intf.h"

#define DESCRIPTION "Northbound MQTT plugin with raw batch and window aggregation."
#define DESCRIPTION_ZH "支持原始批量和窗口聚合的北向应用 MQTT 插件"

const neu_plugin_module_t neu_plugin_module = {
    .version         = NEURON_PLUGIN_VER_1_0,
    .schema          = "mqtt-aggregate",
    .module_name     = "MQTT Aggregate",
    .module_descr    = DESCRIPTION,
    .module_descr_zh = DESCRIPTION_ZH,
    .intf_funs       = &mqtt_plugin_intf_funs,
    .kind            = NEU_PLUGIN_KIND_SYSTEM,
    .type            = NEU_NA_TYPE_APP,
    .display         = true,
    .single          = false,
};
