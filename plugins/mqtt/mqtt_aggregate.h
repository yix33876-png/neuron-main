/**
 * NEURON IIoT System for Industry 4.0
 * MQTT northbound aggregation extension.
 **/

#ifndef NEURON_PLUGIN_MQTT_AGGREGATE_H
#define NEURON_PLUGIN_MQTT_AGGREGATE_H

#ifdef __cplusplus
extern "C" {
#endif

#include "neuron.h"

int  mqtt_aggregate_handle_trans_data(neu_plugin_t *            plugin,
                                      neu_reqresp_trans_data_t *trans_data);
int  mqtt_aggregate_start_timer(neu_plugin_t *plugin);
void mqtt_aggregate_stop_timer(neu_plugin_t *plugin);
void mqtt_aggregate_free(neu_plugin_t *plugin);

#ifdef __cplusplus
}
#endif

#endif
