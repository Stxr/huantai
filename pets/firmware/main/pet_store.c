#include "pet_store.h"
#include "nvs.h"
#include "esp_rom_crc.h"
#include <stddef.h>
#include <string.h>
typedef struct { uint32_t magic, version; uint64_t generation; pet_state_t state; uint32_t crc; } record_t;
typedef struct {
    char epoch[33]; uint64_t seq, today, total; char date[11];
    uint8_t family, level, progress, food_count; bool account_source; pet_food_t food[3];
} legacy_state_t;
typedef struct { uint32_t magic, version; uint64_t generation; legacy_state_t state; uint32_t crc; } legacy_record_t;
_Static_assert(offsetof(pet_state_t, adopted) == sizeof(legacy_state_t), "Legacy state layout changed");
static uint64_t s_generation;
static bool valid(const record_t *record)
{
    return record->magic == 0x50455431 && record->version == 2 &&
        record->crc == esp_rom_crc32_le(0, (const uint8_t *)record, offsetof(record_t, crc)) &&
        record->state.level >= 1 && record->state.level <= 12 && record->state.family < 6 &&
        record->state.progress <= 100 && record->state.food_count <= PET_FOOD_COUNT &&
        record->state.epoch[32] == 0 && record->state.date[10] == 0;
}
bool pet_store_load(pet_state_t *state)
{
    nvs_handle_t handle;
    if (nvs_open("token_pet", NVS_READONLY, &handle) != ESP_OK) return false;
    record_t best = {0}, candidate;
    bool found = false;
    for (unsigned slot = 0; slot < 2; slot++) {
        size_t length = sizeof(candidate);
        esp_err_t error = nvs_get_blob(handle, slot ? "slot1" : "slot0", &candidate, &length);
        if (error == ESP_OK && length == sizeof(legacy_record_t)) {
            legacy_record_t legacy; memcpy(&legacy, &candidate, sizeof(legacy));
            if (legacy.magic != 0x50455431 || legacy.version != 1 || legacy.crc != esp_rom_crc32_le(0,(const uint8_t *)&legacy,offsetof(legacy_record_t,crc))) continue;
            memset(&candidate,0,sizeof(candidate)); candidate.magic=legacy.magic; candidate.version=2; candidate.generation=legacy.generation;
            memcpy(&candidate.state,&legacy.state,sizeof(legacy.state));
            candidate.crc=esp_rom_crc32_le(0,(const uint8_t *)&candidate,offsetof(record_t,crc)); length=sizeof(candidate);
        }
        if (error == ESP_OK && length == sizeof(candidate) && valid(&candidate) && (!found || candidate.generation > best.generation)) {
            best = candidate; found = true;
        }
    }
    nvs_close(handle);
    if (found) { *state = best.state; s_generation = best.generation; }
    return found;
}
bool pet_store_save(const pet_state_t *state)
{
    nvs_handle_t handle;
    if (nvs_open("token_pet", NVS_READWRITE, &handle) != ESP_OK) return false;
    record_t record;
    memset(&record, 0, sizeof(record));
    record.magic = 0x50455431; record.version = 2; record.generation = s_generation + 1; record.state = *state;
    record.crc = esp_rom_crc32_le(0, (const uint8_t *)&record, offsetof(record_t, crc));
    esp_err_t error = nvs_set_blob(handle, record.generation % 2 ? "slot1" : "slot0", &record, sizeof(record));
    if (error == ESP_OK) error = nvs_commit(handle);
    nvs_close(handle);
    if (error == ESP_OK) s_generation = record.generation;
    return error == ESP_OK;
}

bool pet_store_preferences_load(pet_preferences_t *preferences)
{
    *preferences=pet_preferences_defaults();
    nvs_handle_t handle;
    if (nvs_open("token_pet",NVS_READONLY,&handle)!=ESP_OK) return false;
    pet_preferences_t candidate;
    size_t length=sizeof(candidate);
    esp_err_t error=nvs_get_blob(handle,"preferences",&candidate,&length);
    nvs_close(handle);
    if (error!=ESP_OK || length!=sizeof(candidate) || !pet_preferences_valid(&candidate)) return false;
    *preferences=candidate; return true;
}
bool pet_store_preferences_save(const pet_preferences_t *preferences)
{
    if (!pet_preferences_valid(preferences)) return false;
    nvs_handle_t handle;
    if (nvs_open("token_pet",NVS_READWRITE,&handle)!=ESP_OK) return false;
    esp_err_t error=nvs_set_blob(handle,"preferences",preferences,sizeof(*preferences));
    if (error==ESP_OK) error=nvs_commit(handle);
    nvs_close(handle); return error==ESP_OK;
}
