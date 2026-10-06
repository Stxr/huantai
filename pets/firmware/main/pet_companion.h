#pragma once
#include <stdbool.h>
#include <stdint.h>
typedef struct { char handle[17], title[73], source[17]; bool openable; } pet_session_t;
typedef struct {
    bool available, quota_valid, reference_valid, today_valid, live;
    uint8_t session_count;
    uint16_t remaining, reference;
    int16_t today;
    uint32_t reset_after;
    char reset_text[24];
    pet_session_t sessions[3];
} pet_companion_t;
typedef struct { char request[33]; uint8_t code, button, event; } pet_control_t;
