#include "pet_preferences.h"

pet_preferences_t pet_preferences_defaults(void)
{
    return (pet_preferences_t){.brightness=PET_TIER_MEDIUM,.mic_threshold=PET_TIER_LOW};
}
bool pet_preferences_valid(const pet_preferences_t *p)
{
    return p && p->brightness<PET_TIER_COUNT && p->mic_threshold<PET_TIER_COUNT;
}
uint8_t pet_brightness_percent(unsigned tier)
{
    static const uint8_t percent[PET_TIER_COUNT]={20,40,75};
    return percent[tier<PET_TIER_COUNT ? tier : PET_TIER_MEDIUM];
}
uint16_t pet_mic_threshold(unsigned tier, uint16_t floor)
{
    if (tier>=PET_TIER_COUNT) tier=PET_TIER_LOW;
    uint32_t threshold=(uint32_t)floor*(4+tier)/2+40+20*tier;
    uint32_t minimum=120+40*tier;
    if (threshold<minimum) threshold=minimum;
    return threshold>UINT16_MAX ? UINT16_MAX : (uint16_t)threshold;
}
