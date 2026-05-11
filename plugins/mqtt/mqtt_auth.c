/**
 * NEURON IIoT System for Industry 4.0
 * Payload authentication extension for MQTT northbound publishing.
 **/

#include <string.h>

#include <jansson.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>

#include "mqtt_auth.h"

static const char *signing_key(neu_plugin_t *plugin)
{
    if (plugin->config.auth_secret != NULL &&
        strlen(plugin->config.auth_secret) > 0) {
        return plugin->config.auth_secret;
    }
    if (plugin->config.keylink != NULL) {
        return plugin->config.keylink;
    }
    return "";
}

static bool hmac_sha256_hex(const char *key, const char *payload,
                            size_t payload_len, char out[65])
{
    unsigned char digest[EVP_MAX_MD_SIZE] = { 0 };
    unsigned int  digest_len              = 0;

    if (NULL ==
        HMAC(EVP_sha256(), key, (int) strlen(key),
             (const unsigned char *) payload, payload_len, digest,
             &digest_len)) {
        return false;
    }
    if (digest_len != 32) {
        return false;
    }

    for (unsigned int i = 0; i < digest_len; i++) {
        snprintf(out + i * 2, 3, "%02x", digest[i]);
    }
    out[64] = '\0';
    return true;
}

char *mqtt_auth_add_fields(neu_plugin_t *plugin, const char *payload,
                           size_t payload_len)
{
    json_error_t error;
    json_t *     root = json_loadb(payload, payload_len, 0, &error);
    if (root == NULL) {
        plog_error(plugin, "auth payload is not valid json: %s", error.text);
        return NULL;
    }

    if (!json_is_object(root)) {
        json_t *wrapped = json_object();
        if (wrapped == NULL) {
            json_decref(root);
            return NULL;
        }
        json_object_set_new(wrapped, "data", root);
        root = wrapped;
    }

    char keylink[65] = { 0 };
    if (!hmac_sha256_hex(signing_key(plugin), payload, payload_len, keylink)) {
        json_decref(root);
        return NULL;
    }

    if (0 != json_object_set_new(root, "keylink", json_string(keylink))) {
        json_decref(root);
        return NULL;
    }

    char *out = json_dumps(root, JSON_COMPACT | JSON_REAL_PRECISION(16));
    json_decref(root);
    return out;
}
