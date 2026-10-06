#pragma once
#include "pet_model.h"
#include "pet_preferences.h"
bool pet_store_load(pet_state_t *state);
bool pet_store_save(const pet_state_t *state);
// Separate NVS key: host snapshots and player migrations do not change settings.
bool pet_store_preferences_load(pet_preferences_t *preferences);
bool pet_store_preferences_save(const pet_preferences_t *preferences);
