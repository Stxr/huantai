#include "pet_sound.h"
#include "pet_preferences.h"
#include <assert.h>
#include <stdio.h>

int main(void)
{
    int16_t pcm[320];
    for (unsigned i=0;i<320;i++) pcm[i]=1400;
    assert(pet_sound_rms(pcm,320)==0); // DC is not a sound.
    for (unsigned i=0;i<320;i++) pcm[i]=i%2 ? 1700 : 1100;
    assert(pet_sound_rms(pcm,320)==300);
    for (unsigned i=0;i<320;i++) pcm[i]=i%2 ? 32767 : -32768;
    assert(pet_sound_rms(pcm,320)==32767);
    assert(pet_sound_rms(NULL,320)==0 && pet_sound_rms(pcm,321)==0);
    // The same moderate sound triggers low/middle thresholds, not high.
    for (unsigned tier=0;tier<PET_TIER_COUNT;tier++) {
        pet_sound_t detector={0};pet_sound_set_tier(&detector,tier);
        for (unsigned i=0;i<200;i++) assert(!pet_sound_observe(&detector,40));
        assert(pet_mic_threshold(tier,detector.floor)==120+40*tier);
        assert(!pet_sound_observe(&detector,180));
        assert(pet_sound_observe(&detector,180)==(tier<PET_TIER_HIGH));
    }
    // Lowering the threshold during sound cannot create an onset by itself.
    pet_sound_t changed={0};pet_sound_set_tier(&changed,PET_TIER_HIGH);
    for (unsigned i=0;i<200;i++) assert(!pet_sound_observe(&changed,40));
    assert(!pet_sound_observe(&changed,180));
    pet_sound_set_tier(&changed,PET_TIER_LOW);
    assert(!pet_sound_observe(&changed,180) && !pet_sound_observe(&changed,180));
    for (unsigned i=0;i<40;i++) assert(!pet_sound_observe(&changed,40));
    assert(!pet_sound_observe(&changed,180) && pet_sound_observe(&changed,180));
    assert(pet_mic_threshold(PET_TIER_HIGH,UINT16_MAX)==UINT16_MAX);
    // Softer speech missed by the old threshold now triggers, while background
    // fluctuations and an isolated 20 ms click do not.
    pet_sound_t soft={0};
    for (unsigned i=0;i<300;i++) assert(!pet_sound_observe(&soft,35+i%21));
    assert(!pet_sound_observe(&soft,160));
    assert(pet_sound_observe(&soft,160));
    for (unsigned i=0;i<40;i++) assert(!pet_sound_observe(&soft,40));
    assert(!pet_sound_observe(&soft,180));
    assert(!pet_sound_observe(&soft,40));
    pet_sound_t minimum={0};
    for (unsigned i=0;i<200;i++) assert(!pet_sound_observe(&minimum,0));
    for (unsigned i=0;i<100;i++) assert(!pet_sound_observe(&minimum,110));
    pet_sound_t sound={0};
    for (unsigned i=0;i<200;i++) assert(!pet_sound_observe(&sound,40));
    assert(!pet_sound_observe(&sound,400));
    assert(pet_sound_observe(&sound,400));
    for (unsigned i=0;i<200;i++) assert(!pet_sound_observe(&sound,400)); // No repeated hops on steady noise.
    for (unsigned i=0;i<40;i++) assert(!pet_sound_observe(&sound,40));
    assert(!pet_sound_observe(&sound,1500));
    assert(pet_sound_observe(&sound,1500));
    pet_sound_t fan={0};
    for (unsigned i=0;i<1000;i++) assert(!pet_sound_observe(&fan,1000));
    assert(!pet_sound_observe(&fan,4000));
    assert(pet_sound_observe(&fan,4000));
    assert(pet_sound_hop(0)==0 && pet_sound_hop(240)==-8);
    assert(pet_sound_hop(480)==0 && pet_sound_hop(UINT32_MAX)==0);
    for (unsigned i=0;i<=480;i++) assert(pet_sound_hop(i)>=-8 && pet_sound_hop(i)<=0);
    puts("DC removal, extreme PCM, quiet idle, adaptive onset, rearm and bounded hop: PASS");
}
