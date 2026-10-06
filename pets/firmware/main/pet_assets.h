#pragma once
#include "lvgl.h"
typedef struct { unsigned id; const char *name; const char *name_zh; const lv_image_dsc_t *frames[4]; } pet_sprite_t;
extern const pet_sprite_t pet_sprites[];
extern const unsigned pet_sprite_count;
