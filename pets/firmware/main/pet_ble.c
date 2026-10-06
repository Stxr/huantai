#include "pet_ble.h"
#include "pet_stream.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "host/util/util.h"

#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_sm.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "nvs.h"
#include <string.h>

// 5f8f0001-2f76-4f47-9ef8-4bb38d901001; RX 0002, TX 0003.
#define PET_UUID(n) BLE_UUID128_INIT(0x01,0x10,0x90,0x8d,0xb3,0x4b,0xf8,0x9e,0x47,0x4f,0x76,0x2f,n,0x00,0x8f,0x5f)
static const ble_uuid128_t s_service = PET_UUID(1), s_rx_uuid = PET_UUID(2), s_tx_uuid = PET_UUID(3);
static uint16_t s_connection = BLE_HS_CONN_HANDLE_NONE, s_tx_handle;
static uint8_t s_address_type;
static bool s_subscribed, s_authorized;
static char s_owner_key[65];
static SemaphoreHandle_t s_key_lock, s_send_lock;
static pet_stream_t s_stream;
static pet_ble_line_callback_t s_callback;
void ble_store_config_init(void);
static void advertise(void);

static bool encrypted(void)
{
    struct ble_gap_conn_desc desc;
    return s_connection != BLE_HS_CONN_HANDLE_NONE && !ble_gap_conn_find(s_connection, &desc) && desc.sec_state.encrypted;
}
bool pet_ble_connected(void) { return s_connection != BLE_HS_CONN_HANDLE_NONE; }
bool pet_ble_authenticated(void) { return s_authorized && encrypted(); }

bool pet_ble_send(const char *text)
{
    if (!text || !s_subscribed || !encrypted() || !s_send_lock || xSemaphoreTake(s_send_lock, 0) != pdTRUE) return false;
    uint16_t handle = s_connection;
    unsigned mtu = ble_att_mtu(handle), chunk = mtu > 3 ? mtu - 3 : 20;
    size_t length = strlen(text); bool ok = true;
    for (size_t offset = 0; offset < length;) {
        size_t count = length - offset < chunk ? length - offset : chunk;
        struct os_mbuf *buffer = ble_hs_mbuf_from_flat(text + offset, count);
        if (!buffer || ble_gatts_notify_custom(handle, s_tx_handle, buffer)) { ok = false; break; }
        offset += count;
        if (length > chunk * 4 && offset < length) vTaskDelay(1);
    }
    xSemaphoreGive(s_send_lock); return ok;
}

static void receive_line(const char *line, size_t length, void *context)
{
    (void)context; static pet_state_t ignored; static pet_companion_t companion; static pet_control_t control; char key[65];
    pet_message_t type = pet_decode_extended(line, length, &ignored, key, &companion, &control);
    if (type == PET_MESSAGE_AUTH) {
        unsigned mismatch = 0;
        if (xSemaphoreTake(s_key_lock, 0) != pdTRUE) return;
        for (unsigned i = 0; i < 64; i++) mismatch |= (unsigned char)key[i] ^ (unsigned char)s_owner_key[i];
        bool valid = strlen(s_owner_key) == 64 && mismatch == 0;
        xSemaphoreGive(s_key_lock);
        s_authorized = valid && encrypted();
        pet_ble_send(s_authorized ? "{\"v\":1,\"type\":\"auth_ok\"}\n" : "{\"v\":1,\"type\":\"error\",\"code\":\"auth_failed\"}\n");
        return;
    }
    if (!s_authorized || !encrypted()) { pet_ble_send("{\"v\":1,\"type\":\"error\",\"code\":\"auth_required\"}\n"); return; }
    if (type != PET_MESSAGE_SNAPSHOT && type != PET_MESSAGE_STATUS && type != PET_MESSAGE_COMPANION && type != PET_MESSAGE_RESULT) { pet_ble_send("{\"v\":1,\"type\":\"error\",\"code\":\"invalid_message\"}\n"); return; }
    if (s_callback) s_callback(line, length);
}

static int access(uint16_t connection, uint16_t attribute, struct ble_gatt_access_ctxt *context, void *argument)
{
    (void)connection; (void)attribute; (void)argument;
    if (context->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        const char *hello = "{\"v\":1,\"type\":\"hello\",\"app\":\"token-pet\",\"firmware\":\"0.4.2\",\"width\":240,\"height\":320,\"ble\":true}\n";
        return os_mbuf_append(context->om, hello, strlen(hello)) ? BLE_ATT_ERR_INSUFFICIENT_RES : 0;
    }
    if (context->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    uint16_t count = OS_MBUF_PKTLEN(context->om);
    if (!count || count > 512) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    uint8_t data[512]; uint16_t copied;
    if (ble_hs_mbuf_to_flat(context->om, data, sizeof(data), &copied)) return BLE_ATT_ERR_UNLIKELY;
    pet_stream_feed(&s_stream, data, copied, receive_line, NULL); return 0;
}

static const struct ble_gatt_svc_def s_services[] = {
    {.type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = &s_service.u,
     .characteristics = (struct ble_gatt_chr_def[]){
        {.uuid=&s_rx_uuid.u, .access_cb=access, .flags=BLE_GATT_CHR_F_WRITE|BLE_GATT_CHR_F_WRITE_ENC},
        {.uuid=&s_tx_uuid.u, .access_cb=access, .flags=BLE_GATT_CHR_F_READ|BLE_GATT_CHR_F_READ_ENC|BLE_GATT_CHR_F_NOTIFY, .val_handle=&s_tx_handle},
        {0}}}, {0}};

static int gap(struct ble_gap_event *event, void *argument)
{
    (void)argument;
    if (event->type == BLE_GAP_EVENT_CONNECT) {
        if (!event->connect.status) { s_connection=event->connect.conn_handle; s_authorized=false; s_subscribed=false; memset(&s_stream,0,sizeof(s_stream)); }
        else advertise();
    } else if (event->type == BLE_GAP_EVENT_DISCONNECT) {
        s_connection=BLE_HS_CONN_HANDLE_NONE; s_authorized=false; s_subscribed=false; memset(&s_stream,0,sizeof(s_stream)); advertise();
    } else if (event->type == BLE_GAP_EVENT_SUBSCRIBE && event->subscribe.attr_handle == s_tx_handle) {
        s_subscribed=event->subscribe.cur_notify;
    } else if (event->type == BLE_GAP_EVENT_ENC_CHANGE && event->enc_change.status) s_authorized=false;
    else if (event->type == BLE_GAP_EVENT_REPEAT_PAIRING) {
        // The USB-provisioned application key still gates state access.
        struct ble_gap_conn_desc desc;
        if (!ble_gap_conn_find(event->repeat_pairing.conn_handle,&desc)) ble_store_util_delete_peer(&desc.peer_id_addr);
        return BLE_GAP_REPEAT_PAIRING_RETRY;
    }
    return 0;
}
static void advertise(void)
{
    struct ble_hs_adv_fields fields={0};
    fields.flags=BLE_HS_ADV_F_DISC_GEN|BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128=(ble_uuid128_t *)&s_service; fields.num_uuids128=1; fields.uuids128_is_complete=1;
    fields.name=(uint8_t *)"TokenPet"; fields.name_len=8; fields.name_is_complete=1;
    if (ble_gap_adv_set_fields(&fields)) { ESP_LOGW("pet_ble","Advertising fields failed"); return; }
    struct ble_gap_adv_params parameters={0}; parameters.conn_mode=BLE_GAP_CONN_MODE_UND; parameters.disc_mode=BLE_GAP_DISC_MODE_GEN;
    int error=ble_gap_adv_start(s_address_type,NULL,BLE_HS_FOREVER,&parameters,gap,NULL);
    if (error) ESP_LOGW("pet_ble","Advertising failed: %d",error);
}
static void synchronized(void)
{
    if (ble_hs_util_ensure_addr(0) || ble_hs_id_infer_auto(0,&s_address_type)) return;
    advertise();
}
static void host_task(void *argument) { (void)argument; nimble_port_run(); nimble_port_freertos_deinit(); }

bool pet_ble_provision(const char key[65])
{
    if (!s_key_lock || !key || strlen(key)!=64 || xSemaphoreTake(s_key_lock,pdMS_TO_TICKS(100))!=pdTRUE) return false;
    bool same=!strcmp(s_owner_key,key); bool ok=same;
    if (!same) {
        nvs_handle_t handle;
        if (nvs_open("token_pet",NVS_READWRITE,&handle)==ESP_OK) {
            ok=nvs_set_str(handle,"ble_key",key)==ESP_OK && nvs_commit(handle)==ESP_OK; nvs_close(handle);
        }
        if (ok) { memcpy(s_owner_key,key,65); s_authorized=false; }
    }
    xSemaphoreGive(s_key_lock); return ok;
}
bool pet_ble_start(pet_ble_line_callback_t callback)
{
    s_callback=callback; s_key_lock=xSemaphoreCreateMutex(); s_send_lock=xSemaphoreCreateMutex();
    if (!s_key_lock || !s_send_lock) return false;
    nvs_handle_t handle;
    if (nvs_open("token_pet",NVS_READONLY,&handle)==ESP_OK) {
        size_t length=sizeof(s_owner_key); if (nvs_get_str(handle,"ble_key",s_owner_key,&length)!=ESP_OK) memset(s_owner_key,0,sizeof(s_owner_key)); nvs_close(handle);
    }
    if (nimble_port_init()!=ESP_OK) return false;
    ble_hs_cfg.sync_cb=synchronized; ble_hs_cfg.store_status_cb=ble_store_util_status_rr;
    ble_hs_cfg.sm_io_cap=BLE_HS_IO_NO_INPUT_OUTPUT; ble_hs_cfg.sm_bonding=1; ble_hs_cfg.sm_mitm=0; ble_hs_cfg.sm_sc=1;
    ble_hs_cfg.sm_our_key_dist=BLE_SM_PAIR_KEY_DIST_ENC|BLE_SM_PAIR_KEY_DIST_ID; ble_hs_cfg.sm_their_key_dist=BLE_SM_PAIR_KEY_DIST_ENC|BLE_SM_PAIR_KEY_DIST_ID;
    ble_svc_gap_init(); ble_svc_gatt_init(); ble_svc_gap_device_name_set("TokenPet"); ble_store_config_init();
    if (ble_gatts_count_cfg(s_services) || ble_gatts_add_svcs(s_services)) return false;
    nimble_port_freertos_init(host_task); return true;
}
