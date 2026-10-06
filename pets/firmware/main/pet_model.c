#include "pet_model.h"
#include "pet_families.h"
#include <limits.h>
#include <stddef.h>
#include <string.h>

bool pet_parse_u64(const char *text, uint64_t *value)
{
    if (!text || !*text || !value) return false;
    uint64_t result = 0;
    unsigned length = 0;
    for (; *text; text++, length++) {
        if (length >= 20 || *text < '0' || *text > '9') return false;
        unsigned digit = (unsigned)(*text - '0');
        if (result > (UINT64_MAX - digit) / 10) return false;
        result = result * 10 + digit;
    }
    *value = result;
    return true;
}

unsigned pet_species(unsigned family, unsigned level)
{
    if (family >= PET_FAMILY_COUNT || level < 1 || level > 12) return 0;
    return pet_family_species[family][(level - 1) / 4];
}

pet_result_t pet_apply(pet_state_t *state, const pet_state_t *incoming)
{
    if (!state || !incoming || incoming->family >= PET_FAMILY_COUNT ||
        incoming->level < 1 || incoming->level > 12 || incoming->progress > 100 ||
        incoming->food_count > PET_FOOD_COUNT || incoming->today > incoming->total ||
        memchr(incoming->epoch, 0, PET_EPOCH_SIZE) != incoming->epoch + 32 || memchr(incoming->date, 0, 11) != incoming->date + 10)
        return PET_REJECTED;
    if (!strcmp(state->epoch, incoming->epoch)) {
        if (state->adopted && (!incoming->adopted || incoming->family != state->family)) return PET_REJECTED;
        if (incoming->seq < state->seq) return PET_REJECTED;
        if (incoming->seq == state->seq) return PET_DUPLICATE;
        if (incoming->total < state->total || incoming->level < state->level) return PET_REJECTED;
    }
    *state = *incoming;
    return PET_APPLIED;
}
