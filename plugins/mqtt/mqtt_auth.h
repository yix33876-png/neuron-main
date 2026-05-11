/**
 * NEURON IIoT System for Industry 4.0
 * Payload authentication extension for MQTT northbound publishing.
 **/

#ifndef NEURON_PLUGIN_MQTT_AUTH_H
#define NEURON_PLUGIN_MQTT_AUTH_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

#include "mqtt_plugin.h"

char *mqtt_auth_add_fields(neu_plugin_t *plugin, const char *payload,
                           size_t payload_len);

#ifdef __cplusplus
}
#endif

#endif
