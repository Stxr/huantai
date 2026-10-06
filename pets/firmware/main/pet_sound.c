#include "pet_sound.h"
#include "pet_preferences.h"

void pet_sound_set_tier(pet_sound_t *s, unsigned tier)
{
    if (!s || tier>=PET_TIER_COUNT || tier==s->threshold_tier) return;
    s->threshold_tier=(uint8_t)tier;
    s->high=0; s->quiet=0; s->armed=false;
}

uint16_t pet_sound_rms(const int16_t *pcm, size_t count)
{
    if (!pcm || !count || count > 320) return 0;
    int64_t sum=0;
    uint64_t squares=0;
    for (size_t i=0;i<count;i++) {
        int32_t sample=pcm[i]; sum+=sample;
        squares+=(uint64_t)((int64_t)sample*sample);
    }
    // Remove DC bias before detecting volume changes.
    uint64_t variance=(squares*count-(uint64_t)(sum*sum))/(count*count);
    uint32_t low=0,high=32768;
    while (low<high) {
        uint32_t middle=(low+high+1)/2;
        if ((uint64_t)middle*middle<=variance) low=middle;
        else high=middle-1;
    }
    return (uint16_t)low;
}

bool pet_sound_observe(pet_sound_t *s, uint16_t rms)
{
    s->rms=rms;
    if (!s->blocks) s->floor_q8=(uint32_t)rms*256;
    s->blocks++;
    uint32_t floor=s->floor_q8/256;
    if (s->blocks<=100) {
        s->floor_q8=(uint32_t)((int32_t)s->floor_q8+((int32_t)rms*256-(int32_t)s->floor_q8)/8);
        s->floor=(uint16_t)(s->floor_q8/256); s->armed=true;
        return false;
    }
    uint32_t threshold=pet_mic_threshold(s->threshold_tier,(uint16_t)floor);
    bool loud=rms>threshold;
    bool trigger=false;
    if (loud) {
        s->quiet=0;
        if (s->high<2) s->high++;
        if (s->armed && s->high==2 && s->blocks-s->last_onset>=35) {
            trigger=true; s->armed=false; s->last_onset=s->blocks;
        }
    } else {
        s->high=0;
        if (rms<floor*3/2+60) {
            if (s->quiet<10) s->quiet++;
            if (s->quiet==10) s->armed=true;
        } else s->quiet=0;
    }
    // Slowly adapt steady background sound, including a newly started fan.
    if (!loud || s->blocks-s->last_onset>100) {
        int divisor=loud ? 128 : 64;
        s->floor_q8=(uint32_t)((int32_t)s->floor_q8+((int32_t)rms*256-(int32_t)s->floor_q8)/divisor);
    }
    s->floor=(uint16_t)(s->floor_q8/256);
    return trigger;
}

int pet_sound_hop(uint32_t elapsed_ms)
{
    if (elapsed_ms>=480) return 0;
    return -(int)(4*8*elapsed_ms*(480-elapsed_ms)/(480*480));
}
