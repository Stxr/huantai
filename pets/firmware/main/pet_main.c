#include "bsp_battery.h"
#include "bsp_audio.h"
#include "bsp_button.h"
#include "bsp_display.h"
#include "pet_assets.h"
#include "pet_model.h"
#include "pet_protocol.h"
#include "pet_store.h"
#include "pet_ble.h"
#include "pet_stream.h"
#include "pet_game.h"
#include "pet_sound.h"
#include "esp_random.h"
#include "driver/usb_serial_jtag.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "lvgl.h"
#include "nvs_flash.h"
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

LV_FONT_DECLARE(pet_font_16);
LV_FONT_DECLARE(pet_font_20);
typedef struct { unsigned kind; bsp_btn_t button; bsp_btn_ev_t event; bool bluetooth; char key[65]; pet_state_t snapshot; pet_companion_t companion; pet_control_t control; } app_event_t;
static QueueHandle_t s_queue;
static SemaphoreHandle_t s_tx_lock;
static pet_state_t s_state, s_view;
static bool s_dirty, s_save_ok = true, s_have_save;
static TickType_t s_received_tick;
static bool s_received_ble;
static pet_stream_t s_usb_stream;
static int64_t s_saved_at;
static unsigned s_page, s_frame;
static pet_game_t s_game;
static pet_companion_t s_companion;
static int64_t s_companion_at, s_action_at;
static char s_action[512], s_request[33];
static uint32_t s_action_counter, s_boot_id;
static lv_obj_t *s_settings[PET_SETTINGS_COUNT], *s_session_rows[3], *s_session_titles[3], *s_session_sources[3], *s_hint;
static lv_obj_t *s_tier_rows[2][PET_TIER_COUNT], *s_preferences_status[2];
static pet_preferences_t s_preferences;
static bool s_preferences_dirty, s_preferences_save_ok=true;
static int64_t s_preferences_saved_at;
static lv_obj_t *s_quota_title, *s_quota_bar, *s_reference_mark, *s_quota_today, *s_quota_reset, *s_quota_date, *s_quota_source;
static lv_obj_t *s_title, *s_status, *s_battery, *s_battery_fill, *s_home, *s_food, *s_sessions, *s_image, *s_level, *s_bar, *s_today, *s_food_text, *s_journey, *s_evolve;
static int s_battery_soc=-1;
static bool s_battery_ready;
static int64_t s_battery_at;
static int64_t s_evolve_until;
static int64_t s_jump_at, s_last_status_ui;
static int s_jump_offset;
typedef struct { bool ready; uint8_t threshold_tier; uint16_t rms, floor, peak, threshold; uint32_t blocks, onsets, stack_free; } mic_status_t;
static mic_status_t s_mic;
static uint8_t s_mic_threshold_tier;
static portMUX_TYPE s_mic_lock=portMUX_INITIALIZER_UNLOCKED;
// Queue payloads are large; keep these immutable zero-filled events in Flash,
// rather than on the microphone stack during codec/logging calls.
static const app_event_t s_mic_onset_event={.kind=8},s_mic_failure_event={.kind=9};
static bool s_capturing;
static unsigned s_capture_rows;
static lv_display_t *s_display;

static void transmit(const char *text)
{
    if (!s_tx_lock || xSemaphoreTake(s_tx_lock, pdMS_TO_TICKS(500)) != pdTRUE) return;
    size_t length = strlen(text), offset = 0;
    while (offset < length) {
        int written = usb_serial_jtag_write_bytes(text + offset, length - offset, pdMS_TO_TICKS(500));
        if (written <= 0) break;
        offset += (size_t)written;
    }
    xSemaphoreGive(s_tx_lock);
}

static void reply(bool bluetooth, const char *text)
{
    if (bluetooth) { if (pet_ble_authenticated()) (void)pet_ble_send(text); }
    else transmit(text);
}

static const pet_sprite_t *sprite(unsigned id)
{
    for (unsigned i = 0; i < pet_sprite_count; i++) if (pet_sprites[i].id == id) return &pet_sprites[i];
    return &pet_sprites[0];
}

static void compact(uint64_t value, char *text, size_t capacity)
{
    uint64_t divisor = value >= 1000000000 ? 1000000000 : value >= 1000000 ? 1000000 : value >= 1000 ? 1000 : 1;
    const char *suffix = divisor == 1000000000 ? "B" : divisor == 1000000 ? "M" : divisor == 1000 ? "K" : "";
    if (divisor == 1) snprintf(text, capacity, "%" PRIu64, value);
    else snprintf(text, capacity, "%" PRIu64 ".%02" PRIu64 "%s", value / divisor, (value % divisor) * 100 / divisor, suffix);
}

static void compact_inline(uint64_t value, char *text, size_t capacity)
{
    const char *units=" KMBTPE";
    uint64_t divisor=1; unsigned unit=0;
    while (value/divisor>=1000 && unit<6) { divisor*=1000; unit++; }
    if (!unit) snprintf(text,capacity,"%" PRIu64,value);
    else snprintf(text,capacity,"%" PRIu64 ".%" PRIu64 "%c",value/divisor,(value%divisor)*10/divisor,units[unit]);
}

static mic_status_t mic_status(void)
{
    portENTER_CRITICAL(&s_mic_lock);
    mic_status_t result=s_mic;
    portEXIT_CRITICAL(&s_mic_lock);
    return result;
}

static void battery_ui(void)
{
    if (s_battery_soc<0) lv_label_set_text(s_battery,"--%");
    else lv_label_set_text_fmt(s_battery,"%d%%",s_battery_soc);
    if (s_battery_soc<=0) lv_obj_add_flag(s_battery_fill,LV_OBJ_FLAG_HIDDEN);
    else {
        lv_obj_remove_flag(s_battery_fill,LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_width(s_battery_fill,(18*s_battery_soc+99)/100);
        lv_obj_set_style_bg_color(s_battery_fill,lv_color_hex(s_battery_soc<=10 ? 0xBA594A : s_battery_soc<=20 ? 0xBA913E : 0x527447),0);
    }
}

static lv_obj_t *label(lv_obj_t *parent, const char *text, int x, int y, int width, const lv_font_t *font)
{
    lv_obj_t *result = lv_label_create(parent);
    lv_label_set_text(result, text); lv_obj_set_pos(result, x, y); lv_obj_set_width(result, width);
    lv_obj_set_style_text_font(result, font, 0); lv_obj_set_style_text_color(result, lv_color_hex(0x294235), 0);
    lv_label_set_long_mode(result, LV_LABEL_LONG_DOT);
    return result;
}

static lv_obj_t *container(lv_obj_t *screen)
{
    lv_obj_t *object = lv_obj_create(screen);
    lv_obj_set_pos(object, 0, 72); lv_obj_set_size(object, 240, 210);
    lv_obj_remove_flag(object, LV_OBJ_FLAG_SCROLLABLE); lv_obj_set_style_bg_opa(object, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(object, 0, 0); lv_obj_set_style_pad_all(object, 0, 0);
    return object;
}

static void show_page(void)
{
    lv_obj_add_flag(s_home, LV_OBJ_FLAG_HIDDEN); lv_obj_add_flag(s_food, LV_OBJ_FLAG_HIDDEN); lv_obj_add_flag(s_sessions, LV_OBJ_FLAG_HIDDEN);
    for (unsigned i=0;i<PET_SETTINGS_COUNT;i++) lv_obj_add_flag(s_settings[i],LV_OBJ_FLAG_HIDDEN);
    s_page = s_game.settings ? 3+s_game.settings_page : s_view.adopted ? s_game.page : 7;
    if (s_page==0 || s_page==7) lv_obj_add_flag(s_title,LV_OBJ_FLAG_HIDDEN);
    else lv_obj_remove_flag(s_title,LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(s_game.settings ? s_settings[s_game.settings_page] : !s_view.adopted || s_page==0 ? s_home : s_page==1 ? s_sessions : s_food, LV_OBJ_FLAG_HIDDEN);
    if (s_game.settings) {
        const char *titles[PET_SETTINGS_COUNT]={"换台额度进度","伙伴与连接详情","屏幕亮度","麦克风触发门槛"};
        lv_label_set_text(s_title,titles[s_game.settings_page]);
    }
    else if (s_view.adopted && s_page==1) lv_label_set_text(s_title,"最近三个会话");
    else if (s_view.adopted && s_page==2) lv_label_set_text(s_title,"今天吃了什么");
    lv_label_set_text(s_hint,s_game.pending ? "等待主机确认..." : s_game.settings ? s_game.settings_page>=2 ? "上下选 OK调 长按返回" : "上/下查看  长按OK返回" : !s_view.adopted ? "上/下选择  单击OK确认" : s_page==1 ? "上/下选 OK开 双击翻页" : "双击OK翻页  长按OK设置");
}

static void preferences_ui(void)
{
    for (unsigned setting=0;setting<2;setting++) {
        unsigned selected=setting ? s_preferences.mic_threshold : s_preferences.brightness;
        for (unsigned tier=0;tier<PET_TIER_COUNT;tier++) {
            lv_obj_set_style_bg_color(s_tier_rows[setting][tier],lv_color_hex(tier==selected ? 0xE9F0D9 : 0xF1F4EA),0);
            lv_obj_set_style_border_color(s_tier_rows[setting][tier],lv_color_hex(tier==selected ? 0x527447 : 0xD8E2C9),0);
        }
        lv_label_set_text(s_preferences_status[setting],s_preferences_dirty ? s_preferences_save_ok ? "正在保存..." : "保存失败，将重试" : "已保存，重启后保留");
    }
}

static void quota_ui(void)
{
    bool fresh=s_companion_at && esp_timer_get_time()-s_companion_at < 15000000;
    bool valid=fresh && s_companion.quota_valid;
    if (!valid) {
        lv_label_set_text(s_quota_title,"额度未连接"); lv_label_set_text(s_quota_today,"今日参考未连接");
        lv_label_set_text(s_quota_reset,"重置时间未连接"); lv_label_set_text(s_quota_date,"");
        lv_label_set_text(s_quota_source,"请打开Mac上的换台"); lv_bar_set_value(s_quota_bar,0,LV_ANIM_OFF); lv_obj_add_flag(s_reference_mark,LV_OBJ_FLAG_HIDDEN); return;
    }
    unsigned remaining=s_companion.remaining;
    lv_label_set_text_fmt(s_quota_title,"周剩余 %u.%u%%",remaining/10,remaining%10);
    lv_bar_set_value(s_quota_bar,remaining/10,LV_ANIM_OFF);
    lv_obj_set_style_bg_color(s_quota_bar,lv_color_hex(s_companion.today_valid && s_companion.today < 0 ? 0xBA594A : 0x527447),LV_PART_INDICATOR);
    if (s_companion.reference_valid) {
        lv_obj_set_x(s_reference_mark,14+(212*s_companion.reference)/1000); lv_obj_remove_flag(s_reference_mark,LV_OBJ_FLAG_HIDDEN);
    } else lv_obj_add_flag(s_reference_mark,LV_OBJ_FLAG_HIDDEN);
    int today=s_companion.today < 0 ? -s_companion.today : s_companion.today;
    if (s_companion.today_valid) lv_label_set_text_fmt(s_quota_today,"%s %d.%d%%",s_companion.today < 0 ? "今日超出" : "今日参考剩余",today/10,today%10);
    else lv_label_set_text(s_quota_today,"今日参考待刷新");
    uint32_t elapsed=(uint32_t)((esp_timer_get_time()-s_companion_at)/1000000);
    uint32_t seconds=s_companion.reset_after > elapsed ? s_companion.reset_after-elapsed : 0;
    if (seconds) lv_label_set_text_fmt(s_quota_reset,"重置 %u天 %02u:%02u:%02u",(unsigned)(seconds/86400),(unsigned)(seconds%86400/3600),(unsigned)(seconds%3600/60),(unsigned)(seconds%60));
    else lv_label_set_text(s_quota_reset,"等待额度刷新");
    lv_label_set_text_fmt(s_quota_date,"%s 重置",s_companion.reset_text);
    lv_label_set_text(s_quota_source,s_companion.live ? "账户额度 · 今日参考为自定节奏" : "离线快照 · 非实时额度");
}

static void update_ui(void)
{
    s_view = s_state;
    const pet_sprite_t *current = sprite(pet_species(s_view.adopted ? s_view.family : s_game.choice, s_view.adopted ? s_view.level : 1));
    lv_image_set_src(s_image,current->frames[s_frame%4]); lv_image_set_scale(s_image,s_view.adopted ? 384+((s_view.level-1)%4)*6 : 384);
    char today[24],total[24],text[320]; compact(s_view.today,today,sizeof(today)); compact(s_view.total,total,sizeof(total));
    if (s_view.adopted) {
        lv_label_set_text_fmt(s_level,"%s · Lv.%u/12",current->name_zh,s_view.level); lv_obj_remove_flag(s_bar,LV_OBJ_FLAG_HIDDEN); lv_bar_set_value(s_bar,s_view.progress,LV_ANIM_OFF);
        char inline_today[24],inline_total[24]; compact_inline(s_view.today,inline_today,sizeof(inline_today)); compact_inline(s_view.total,inline_total,sizeof(inline_total));
        lv_label_set_text_fmt(s_today,"%s %s · 累计 %s",s_view.account_source ? "今日入账" : "今日摄入",inline_today,inline_total);
    } else {
        lv_label_set_text(s_level,s_game.confirm ? "确认领养？之后不能更换" : "选择你的初始伙伴"); lv_obj_add_flag(s_bar,LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text(s_today,s_game.confirm ? "再单击OK，开始饲养" : "单击OK，查看领养确认");
    }
    size_t used=(size_t)snprintf(text,sizeof(text),"%s\n\n",*s_view.date ? s_view.date : "等待主机同步");
    for (unsigned i=0;i<s_view.food_count && used<sizeof(text);i++) {
        char amount[24];compact(s_view.food[i].tokens,amount,sizeof(amount));
        int written=snprintf(text+used,sizeof(text)-used,"%.24s\n%s Token\n",s_view.food[i].model,amount);
        if (written<0 || (size_t)written>=sizeof(text)-used) break;
        used+=(size_t)written;
    }
    if (!s_view.food_count && used<sizeof(text)) snprintf(text+used,sizeof(text)-used,"今天还没有新食物\n\n使用AI后即可喂养");
    lv_label_set_text(s_food_text,text);
    for (unsigned i=0;i<3;i++) {
        bool present=i<s_companion.session_count;
        lv_label_set_text(s_session_titles[i],present ? s_companion.sessions[i].title : i==0 ? "暂无会话 / 换台未连接" : "");
        lv_label_set_text(s_session_sources[i],present ? s_companion.sessions[i].openable ? s_companion.sessions[i].source : "暂不可跳转" : "");
        lv_obj_set_style_bg_color(s_session_rows[i],lv_color_hex(present && i==s_game.selected ? 0xE9F0D9 : 0xF1F4EA),0);
        lv_obj_set_style_border_color(s_session_rows[i],lv_color_hex(present && i==s_game.selected ? 0x527447 : 0xF1F4EA),0);
    }
    mic_status_t mic=mic_status();
    char battery[12];
    if (s_battery_soc<0) snprintf(battery,sizeof(battery),"--%%");
    else snprintf(battery,sizeof(battery),"%d%%",s_battery_soc);
    lv_label_set_text_fmt(s_journey,"%s · %s\n成长 %u / 12 · 进度 %u%%\n\n今日 %s Token\n累计 %s Token\n\n%s\n%s · 电量%s\n麦克风：%s",current->name_zh,s_view.adopted ? "已领养" : "待选择",s_view.level,s_view.progress,today,total,s_view.account_source ? "食物：账户增量" : "食物：本地日志",s_received_ble ? "连接：蓝牙" : "连接：USB",battery,mic.ready ? "声音触发跳动" : "未就绪");
    quota_ui(); preferences_ui(); show_page();
}

static void animate(lv_timer_t *timer)
{
    (void)timer; int64_t now=esp_timer_get_time();
    uint32_t elapsed=s_jump_at ? (uint32_t)((now-s_jump_at)/1000) : 480;
    unsigned frame=elapsed<480 ? elapsed/120 : 0;
    int offset=pet_sound_hop(elapsed);
    if (offset!=s_jump_offset) { lv_obj_set_y(s_image,36+offset); s_jump_offset=offset; }
    if (frame!=s_frame) {
        s_frame=frame;
        const pet_sprite_t *current=sprite(pet_species(s_view.adopted ? s_view.family : s_game.choice,s_view.adopted ? s_view.level : 1));
        lv_image_set_src(s_image,current->frames[s_frame]);
    }
    if (elapsed>=480) s_jump_at=0;
    if (now-s_last_status_ui>1000000) {
        bool online=s_received_tick && xTaskGetTickCount()-s_received_tick<pdMS_TO_TICKS(15000);
        lv_label_set_text(s_status,online ? (s_received_ble ? "BLE" : "USB") : "离线");
        battery_ui(); quota_ui(); s_last_status_ui=now;
    }
    if (s_evolve_until && now>s_evolve_until) { lv_obj_add_flag(s_evolve,LV_OBJ_FLAG_HIDDEN); s_evolve_until=0; }
}

static void build_ui(void)
{
    lv_obj_t *screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_hex(0xF7F8EE), 0); lv_obj_remove_flag(screen, LV_OBJ_FLAG_SCROLLABLE);
    s_status=label(screen,"离线",20,16,78,&pet_font_16);
    s_battery=label(screen,"--%",140,16,55,&pet_font_16);
    lv_obj_set_style_text_align(s_battery,LV_TEXT_ALIGN_RIGHT,0);
    lv_obj_t *battery_frame=lv_obj_create(screen);
    lv_obj_set_pos(battery_frame,199,20); lv_obj_set_size(battery_frame,22,11);
    lv_obj_remove_flag(battery_frame,LV_OBJ_FLAG_SCROLLABLE); lv_obj_set_style_pad_all(battery_frame,0,0);
    lv_obj_set_style_radius(battery_frame,2,0); lv_obj_set_style_border_width(battery_frame,1,0);
    lv_obj_set_style_border_color(battery_frame,lv_color_hex(0x527447),0); lv_obj_set_style_bg_opa(battery_frame,LV_OPA_TRANSP,0);
    s_battery_fill=lv_obj_create(battery_frame); lv_obj_set_pos(s_battery_fill,1,1); lv_obj_set_size(s_battery_fill,18,7);
    lv_obj_remove_flag(s_battery_fill,LV_OBJ_FLAG_SCROLLABLE); lv_obj_set_style_border_width(s_battery_fill,0,0); lv_obj_set_style_radius(s_battery_fill,1,0);
    lv_obj_t *battery_tip=lv_obj_create(screen); lv_obj_set_pos(battery_tip,221,23); lv_obj_set_size(battery_tip,3,5);
    lv_obj_set_style_border_width(battery_tip,0,0); lv_obj_set_style_radius(battery_tip,1,0); lv_obj_set_style_bg_color(battery_tip,lv_color_hex(0x527447),0);
    lv_obj_remove_flag(battery_tip,LV_OBJ_FLAG_SCROLLABLE);
    battery_ui();
    s_title = label(screen, "小火龙", 20, 44, 200, &pet_font_20); lv_obj_set_style_text_align(s_title, LV_TEXT_ALIGN_CENTER, 0);
    s_home = container(screen); s_food = container(screen); s_sessions = container(screen);
    lv_obj_set_pos(s_home,0,44); lv_obj_set_height(s_home,244);
    for (unsigned i=0;i<PET_SETTINGS_COUNT;i++) s_settings[i]=container(screen);
    lv_obj_t *arena = lv_obj_create(s_home);
    lv_obj_set_pos(arena, 14, 0); lv_obj_set_size(arena, 212, 190); lv_obj_set_style_bg_color(arena, lv_color_hex(0xE9F0D9), 0);
    lv_obj_set_style_radius(arena, 20, 0); lv_obj_set_style_border_width(arena, 0, 0);
    lv_obj_set_style_pad_all(arena, 0, 0); lv_obj_remove_flag(arena, LV_OBJ_FLAG_SCROLLABLE);
    s_image = lv_image_create(arena); lv_obj_set_pos(s_image, 46, 36); lv_image_set_antialias(s_image,false);
    s_level = label(s_home, "成长 1 / 12", 14, 192, 212, &pet_font_16);
    s_bar = lv_bar_create(s_home); lv_obj_set_pos(s_bar, 14, 214); lv_obj_set_size(s_bar, 212, 6);
    lv_obj_set_style_bg_color(s_bar, lv_color_hex(0xD8E2C9), LV_PART_MAIN); lv_obj_set_style_bg_color(s_bar, lv_color_hex(0x527447), LV_PART_INDICATOR);
    s_today = label(s_home, "今日摄入 0 · 累计 0", 14, 224, 212, &pet_font_16);
    s_food_text = label(s_food, "等待主机同步", 18, 8, 204, &pet_font_16); lv_obj_set_height(s_food_text, 190); lv_label_set_long_mode(s_food_text, LV_LABEL_LONG_WRAP);
    for (unsigned i=0;i<3;i++) {
        s_session_rows[i]=lv_obj_create(s_sessions); lv_obj_set_pos(s_session_rows[i],12,2+67*i); lv_obj_set_size(s_session_rows[i],216,64);
        lv_obj_set_style_pad_all(s_session_rows[i],5,0); lv_obj_set_style_border_width(s_session_rows[i],1,0); lv_obj_set_style_radius(s_session_rows[i],9,0); lv_obj_remove_flag(s_session_rows[i],LV_OBJ_FLAG_SCROLLABLE);
        s_session_titles[i]=label(s_session_rows[i],"",2,0,200,&pet_font_16); lv_obj_set_height(s_session_titles[i],38); lv_label_set_long_mode(s_session_titles[i],LV_LABEL_LONG_WRAP);
        s_session_sources[i]=label(s_session_rows[i],"",2,38,200,&pet_font_16);
    }
    s_quota_title=label(s_settings[0],"",14,8,212,&pet_font_20);
    s_quota_bar=lv_bar_create(s_settings[0]); lv_obj_set_pos(s_quota_bar,14,45); lv_obj_set_size(s_quota_bar,212,9);
    lv_obj_set_style_bg_color(s_quota_bar,lv_color_hex(0xD8E2C9),LV_PART_MAIN);
    s_reference_mark=lv_obj_create(s_settings[0]); lv_obj_set_size(s_reference_mark,2,17); lv_obj_set_y(s_reference_mark,41); lv_obj_set_style_border_width(s_reference_mark,0,0); lv_obj_set_style_bg_color(s_reference_mark,lv_color_hex(0xBA913E),0);
    s_quota_today=label(s_settings[0],"",14,68,212,&pet_font_16); s_quota_reset=label(s_settings[0],"",14,101,212,&pet_font_16);
    s_quota_date=label(s_settings[0],"",14,127,212,&pet_font_16); s_quota_source=label(s_settings[0],"",14,163,212,&pet_font_16); lv_obj_set_height(s_quota_source,40); lv_label_set_long_mode(s_quota_source,LV_LABEL_LONG_WRAP);
    s_journey=label(s_settings[1],"",14,4,212,&pet_font_16); lv_obj_set_height(s_journey,205); lv_label_set_long_mode(s_journey,LV_LABEL_LONG_WRAP);
    const char *tiers[PET_TIER_COUNT]={"低","中","高"};
    for (unsigned setting=0;setting<2;setting++) {
        for (unsigned tier=0;tier<PET_TIER_COUNT;tier++) {
            lv_obj_t *row=lv_obj_create(s_settings[2+setting]); s_tier_rows[setting][tier]=row;
            lv_obj_set_pos(row,14,4+tier*50); lv_obj_set_size(row,212,44);
            lv_obj_set_style_pad_all(row,0,0); lv_obj_set_style_radius(row,9,0);
            lv_obj_set_style_border_width(row,1,0); lv_obj_remove_flag(row,LV_OBJ_FLAG_SCROLLABLE);
            char text[40];
            if (setting) snprintf(text,sizeof(text),"%s门槛",tiers[tier]);
            else snprintf(text,sizeof(text),"%s  %u%%",tiers[tier],pet_brightness_percent(tier));
            label(row,text,14,7,180,&pet_font_20);
        }
        label(s_settings[2+setting],setting ? "低门槛更灵敏" : "默认中档，柔和省电",14,162,212,&pet_font_16);
        s_preferences_status[setting]=label(s_settings[2+setting],"",14,187,212,&pet_font_16);
    }
    s_evolve = label(screen, "进化了！", 50, 132, 140, &pet_font_20); lv_obj_set_style_text_align(s_evolve, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_bg_color(s_evolve, lv_color_hex(0xFFF4CB), 0); lv_obj_set_style_bg_opa(s_evolve, LV_OPA_COVER, 0); lv_obj_set_style_pad_all(s_evolve, 12, 0);
    lv_obj_add_flag(s_evolve, LV_OBJ_FLAG_HIDDEN);
    s_hint=label(screen,"",20,292,200,&pet_font_16);
    update_ui(); lv_timer_create(animate, 30, NULL);
}

static void on_button(bsp_btn_t button, bsp_btn_ev_t event, void *user)
{
    (void)user;
    if (event != BSP_BTN_CLICK && event != BSP_BTN_DOUBLE && event != BSP_BTN_LONG) return;
    app_event_t item = {.kind = 2, .button = button, .event = event};
    if (s_queue) (void)xQueueSend(s_queue, &item, 0);
}

static void status(bool bluetooth)
{
    mic_status_t mic=mic_status();
    char response[1200];
    snprintf(response, sizeof(response), "{\"v\":1,\"type\":\"state\",\"epoch\":\"%s\",\"seq\":%" PRIu64 ",\"level\":%u,\"family\":%u,\"species_id\":%u,\"tokens_today\":\"%" PRIu64 "\",\"pet_tokens_total\":\"%" PRIu64 "\",\"saved\":%s,\"free_heap\":%u,\"page\":%u,\"ble_connected\":%s,\"ble_authenticated\":%s,\"adopted\":%s,\"session_count\":%u,\"quota_valid\":%s,\"pending_action\":%s}\n",
        s_state.epoch, s_state.seq, s_state.level, s_state.family, pet_species(s_state.family, s_state.level), s_state.today, s_state.total,
        s_have_save && s_save_ok && !s_dirty ? "true" : "false", (unsigned)esp_get_free_heap_size(), s_page, pet_ble_connected() ? "true" : "false", pet_ble_authenticated() ? "true" : "false", s_state.adopted ? "true" : "false",s_companion.session_count,s_companion.quota_valid ? "true" : "false",s_game.pending ? "true" : "false");
    size_t used=strlen(response);
    if (used>=2) snprintf(response+used-2,sizeof(response)-used+2,",\"mic_ready\":%s,\"mic_rms\":%u,\"mic_floor\":%u,\"mic_peak\":%u,\"mic_blocks\":%" PRIu32 ",\"mic_onsets\":%" PRIu32 ",\"mic_stack_free\":%" PRIu32 ",\"hop_offset\":%d,\"sprite_frame\":%u}\n",mic.ready ? "true" : "false",mic.rms,mic.floor,mic.peak,mic.blocks,mic.onsets,mic.stack_free,s_jump_offset,s_frame);
    used=strlen(response);
    if (used>=2) snprintf(response+used-2,sizeof(response)-used+2,",\"battery_percent\":%d,\"brightness_tier\":%u,\"brightness_percent\":%u,\"mic_threshold_tier\":%u,\"mic_active_tier\":%u,\"mic_threshold_rms\":%u,\"preferences_saved\":%s}\n",s_battery_soc,s_preferences.brightness,pet_brightness_percent(s_preferences.brightness),s_preferences.mic_threshold,mic.threshold_tier,mic.threshold,!s_preferences_dirty && s_preferences_save_ok ? "true" : "false");
    used=strlen(response);
    if (used>=2) snprintf(response+used-2,sizeof(response)-used+2,",\"brightness_pwm_percent\":%d}\n",bsp_display_backlight_percent());
    reply(bluetooth, response);
}

// Capture the RGB565 buffers actually rendered on the board. No full-frame
// allocation is needed on this no-PSRAM device; one bounded RLE row is streamed.
static void capture_flush(lv_event_t *event)
{
    if (!s_capturing) return;
    lv_display_t *display = lv_event_get_target(event);
    const lv_area_t *area = lv_event_get_param(event);
    lv_draw_buf_t *buffer = lv_display_get_buf_active(display);
    if (!area || !buffer || !buffer->data || lv_display_get_color_format(display) != LV_COLOR_FORMAT_RGB565) return;
    int width = lv_area_get_width(area);
    if (width <= 0 || width > 240 || buffer->header.stride < (unsigned)width * 2) return;
    static const char hex[] = "0123456789abcdef";
    char message[1600];
    for (int y = area->y1; y <= area->y2; y++) {
        const uint16_t *row = (const uint16_t *)(buffer->data + (y - area->y1) * buffer->header.stride);
        size_t used = (size_t)snprintf(message, sizeof(message), "{\"v\":1,\"type\":\"capture_row\",\"y\":%d,\"x\":%d,\"width\":%d,\"pixels\":\"", y, (int)area->x1, width);
        for (int x = 0; x < width;) {
            uint16_t pixel = row[x]; unsigned count = 1;
            while (x + (int)count < width && row[x + count] == pixel && count < 255) count++;
            message[used++] = hex[(pixel >> 12) & 15]; message[used++] = hex[(pixel >> 8) & 15];
            message[used++] = hex[(pixel >> 4) & 15]; message[used++] = hex[pixel & 15];
            message[used++] = hex[count >> 4]; message[used++] = hex[count & 15]; x += (int)count;
        }
        memcpy(message + used, "\"}\n", 4); transmit(message); s_capture_rows++;
    }
}
static void capture(void)
{
    if (!bsp_lvgl_lock(1000)) { transmit("{\"v\":1,\"type\":\"error\",\"code\":\"display_busy\"}\n"); return; }
    char header[128]; snprintf(header, sizeof(header), "{\"v\":1,\"type\":\"capture_begin\",\"width\":240,\"height\":320,\"format\":\"rgb565-rle6\",\"page\":%u}\n", s_page); transmit(header);
    s_capture_rows = 0; s_capturing = true;
    lv_obj_invalidate(lv_screen_active()); lv_refr_now(s_display);
    s_capturing = false; bsp_lvgl_unlock();
    snprintf(header, sizeof(header), "{\"v\":1,\"type\":\"capture_end\",\"rows\":%u}\n", s_capture_rows); transmit(header);
}

static void microphone_task(void *argument)
{
    (void)argument;
    pet_sound_t detector={0};
    static int16_t pcm[320]; // Single worker owns 640 bytes, clears every block.
    esp_err_t result=bsp_audio_init();
    if (result==ESP_OK) result=bsp_audio_set_format(16000,16,1);
    if (result==ESP_OK) bsp_audio_set_volume(0);
    while (result==ESP_OK) {
        result=bsp_audio_read(pcm,sizeof(pcm));
        if (result!=ESP_OK) break;
        uint16_t rms=pet_sound_rms(pcm,320);
        portENTER_CRITICAL(&s_mic_lock);
        unsigned tier=s_mic_threshold_tier;
        portEXIT_CRITICAL(&s_mic_lock);
        pet_sound_set_tier(&detector,tier);
        bool onset=pet_sound_observe(&detector,rms);
        memset(pcm,0,sizeof(pcm));
        portENTER_CRITICAL(&s_mic_lock);
        s_mic.ready=true; s_mic.rms=rms; s_mic.floor=detector.floor;
        s_mic.threshold_tier=detector.threshold_tier;
        s_mic.threshold=pet_mic_threshold(detector.threshold_tier,detector.floor);
        s_mic.blocks=detector.blocks; s_mic.stack_free=uxTaskGetStackHighWaterMark(NULL);
        if (rms>s_mic.peak) s_mic.peak=rms;
        if (onset) s_mic.onsets++;
        portEXIT_CRITICAL(&s_mic_lock);
        if (onset) {
            (void)xQueueSend(s_queue,&s_mic_onset_event,0);
        }
        // I2S normally blocks 20 ms; yield even when draining queued DMA.
        vTaskDelay(1);
    }
    memset(pcm,0,sizeof(pcm));
    portENTER_CRITICAL(&s_mic_lock); s_mic.ready=false; portEXIT_CRITICAL(&s_mic_lock);
    (void)bsp_audio_sleep();
    ESP_LOGE("token_pet","Microphone unavailable: %s",esp_err_to_name(result));
    (void)xQueueSend(s_queue,&s_mic_failure_event,0);
    vTaskDelete(NULL);
}

static void app_task(void *argument)
{
    (void)argument; app_event_t event;
    for (;;) {
        if (xQueueReceive(s_queue, &event, pdMS_TO_TICKS(100)) == pdTRUE) {
            if (event.kind == 1) {
                bool previously_adopted=s_state.adopted;
                unsigned old_species = pet_species(s_state.family, s_state.level);
                pet_result_t applied = pet_apply(&s_state, &event.snapshot);
                if (applied != PET_REJECTED) {
                    s_received_tick = xTaskGetTickCount(); s_received_ble = event.bluetooth;
                    if (applied == PET_APPLIED) {
                        s_dirty = true;
                        if (bsp_lvgl_lock(1000)) {
                            update_ui();
                            if (previously_adopted && old_species != pet_species(s_state.family, s_state.level)) { lv_obj_remove_flag(s_evolve, LV_OBJ_FLAG_HIDDEN); s_evolve_until = esp_timer_get_time() + 1800000; }
                            bsp_lvgl_unlock();
                        }
                    }
                    char ack[128];
                    snprintf(ack, sizeof(ack), "{\"v\":1,\"type\":\"ack\",\"epoch\":\"%s\",\"seq\":%" PRIu64 "}\n", s_state.epoch, s_state.seq);
                    reply(event.bluetooth, ack);
                } else reply(event.bluetooth, "{\"v\":1,\"type\":\"error\",\"code\":\"snapshot_rejected\"}\n");
            } else if (event.kind == 2 && bsp_lvgl_lock(1000)) {
                pet_game_action_t action=pet_game_press(&s_game,event.button,event.event,s_state.adopted,s_companion.session_count);
                bool preferences_changed=action==PET_GAME_BRIGHTNESS || action==PET_GAME_MIC_THRESHOLD;
                if (preferences_changed) {
                    uint8_t *tier=action==PET_GAME_BRIGHTNESS ? &s_preferences.brightness : &s_preferences.mic_threshold;
                    *tier=(*tier+1)%PET_TIER_COUNT;
                    s_preferences_dirty=true; s_preferences_save_ok=true;
                    portENTER_CRITICAL(&s_mic_lock);
                    s_mic_threshold_tier=s_preferences.mic_threshold;
                    portEXIT_CRITICAL(&s_mic_lock);
                } else if (action==PET_GAME_ADOPT || action==PET_GAME_OPEN) {
                    snprintf(s_request,sizeof(s_request),"%08" PRIx32 "%08" PRIx32 "%016" PRIx64,s_boot_id,++s_action_counter,(uint64_t)esp_timer_get_time());
                    if (action==PET_GAME_ADOPT) snprintf(s_action,sizeof(s_action),"{\"v\":1,\"type\":\"action\",\"action\":\"adopt\",\"request\":\"%s\",\"epoch\":\"%s\",\"family\":%u}\n",s_request,s_state.epoch,s_game.choice);
                    else snprintf(s_action,sizeof(s_action),"{\"v\":1,\"type\":\"action\",\"action\":\"open\",\"request\":\"%s\",\"epoch\":\"%s\",\"handle\":\"%s\"}\n",s_request,s_state.epoch,s_companion.sessions[s_game.selected].handle);
                    s_action_at=0;
                }
                update_ui(); bsp_lvgl_unlock();
                if (preferences_changed) bsp_display_backlight(pet_brightness_percent(s_preferences.brightness));
            } else if (event.kind == 6 && bsp_lvgl_lock(1000)) {
                s_companion=event.companion; s_companion_at=esp_timer_get_time();
                if (s_game.selected>=s_companion.session_count) s_game.selected=0;
                update_ui(); bsp_lvgl_unlock();
            } else if (event.kind == 7 && !strcmp(s_request,event.control.request) && bsp_lvgl_lock(1000)) {
                bool adoption=strstr(s_action,"adopt")!=NULL;
                s_game.pending=false; s_game.confirm=false; s_action[0]=0;
                update_ui();
                if (event.control.code) lv_label_set_text(s_hint,"操作未完成，请重试");
                else lv_label_set_text(s_hint,adoption ? "领养成功，等待同步" : "已在Mac打开会话");
                bsp_lvgl_unlock();
            } else if (event.kind == 3) status(event.bluetooth);
            else if (event.kind==8 && bsp_lvgl_lock(1000)) {
                s_jump_at=esp_timer_get_time(); bsp_lvgl_unlock();
            } else if (event.kind==9 && bsp_lvgl_lock(1000)) {
                update_ui(); bsp_lvgl_unlock();
            }
            else if (event.kind == 4) capture();
            else if (event.kind == 5) {
                bool ok = pet_ble_provision(event.key);
                transmit(ok ? "{\"v\":1,\"type\":\"ble_provisioned\"}\n" : "{\"v\":1,\"type\":\"error\",\"code\":\"ble_provision_failed\"}\n");
            }
        }
        if (s_game.pending && *s_action && esp_timer_get_time()-s_action_at > 2000000) {
            bool online=s_received_tick && xTaskGetTickCount()-s_received_tick < pdMS_TO_TICKS(15000);
            if (online) reply(s_received_ble,s_action);
            s_action_at=esp_timer_get_time();
        }
        // Gauge I/O stays outside LVGL and button callbacks. The BSP bounds
        // each read to 100 ms; refresh the cached percentage every five seconds.
        if (s_battery_ready && esp_timer_get_time()-s_battery_at>5000000) {
            int soc=bsp_battery_soc(); s_battery_at=esp_timer_get_time();
            if (bsp_lvgl_lock(1000)) { s_battery_soc=soc; battery_ui(); bsp_lvgl_unlock(); }
        }
        if (s_dirty && (!s_have_save || esp_timer_get_time() - s_saved_at > 10000000)) {
            s_save_ok = pet_store_save(&s_state); s_saved_at = esp_timer_get_time();
            if (s_save_ok) { s_have_save = true; s_dirty = false; }
        }
        if (s_preferences_dirty && (s_preferences_save_ok || esp_timer_get_time()-s_preferences_saved_at>2000000)) {
            s_preferences_save_ok=pet_store_preferences_save(&s_preferences);
            s_preferences_saved_at=esp_timer_get_time();
            if (s_preferences_save_ok) s_preferences_dirty=false;
            if (bsp_lvgl_lock(1000)) { preferences_ui(); bsp_lvgl_unlock(); }
        }
    }
}

static void submit(const char *line, size_t length, bool bluetooth)
{
    app_event_t event = {.bluetooth = bluetooth};
    pet_message_t message = pet_decode_extended(line, length, &event.snapshot, event.key, &event.companion, &event.control);
    event.kind = message == PET_MESSAGE_SNAPSHOT ? 1 : message == PET_MESSAGE_STATUS ? 3 :
        !bluetooth && message == PET_MESSAGE_CAPTURE ? 4 : !bluetooth && message == PET_MESSAGE_BLE_KEY ? 5 : message == PET_MESSAGE_COMPANION ? 6 : message == PET_MESSAGE_RESULT ? 7 : !bluetooth && message == PET_MESSAGE_INPUT ? 2 : 0;
    if (message==PET_MESSAGE_INPUT) { event.button=event.control.button; event.event=event.control.event; }
    if (!event.kind || xQueueSend(s_queue, &event, 0) != pdTRUE)
        reply(bluetooth, "{\"v\":1,\"type\":\"error\",\"code\":\"invalid_or_busy\"}\n");
}
static void usb_line(const char *line, size_t length, void *context) { (void)context; submit(line, length, false); }
static void ble_line(const char *line, size_t length) { submit(line, length, true); }
static void usb_task(void *argument)
{
    (void)argument; uint8_t bytes[128]; int64_t last_hello = 0;
    for (;;) {
        if (esp_timer_get_time() - last_hello > 2000000) {
            transmit("{\"v\":1,\"type\":\"hello\",\"app\":\"token-pet\",\"firmware\":\"0.4.2\",\"width\":240,\"height\":320,\"ble\":true,\"mic\":true}\n"); last_hello = esp_timer_get_time();
        }
        int received = usb_serial_jtag_read_bytes(bytes, sizeof(bytes), pdMS_TO_TICKS(100));
        if (received > 0) pet_stream_feed(&s_usb_stream, bytes, (size_t)received, usb_line, NULL);
    }
}

void app_main(void)
{
    memset(&s_state, 0, sizeof(s_state)); s_state.level = 1;
    esp_err_t nvs_error = nvs_flash_init();
    if (nvs_error == ESP_OK) s_have_save = pet_store_load(&s_state); else s_save_ok = false;
    (void)pet_store_preferences_load(&s_preferences);
    s_mic_threshold_tier=s_preferences.mic_threshold;
    s_game.choice=s_state.family; s_boot_id=esp_random();
    usb_serial_jtag_driver_config_t usb = {.rx_buffer_size = 4096, .tx_buffer_size = 4096};
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&usb));
    s_tx_lock = xSemaphoreCreateMutex(); s_queue = xQueueCreate(6, sizeof(app_event_t));
    if (!s_tx_lock || !s_queue) { ESP_LOGE("token_pet", "Unable to allocate application queues"); return; }
    ESP_ERROR_CHECK(bsp_display_init());
    s_display = bsp_lvgl_init();
    if (!s_display) { ESP_LOGE("token_pet", "LVGL initialization failed"); return; }
    s_battery_ready=bsp_battery_init()==ESP_OK;
    if (s_battery_ready) s_battery_soc=bsp_battery_soc();
    s_battery_at=esp_timer_get_time();
    if (!bsp_lvgl_lock(1000)) return;
    build_ui(); lv_display_add_event_cb(s_display, capture_flush, LV_EVENT_FLUSH_START, NULL); bsp_lvgl_unlock(); bsp_display_backlight(pet_brightness_percent(s_preferences.brightness));
    ESP_ERROR_CHECK(bsp_button_init(on_button, NULL));
    if (!pet_ble_start(ble_line)) ESP_LOGE("token_pet", "BLE initialization failed");
    if (xTaskCreate(app_task, "pet_app", 6144, NULL, 5, NULL) != pdPASS || xTaskCreate(usb_task, "pet_usb", 6144, NULL, 4, NULL) != pdPASS)
        ESP_LOGE("token_pet", "Unable to start application workers");
    if (xTaskCreate(microphone_task,"pet_mic",4096,NULL,4,NULL)!=pdPASS)
        ESP_LOGE("token_pet","Unable to start microphone worker");
}
