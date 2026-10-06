#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Each observation represents 20 ms of 16 kHz mono input. PCM is discarded.
typedef struct {
    uint32_t floor_q8, blocks, last_onset;
    uint16_t rms, floor;
    uint8_t high, quiet, threshold_tier;
    bool armed;
} pet_sound_t;

uint16_t pet_sound_rms(const int16_t *pcm, size_t count);
bool pet_sound_observe(pet_sound_t *state, uint16_t rms);
// Changing the threshold never creates an onset; quiet input must rearm it.
void pet_sound_set_tier(pet_sound_t *state, unsigned tier);
// 480 ms hop, zero at rest; independent of wall time and LVGL.
int pet_sound_hop(uint32_t elapsed_ms);
