#include "pet_model.h"
#include "pet_protocol.h"
#include "pet_stream.h"
#include "pet_game.h"
#include "pet_preferences.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <inttypes.h>
static const char *packet="{\"v\":1,\"type\":\"snapshot\",\"epoch\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"seq\":1,\"date\":\"2026-10-06\",\"family\":0,\"level\":1,\"progress\":25,\"source\":\"local\",\"tokens_today\":\"10\",\"pet_tokens_total\":\"100\",\"food\":[{\"model\":\"gpt-6-sol\",\"tokens\":\"10\"}]}";
static unsigned lines;
static void received(const char *line, size_t count, void *context) { (void)context; assert(count==2 && !memcmp(line,"{}",2)); lines++; }
int main(void) {
    uint64_t n;
    assert(pet_parse_u64("18446744073709551615",&n)&&n==UINT64_MAX);
    assert(!pet_parse_u64("18446744073709551616",&n));
    assert(!pet_parse_u64("-1",&n));assert(!pet_parse_u64("",&n));assert(!pet_parse_u64("1.2",&n));
    unsigned chains[6][3]={{4,5,6},{172,25,26},{1,2,3},{7,8,9},{147,148,149},{92,93,94}};
    for(unsigned f=0;f<6;f++)for(unsigned level=1;level<=12;level++) assert(pet_species(f,level)==chains[f][(level-1)/4]);
    assert(!pet_species(6,1));assert(!pet_species(0,0));assert(!pet_species(0,13));
    pet_state_t state={0}, incoming={0};
    assert(pet_decode(packet,strlen(packet),&incoming)==PET_MESSAGE_SNAPSHOT);
    assert(incoming.today==10&&incoming.total==100&&incoming.food_count==1);
    assert(pet_apply(&state,&incoming)==PET_APPLIED);
    assert(pet_apply(&state,&incoming)==PET_DUPLICATE);
    incoming.seq=0;assert(pet_apply(&state,&incoming)==PET_REJECTED);
    incoming.seq=2;incoming.total=99;assert(pet_apply(&state,&incoming)==PET_REJECTED);
    incoming.total=110;incoming.level=5;assert(pet_apply(&state,&incoming)==PET_APPLIED);
    incoming.seq=3;incoming.level=1;assert(pet_apply(&state,&incoming)==PET_REJECTED);
    incoming.epoch[0]='b';incoming.total=10;assert(pet_apply(&state,&incoming)==PET_APPLIED);
    const char *bad[]={"{\"v\":1,\"v\":1,\"type\":\"status\"}","{\"v\":1,\"type\":\"status\\u0000abc\"}","{\"v\":1,\"type\":\"status\"} junk","{\"v\":1.5,\"type\":\"status\"}","[[[[[[[[[]]]]]]]]]"};
    for(unsigned i=0;i<sizeof(bad)/sizeof(*bad);i++)assert(pet_decode(bad[i],strlen(bad[i]),&incoming)==PET_MESSAGE_INVALID);
    const char *query="{\"v\":1,\"type\":\"status\"}";assert(pet_decode(query,strlen(query),&incoming)==PET_MESSAGE_STATUS);
    query="{\"v\":1,\"type\":\"capture\"}";assert(pet_decode(query,strlen(query),&incoming)==PET_MESSAGE_CAPTURE);
    for(size_t i=1;i<strlen(packet);i++)assert(pet_decode(packet,i,&incoming)==PET_MESSAGE_INVALID);
    char large[PET_LINE_MAX+1];memset(large,'a',sizeof(large));assert(pet_decode(large,sizeof(large),&incoming)==PET_MESSAGE_INVALID);
    char auth[160], key[65];
    snprintf(auth,sizeof(auth),"{\"v\":1,\"type\":\"auth\",\"key\":\"%064u\"}",0u);
    assert(pet_decode_control(auth,strlen(auth),&incoming,key)==PET_MESSAGE_AUTH);
    assert(strlen(key)==64);
    assert(pet_decode(auth,strlen(auth),&incoming)==PET_MESSAGE_INVALID);
    auth[strlen(auth)-3]='g';assert(pet_decode_control(auth,strlen(auth),&incoming,key)==PET_MESSAGE_INVALID);
    pet_stream_t stream={0};
    pet_stream_feed(&stream,(const uint8_t *)"{",1,received,NULL);
    assert(lines==0);pet_stream_feed(&stream,(const uint8_t *)"}\n{}\n",5,received,NULL);assert(lines==2);
    memset(large,'x',sizeof(large));pet_stream_feed(&stream,(const uint8_t *)large,sizeof(large),received,NULL);
    pet_stream_feed(&stream,(const uint8_t *)"\n{}\n",4,received,NULL);assert(lines==3);
    pet_game_t game={0};
    assert(pet_game_press(&game,1,1,false,0)==PET_GAME_NONE && game.choice==1 && game.page==0);
    assert(pet_game_press(&game,2,1,false,0)==PET_GAME_NONE && game.confirm);
    assert(pet_game_press(&game,2,2,false,0)==PET_GAME_NONE && !game.confirm);
    assert(pet_game_press(&game,2,1,false,0)==PET_GAME_NONE);
    assert(pet_game_press(&game,2,1,false,0)==PET_GAME_ADOPT && game.pending);
    assert(pet_game_press(&game,2,1,false,0)==PET_GAME_NONE);game.pending=false;
    assert(pet_game_press(&game,1,1,true,3)==PET_GAME_NONE && game.page==0);
    assert(pet_game_press(&game,2,2,true,3)==PET_GAME_NONE && game.page==1);
    assert(pet_game_press(&game,1,1,true,3)==PET_GAME_NONE && game.selected==1);
    assert(pet_game_press(&game,2,2,true,3)==PET_GAME_NONE && game.page==2 && !game.pending);
    pet_game_press(&game,2,2,true,3);assert(game.page==0);
    pet_game_press(&game,2,3,true,3);assert(game.settings && game.page==0);
    pet_game_press(&game,1,1,true,3);assert(game.settings_page==1);
    assert(pet_game_press(&game,2,1,true,3)==PET_GAME_NONE);
    pet_game_press(&game,1,1,true,3);assert(game.settings_page==2);
    assert(pet_game_press(&game,2,1,true,3)==PET_GAME_BRIGHTNESS && !game.pending);
    assert(pet_game_press(&game,2,2,true,3)==PET_GAME_NONE && game.settings_page==2 && game.page==0);
    pet_game_press(&game,1,1,true,3);assert(game.settings_page==3);
    assert(pet_game_press(&game,2,1,true,3)==PET_GAME_MIC_THRESHOLD && !game.pending);
    pet_game_press(&game,1,1,true,3);assert(game.settings_page==0);
    pet_game_press(&game,0,1,true,3);assert(game.settings_page==3);
    pet_game_press(&game,2,3,true,3);assert(!game.settings);
    game.page=1;assert(pet_game_press(&game,2,1,true,3)==PET_GAME_OPEN);
    incoming.adopted=true;incoming.seq++;state=incoming;
    incoming.seq++;incoming.family=(state.family+1)%6;assert(pet_apply(&state,&incoming)==PET_REJECTED);
    incoming.family=state.family;incoming.adopted=false;assert(pet_apply(&state,&incoming)==PET_REJECTED);
    pet_companion_t companion;pet_control_t control;
    query="{\"v\":1,\"type\":\"companion\",\"available\":true,\"sessions\":[{\"handle\":\"aaaaaaaaaaaaaaaa\",\"title\":\"会话\",\"source\":\"Codex\",\"openable\":true}],\"quota_valid\":true,\"remaining\":625,\"reset_after\":86400,\"reset_text\":\"10-10 12:00\",\"reference\":500,\"today\":-50,\"live\":true}";
    assert(pet_decode_extended(query,strlen(query),&incoming,NULL,&companion,&control)==PET_MESSAGE_COMPANION);
    assert(companion.session_count==1 && companion.remaining==625 && companion.today==-50);
    query="{\"v\":1,\"type\":\"input\",\"button\":2,\"event\":2}";
    assert(pet_decode_extended(query,strlen(query),&incoming,NULL,&companion,&control)==PET_MESSAGE_INPUT && control.event==2);
    pet_preferences_t preferences=pet_preferences_defaults();
    assert(preferences.brightness==PET_TIER_MEDIUM && preferences.mic_threshold==PET_TIER_LOW);
    assert(pet_preferences_valid(&preferences));
    preferences.brightness=3;assert(!pet_preferences_valid(&preferences));
    preferences.brightness=0;preferences.mic_threshold=255;assert(!pet_preferences_valid(&preferences));
    assert(!pet_preferences_valid(NULL));
    assert(pet_brightness_percent(0)==20 && pet_brightness_percent(1)==40 && pet_brightness_percent(2)==75);
    assert(pet_brightness_percent(99)==40);
    puts("Pet model/protocol/game tests: PASS (72 mappings, owner lock, confirmation, click/double/long, bounded companion, replay and fragments)");
    return 0;
}
