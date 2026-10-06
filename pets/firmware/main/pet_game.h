#pragma once
#include <stdbool.h>
#include <stdint.h>
typedef struct {
    uint8_t page, settings_page, selected, choice;
    bool settings, confirm, pending;
} pet_game_t;
enum { PET_SETTINGS_COUNT=4 };
typedef enum { PET_GAME_NONE, PET_GAME_ADOPT, PET_GAME_OPEN, PET_GAME_BRIGHTNESS, PET_GAME_MIC_THRESHOLD } pet_game_action_t;
// Button values UP=0 DOWN=1 OK=2; events CLICK=1 DOUBLE=2 LONG=3.
pet_game_action_t pet_game_press(pet_game_t *game, unsigned button, unsigned event, bool adopted, unsigned sessions);
