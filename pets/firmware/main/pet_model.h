#pragma once
#include <stdbool.h>
#include <stdint.h>
#define PET_FOOD_COUNT 3
#define PET_EPOCH_SIZE 33
typedef struct { char model[65]; uint64_t tokens; } pet_food_t;
typedef struct {
    char epoch[PET_EPOCH_SIZE];
    uint64_t seq, today, total;
    char date[11];
    uint8_t family, level, progress, food_count;
    bool account_source;
    pet_food_t food[PET_FOOD_COUNT];
    bool adopted;
} pet_state_t;
typedef enum { PET_REJECTED = -1, PET_DUPLICATE = 0, PET_APPLIED = 1 } pet_result_t;
bool pet_parse_u64(const char *text, uint64_t *value);
pet_result_t pet_apply(pet_state_t *state, const pet_state_t *incoming);
unsigned pet_species(unsigned family, unsigned level);
