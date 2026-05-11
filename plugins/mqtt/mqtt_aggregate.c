/**
 * NEURON IIoT System for Industry 4.0
 * MQTT northbound aggregation extension.
 **/

#include <float.h>
#include <math.h>
#include <pthread.h>
#include <string.h>

#include <jansson.h>

#include "mqtt_aggregate.h"
#include "mqtt_auth.h"
#include "mqtt_handle.h"
#include "mqtt_plugin.h"
#include "utils/asprintf.h"
#include "utils/time.h"

typedef struct aggregate_tag {
    char *tag;
    bool  numeric;
    bool  latest_is_error;
    int64_t error;
    json_t *latest;

    uint64_t count;
    double   sum;
    double   min;
    double   max;

    UT_hash_handle hh;
} aggregate_tag_t;

typedef struct aggregate_sensor {
    route_key_t key;
    int64_t     last_ts;
    json_t *    latest_values;
    json_t *    latest_errors;
    aggregate_tag_t *tags;

    UT_hash_handle hh;
} aggregate_sensor_t;

typedef struct aggregate_state {
    pthread_mutex_t     mtx;
    bool                inited;
    int64_t             window_start;
    aggregate_sensor_t *sensors;
} aggregate_state_t;

static aggregate_state_t *get_state(neu_plugin_t *plugin)
{
    aggregate_state_t *state = plugin->aggregate_state;
    if (state == NULL) {
        state = calloc(1, sizeof(*state));
        if (state == NULL) {
            return NULL;
        }
        pthread_mutex_init(&state->mtx, NULL);
        plugin->aggregate_state = state;
    }
    return state;
}

static void tag_free(aggregate_tag_t *tag)
{
    free(tag->tag);
    json_decref(tag->latest);
    free(tag);
}

static void sensor_free(aggregate_sensor_t *sensor)
{
    aggregate_tag_t *tag = NULL, *tmp = NULL;
    HASH_ITER(hh, sensor->tags, tag, tmp)
    {
        HASH_DEL(sensor->tags, tag);
        tag_free(tag);
    }
    json_decref(sensor->latest_values);
    json_decref(sensor->latest_errors);
    free(sensor);
}

void mqtt_aggregate_free(neu_plugin_t *plugin)
{
    aggregate_state_t *state = plugin->aggregate_state;
    if (state == NULL) {
        return;
    }

    pthread_mutex_lock(&state->mtx);
    aggregate_sensor_t *sensor = NULL, *tmp = NULL;
    HASH_ITER(hh, state->sensors, sensor, tmp)
    {
        HASH_DEL(state->sensors, sensor);
        sensor_free(sensor);
    }
    pthread_mutex_unlock(&state->mtx);

    pthread_mutex_destroy(&state->mtx);
    free(state);
    plugin->aggregate_state = NULL;
}

static aggregate_sensor_t *sensor_get(aggregate_state_t *state,
                                      const char *driver, const char *group,
                                      bool create)
{
    route_key_t key    = { 0 };
    aggregate_sensor_t *sensor = NULL;

    strncpy(key.driver, driver, sizeof(key.driver));
    strncpy(key.group, group, sizeof(key.group));
    HASH_FIND(hh, state->sensors, &key, sizeof(key), sensor);
    if (sensor || !create) {
        return sensor;
    }

    sensor = calloc(1, sizeof(*sensor));
    if (sensor == NULL) {
        return NULL;
    }
    sensor->key           = key;
    sensor->latest_values = json_object();
    sensor->latest_errors = json_object();
    if (sensor->latest_values == NULL || sensor->latest_errors == NULL) {
        sensor_free(sensor);
        return NULL;
    }
    HASH_ADD(hh, state->sensors, key, sizeof(sensor->key), sensor);
    return sensor;
}

static aggregate_tag_t *tag_get(aggregate_sensor_t *sensor, const char *name,
                                bool create)
{
    aggregate_tag_t *tag = NULL;
    HASH_FIND_STR(sensor->tags, name, tag);
    if (tag || !create) {
        return tag;
    }

    tag = calloc(1, sizeof(*tag));
    if (tag == NULL) {
        return NULL;
    }
    tag->tag = strdup(name);
    if (tag->tag == NULL) {
        free(tag);
        return NULL;
    }
    HASH_ADD_KEYPTR(hh, sensor->tags, tag->tag, strlen(tag->tag), tag);
    return tag;
}

static bool dvalue_number(const neu_dvalue_t *value, double *out)
{
    switch (value->type) {
    case NEU_TYPE_INT8:
        *out = value->value.i8;
        return true;
    case NEU_TYPE_UINT8:
        *out = value->value.u8;
        return true;
    case NEU_TYPE_INT16:
        *out = value->value.i16;
        return true;
    case NEU_TYPE_UINT16:
    case NEU_TYPE_WORD:
        *out = value->value.u16;
        return true;
    case NEU_TYPE_INT32:
        *out = value->value.i32;
        return true;
    case NEU_TYPE_UINT32:
    case NEU_TYPE_DWORD:
        *out = value->value.u32;
        return true;
    case NEU_TYPE_INT64:
        *out = (double) value->value.i64;
        return true;
    case NEU_TYPE_UINT64:
    case NEU_TYPE_LWORD:
        *out = (double) value->value.u64;
        return true;
    case NEU_TYPE_FLOAT:
        if (isnan(value->value.f32)) {
            return false;
        }
        *out = value->value.f32;
        return true;
    case NEU_TYPE_DOUBLE:
        if (isnan(value->value.d64)) {
            return false;
        }
        *out = value->value.d64;
        return true;
    default:
        return false;
    }
}

static json_t *dvalue_json(const neu_dvalue_t *value)
{
    switch (value->type) {
    case NEU_TYPE_INT8:
        return json_integer(value->value.i8);
    case NEU_TYPE_UINT8:
        return json_integer(value->value.u8);
    case NEU_TYPE_INT16:
        return json_integer(value->value.i16);
    case NEU_TYPE_UINT16:
    case NEU_TYPE_WORD:
        return json_integer(value->value.u16);
    case NEU_TYPE_INT32:
        return json_integer(value->value.i32);
    case NEU_TYPE_UINT32:
    case NEU_TYPE_DWORD:
        return json_integer(value->value.u32);
    case NEU_TYPE_INT64:
        return json_integer(value->value.i64);
    case NEU_TYPE_UINT64:
    case NEU_TYPE_LWORD:
        return json_integer((json_int_t) value->value.u64);
    case NEU_TYPE_FLOAT:
        if (isnan(value->value.f32)) {
            return NULL;
        }
        return json_real(value->value.f32);
    case NEU_TYPE_DOUBLE:
        if (isnan(value->value.d64)) {
            return NULL;
        }
        return json_real(value->value.d64);
    case NEU_TYPE_BOOL:
        return json_boolean(value->value.boolean);
    case NEU_TYPE_BIT:
        return json_integer(value->value.u8);
    case NEU_TYPE_STRING:
    case NEU_TYPE_TIME:
    case NEU_TYPE_DATA_AND_TIME:
    case NEU_TYPE_ARRAY_CHAR:
        return json_string(value->value.str);
    default:
        return NULL;
    }
}

static void update_stat(aggregate_tag_t *tag, double val)
{
    if (tag->count == 0) {
        tag->min = val;
        tag->max = val;
    } else {
        if (val < tag->min) {
            tag->min = val;
        }
        if (val > tag->max) {
            tag->max = val;
        }
    }
    tag->count++;
    tag->sum += val;
    tag->numeric = true;
}

static int update_sensor(neu_plugin_t *plugin,
                         neu_reqresp_trans_data_t *trans_data)
{
    aggregate_state_t *state = get_state(plugin);
    if (state == NULL) {
        return NEU_ERR_EINTERNAL;
    }

    int64_t now = global_timestamp > 0 ? global_timestamp : neu_time_ms();
    if (!state->inited) {
        state->window_start = now;
        state->inited       = true;
    }

    aggregate_sensor_t *sensor =
        sensor_get(state, trans_data->driver, trans_data->group, true);
    if (sensor == NULL) {
        return NEU_ERR_EINTERNAL;
    }

    sensor->last_ts = now;
    json_object_clear(sensor->latest_values);
    json_object_clear(sensor->latest_errors);

    utarray_foreach(trans_data->tags, neu_resp_tag_value_meta_t *, tag_value)
    {
        aggregate_tag_t *tag = tag_get(sensor, tag_value->tag, true);
        if (tag == NULL) {
            return NEU_ERR_EINTERNAL;
        }

        json_t *latest = NULL;
        if (tag_value->value.type == NEU_TYPE_ERROR) {
            tag->latest_is_error = true;
            tag->error           = tag_value->value.value.i32;
            json_object_set_new(sensor->latest_errors, tag_value->tag,
                                json_integer(tag->error));
            latest = json_integer(tag->error);
        } else {
            double val = 0;
            if (dvalue_number(&tag_value->value, &val)) {
                update_stat(tag, val);
            }
            latest = dvalue_json(&tag_value->value);
            if (latest != NULL) {
                tag->latest_is_error = false;
                json_object_set(sensor->latest_values, tag_value->tag, latest);
            }
        }

        if (latest != NULL) {
            json_decref(tag->latest);
            tag->latest = latest;
        }
    }

    return NEU_ERR_SUCCESS;
}

static char *topic_for_driver(const char *pattern, const char *driver)
{
    const char *needle = "${node}";
    const char *pos    = strstr(pattern, needle);
    char *      topic  = NULL;

    if (pos == NULL) {
        return strdup(pattern);
    }

    size_t prefix = (size_t)(pos - pattern);
    size_t suffix = strlen(pos + strlen(needle));
    topic         = calloc(1, prefix + strlen(driver) + suffix + 1);
    if (topic == NULL) {
        return NULL;
    }
    memcpy(topic, pattern, prefix);
    strcpy(topic + prefix, driver);
    strcpy(topic + prefix + strlen(driver), pos + strlen(needle));
    return topic;
}

static bool driver_seen(char drivers[][NEU_NODE_NAME_LEN], size_t n,
                        const char *driver)
{
    for (size_t i = 0; i < n; i++) {
        if (0 == strcmp(drivers[i], driver)) {
            return true;
        }
    }
    return false;
}

static bool route_current_window(aggregate_sensor_t *sensor,
                                 int64_t window_start)
{
    return sensor != NULL && sensor->last_ts >= window_start;
}

static const char *sensor_status(aggregate_sensor_t *sensor,
                                 int64_t window_start, int64_t now,
                                 uint32_t timeout_ms)
{
    if (sensor == NULL || sensor->last_ts <= 0 ||
        (timeout_ms > 0 && now - sensor->last_ts > timeout_ms)) {
        return "missing";
    }
    if (sensor->last_ts < window_start) {
        return "stale";
    }
    if (json_object_size(sensor->latest_errors) > 0) {
        return "error";
    }
    return "ok";
}

static json_t *raw_sensor_json(route_entry_t *route, aggregate_sensor_t *sensor,
                               int64_t window_start, int64_t now,
                               uint32_t timeout_ms)
{
    const char *status = sensor_status(sensor, window_start, now, timeout_ms);
    json_t *    root   = json_object();
    if (root == NULL) {
        return NULL;
    }

    json_object_set_new(root, "sensor", json_string(route->key.group));
    json_object_set_new(root, "status", json_string(status));
    if (sensor != NULL && sensor->last_ts > 0) {
        json_object_set_new(root, "timestamp", json_integer(sensor->last_ts));
        json_object_set(root, "values", sensor->latest_values);
        if (json_object_size(sensor->latest_errors) > 0) {
            json_object_set(root, "errors", sensor->latest_errors);
        }
    }
    return root;
}

static json_t *metrics_from_sensor(aggregate_sensor_t *sensor)
{
    json_t *metrics = json_object();
    if (metrics == NULL || sensor == NULL) {
        return metrics;
    }

    aggregate_tag_t *tag = NULL, *tmp = NULL;
    HASH_ITER(hh, sensor->tags, tag, tmp)
    {
        if (!tag->numeric || tag->count == 0) {
            continue;
        }

        json_t *m = json_object();
        if (m == NULL) {
            json_decref(metrics);
            return NULL;
        }
        json_object_set_new(m, "count", json_integer((json_int_t) tag->count));
        json_object_set_new(m, "avg", json_real(tag->sum / tag->count));
        json_object_set_new(m, "max", json_real(tag->max));
        json_object_set_new(m, "min", json_real(tag->min));
        json_object_set_new(metrics, tag->tag, m);
    }

    return metrics;
}

static void reset_stats(aggregate_state_t *state)
{
    aggregate_sensor_t *sensor = NULL, *s_tmp = NULL;
    HASH_ITER(hh, state->sensors, sensor, s_tmp)
    {
        aggregate_tag_t *tag = NULL, *t_tmp = NULL;
        HASH_ITER(hh, sensor->tags, tag, t_tmp)
        {
            tag->count = 0;
            tag->sum   = 0;
            tag->min   = 0;
            tag->max   = 0;
        }
    }
}

static int publish_json(neu_plugin_t *plugin, const char *driver, json_t *root)
{
    char *json_str = json_dumps(root, JSON_COMPACT | JSON_REAL_PRECISION(16));
    if (json_str == NULL) {
        return NEU_ERR_EINTERNAL;
    }

    size_t size = strlen(json_str);
    if (plugin->config.auth_enable) {
        char *auth_payload = mqtt_auth_add_fields(plugin, json_str, size);
        free(json_str);
        if (auth_payload == NULL) {
            return NEU_ERR_EINTERNAL;
        }
        json_str = auth_payload;
        size     = strlen(json_str);
    }

    char *topic = topic_for_driver(plugin->config.aggregate_topic, driver);
    if (topic == NULL) {
        free(json_str);
        return NEU_ERR_EINTERNAL;
    }

    int rv = publish(plugin, plugin->config.qos, topic, json_str, size);
    free(topic);
    return rv;
}

static int flush_raw_driver(neu_plugin_t *plugin, const char *driver,
                            int64_t start, int64_t end)
{
    json_t *root    = json_object();
    json_t *window  = json_object();
    json_t *sensors = json_array();
    if (root == NULL || window == NULL || sensors == NULL) {
        json_decref(root);
        json_decref(window);
        json_decref(sensors);
        return NEU_ERR_EINTERNAL;
    }

    bool complete = true;
    size_t n_ok   = 0;
    route_entry_t *route = NULL, *tmp = NULL;
    HASH_ITER(hh, plugin->route_tbl, route, tmp)
    {
        if (0 != strcmp(route->key.driver, driver)) {
            continue;
        }
        aggregate_sensor_t *sensor =
            sensor_get(plugin->aggregate_state, route->key.driver,
                       route->key.group, false);
        if (!route_current_window(sensor, start)) {
            complete = false;
        } else {
            n_ok++;
        }
        json_t *sensor_json = raw_sensor_json(
            route, sensor, start, end, plugin->config.sensor_timeout_ms);
        if (sensor_json == NULL || json_array_append_new(sensors, sensor_json)) {
            json_decref(root);
            json_decref(window);
            json_decref(sensors);
            json_decref(sensor_json);
            return NEU_ERR_EINTERNAL;
        }
    }

    if (!plugin->config.emit_partial && !complete) {
        json_decref(root);
        json_decref(window);
        json_decref(sensors);
        return NEU_ERR_SUCCESS;
    }
    if (n_ok == 0 && !plugin->config.emit_partial) {
        json_decref(root);
        json_decref(window);
        json_decref(sensors);
        return NEU_ERR_SUCCESS;
    }

    json_object_set_new(window, "start", json_integer(start));
    json_object_set_new(window, "end", json_integer(end));
    json_object_set_new(root, "type", json_string("raw_batch"));
    json_object_set_new(root, "node", json_string(driver));
    json_object_set_new(root, "timestamp", json_integer(end));
    json_object_set_new(root, "window", window);
    json_object_set_new(root, "complete", json_boolean(complete));
    json_object_set_new(root, "sensors", sensors);

    int rv = publish_json(plugin, driver, root);
    json_decref(root);
    return rv;
}

static int flush_multi_driver(neu_plugin_t *plugin, const char *driver,
                              int64_t start, int64_t end)
{
    json_t *root    = json_object();
    json_t *window  = json_object();
    json_t *sensors = json_object();
    if (root == NULL || window == NULL || sensors == NULL) {
        json_decref(root);
        json_decref(window);
        json_decref(sensors);
        return NEU_ERR_EINTERNAL;
    }

    bool complete = true;
    route_entry_t *route = NULL, *tmp = NULL;
    HASH_ITER(hh, plugin->route_tbl, route, tmp)
    {
        if (0 != strcmp(route->key.driver, driver)) {
            continue;
        }
        aggregate_sensor_t *sensor =
            sensor_get(plugin->aggregate_state, route->key.driver,
                       route->key.group, false);
        const char *status =
            sensor_status(sensor, start, end, plugin->config.sensor_timeout_ms);
        if (!route_current_window(sensor, start)) {
            complete = false;
        }

        json_t *entry = json_object();
        json_t *metrics = metrics_from_sensor(sensor);
        if (entry == NULL || metrics == NULL) {
            json_decref(root);
            json_decref(window);
            json_decref(sensors);
            json_decref(entry);
            json_decref(metrics);
            return NEU_ERR_EINTERNAL;
        }
        json_object_set_new(entry, "status", json_string(status));
        if (sensor != NULL && sensor->last_ts > 0) {
            json_object_set_new(entry, "last_timestamp",
                                json_integer(sensor->last_ts));
        }
        json_object_set_new(entry, "metrics", metrics);
        json_object_set_new(sensors, route->key.group, entry);
    }

    if (!plugin->config.emit_partial && !complete) {
        json_decref(root);
        json_decref(window);
        json_decref(sensors);
        return NEU_ERR_SUCCESS;
    }

    json_object_set_new(window, "start", json_integer(start));
    json_object_set_new(window, "end", json_integer(end));
    json_object_set_new(root, "type", json_string("agg_multi_sensor"));
    json_object_set_new(root, "node", json_string(driver));
    json_object_set_new(root, "window", window);
    json_object_set_new(root, "complete", json_boolean(complete));
    json_object_set_new(root, "sensors", sensors);

    int rv = publish_json(plugin, driver, root);
    json_decref(root);
    return rv;
}

static bool single_sensor_match(neu_plugin_t *plugin, const char *group)
{
    return plugin->config.aggregate_sensor == NULL ||
        strlen(plugin->config.aggregate_sensor) == 0 ||
        0 == strcmp(plugin->config.aggregate_sensor, group);
}

static int flush_single(neu_plugin_t *plugin, int64_t start, int64_t end)
{
    int rv = NEU_ERR_SUCCESS;
    route_entry_t *route = NULL, *tmp = NULL;
    HASH_ITER(hh, plugin->route_tbl, route, tmp)
    {
        if (!single_sensor_match(plugin, route->key.group)) {
            continue;
        }

        aggregate_sensor_t *sensor =
            sensor_get(plugin->aggregate_state, route->key.driver,
                       route->key.group, false);
        if (!plugin->config.emit_partial &&
            !route_current_window(sensor, start)) {
            continue;
        }

        json_t *root    = json_object();
        json_t *window  = json_object();
        json_t *metrics = metrics_from_sensor(sensor);
        if (root == NULL || window == NULL || metrics == NULL) {
            json_decref(root);
            json_decref(window);
            json_decref(metrics);
            return NEU_ERR_EINTERNAL;
        }

        json_object_set_new(window, "start", json_integer(start));
        json_object_set_new(window, "end", json_integer(end));
        json_object_set_new(root, "type", json_string("agg_single_sensor"));
        json_object_set_new(root, "node", json_string(route->key.driver));
        json_object_set_new(root, "sensor", json_string(route->key.group));
        json_object_set_new(root, "window", window);
        json_object_set_new(
            root, "status",
            json_string(sensor_status(sensor, start, end,
                                      plugin->config.sensor_timeout_ms)));
        json_object_set_new(root, "metrics", metrics);

        rv = publish_json(plugin, route->key.driver, root);
        json_decref(root);
        if (rv != NEU_ERR_SUCCESS) {
            return rv;
        }

        if (plugin->config.aggregate_sensor == NULL ||
            strlen(plugin->config.aggregate_sensor) == 0) {
            return rv;
        }
    }
    return rv;
}

static int flush_locked(neu_plugin_t *plugin, int64_t now)
{
    aggregate_state_t *state = plugin->aggregate_state;
    if (state == NULL || !state->inited ||
        plugin->config.aggregate_mode == MQTT_AGGREGATE_DISABLED) {
        return NEU_ERR_SUCCESS;
    }

    int64_t start = state->window_start;
    int64_t end   = now;
    int     rv    = NEU_ERR_SUCCESS;

    if (plugin->config.aggregate_mode == MQTT_AGGREGATE_AGG_SINGLE_SENSOR) {
        rv = flush_single(plugin, start, end);
    } else {
        char drivers[128][NEU_NODE_NAME_LEN] = { 0 };
        size_t n_driver = 0;
        route_entry_t *route = NULL, *tmp = NULL;
        HASH_ITER(hh, plugin->route_tbl, route, tmp)
        {
            if (!driver_seen(drivers, n_driver, route->key.driver) &&
                n_driver < 128) {
                strncpy(drivers[n_driver], route->key.driver,
                        sizeof(drivers[n_driver]));
                n_driver++;
            }
        }

        for (size_t i = 0; i < n_driver; i++) {
            if (plugin->config.aggregate_mode == MQTT_AGGREGATE_RAW_BATCH) {
                rv = flush_raw_driver(plugin, drivers[i], start, end);
            } else {
                rv = flush_multi_driver(plugin, drivers[i], start, end);
            }
            if (rv != NEU_ERR_SUCCESS) {
                break;
            }
        }
    }

    reset_stats(state);
    state->window_start = now;
    return rv;
}

static int aggregate_timer_cb(void *data)
{
    neu_plugin_t *plugin = data;
    aggregate_state_t *state = plugin->aggregate_state;
    if (state == NULL) {
        return NEU_ERR_SUCCESS;
    }

    pthread_mutex_lock(&state->mtx);
    int rv = flush_locked(plugin, global_timestamp > 0 ? global_timestamp
                                                       : neu_time_ms());
    pthread_mutex_unlock(&state->mtx);
    return rv;
}

int mqtt_aggregate_start_timer(neu_plugin_t *plugin)
{
    if (plugin->config.aggregate_mode == MQTT_AGGREGATE_DISABLED) {
        return NEU_ERR_SUCCESS;
    }

    if (NULL == plugin->events) {
        plugin->events = neu_event_new(plugin->common.name);
        if (NULL == plugin->events) {
            return NEU_ERR_EINTERNAL;
        }
    }

    if (plugin->aggregate_timer != NULL) {
        neu_event_del_timer(plugin->events, plugin->aggregate_timer);
        plugin->aggregate_timer = NULL;
    }

    uint32_t window_ms = plugin->config.aggregate_window_ms;
    neu_event_timer_param_t param = {
        .second      = window_ms / 1000,
        .millisecond = window_ms % 1000,
        .cb          = aggregate_timer_cb,
        .usr_data    = plugin,
    };
    if (param.second == 0 && param.millisecond == 0) {
        param.millisecond = 1000;
    }

    plugin->aggregate_timer = neu_event_add_timer(plugin->events, param);
    if (plugin->aggregate_timer == NULL) {
        return NEU_ERR_EINTERNAL;
    }

    return NEU_ERR_SUCCESS;
}

void mqtt_aggregate_stop_timer(neu_plugin_t *plugin)
{
    if (plugin->aggregate_timer != NULL && plugin->events != NULL) {
        neu_event_del_timer(plugin->events, plugin->aggregate_timer);
        plugin->aggregate_timer = NULL;
    }
}

int mqtt_aggregate_handle_trans_data(neu_plugin_t *            plugin,
                                     neu_reqresp_trans_data_t *trans_data)
{
    if (plugin->config.aggregate_mode == MQTT_AGGREGATE_DISABLED) {
        return NEU_ERR_SUCCESS;
    }

    aggregate_state_t *state = get_state(plugin);
    if (state == NULL) {
        return NEU_ERR_EINTERNAL;
    }

    pthread_mutex_lock(&state->mtx);
    int rv = update_sensor(plugin, trans_data);
    pthread_mutex_unlock(&state->mtx);
    return rv;
}
