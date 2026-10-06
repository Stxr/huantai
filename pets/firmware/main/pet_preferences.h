#pragma once
#include <stdbool.h>
#include <stdint.h>

enum { PET_TIER_LOW, PET_TIER_MEDIUM, PET_TIER_HIGH, PET_TIER_COUNT };
typedef struct { uint8_t brightness, mic_threshold; } pet_preferences_t;
pet_preferences_t pet_preferences_defaults(void);
bool pet_preferences_valid(const pet_preferences_t *preferences);
uint8_t pet_brightness_percent(unsigned tier);
uint16_t pet_mic_threshold(unsigned tier, uint16_t floor);
