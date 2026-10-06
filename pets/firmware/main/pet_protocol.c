#include "pet_protocol.h"
#include "cJSON.h"
#include <math.h>
#include <string.h>

static const cJSON *field(const cJSON *object, const char *key) { return cJSON_GetObjectItemCaseSensitive(object, key); }
static bool text(const cJSON *object, const char *key, char *out, size_t capacity)
{
    const cJSON *item = field(object, key);
    if (!cJSON_IsString(item) || !item->valuestring || strlen(item->valuestring) >= capacity) return false;
    memcpy(out, item->valuestring, strlen(item->valuestring) + 1);
    return true;
}
static bool number(const cJSON *object, const char *key, unsigned maximum, unsigned *out)
{
    const cJSON *item = field(object, key);
    if (!cJSON_IsNumber(item) || !isfinite(item->valuedouble) || item->valuedouble < 0 ||
        item->valuedouble > maximum || floor(item->valuedouble) != item->valuedouble) return false;
    *out = (unsigned)item->valuedouble;
    return true;
}
static bool count(const cJSON *object, const char *key, uint64_t *out)
{
    const cJSON *item = field(object, key);
    return cJSON_IsString(item) && pet_parse_u64(item->valuestring, out);
}

static bool unique_keys(const cJSON *item)
{
    if (cJSON_IsObject(item)) {
        for (const cJSON *a = item->child; a; a = a->next)
            for (const cJSON *b = a->next; b; b = b->next)
                if (a->string && b->string && !strcmp(a->string, b->string)) return false;
    }
    for (const cJSON *child = item->child; child; child = child->next)
        if (!unique_keys(child)) return false;
    return true;
}

pet_message_t pet_decode_extended(const char *line, size_t length, pet_state_t *snapshot, char key[65], pet_companion_t *companion, pet_control_t *control)
{
    if (!line || !snapshot || length == 0 || length > PET_LINE_MAX || memchr(line, 0, length)) return PET_MESSAGE_INVALID;
    for (size_t i = 0; i + 6 <= length; i++)
        if (!memcmp(line + i, "\\u0000", 6)) return PET_MESSAGE_INVALID;
    // cJSON recursion is bounded before allocation, ignoring braces inside strings.
    unsigned depth = 0; bool quoted = false, escaped = false;
    for (size_t i = 0; i < length; i++) {
        char ch = line[i];
        if (escaped) { escaped = false; continue; }
        if (quoted && ch == '\\') { escaped = true; continue; }
        if (ch == '"') { quoted = !quoted; continue; }
        if (!quoted && (ch == '{' || ch == '[') && ++depth > 8) return PET_MESSAGE_INVALID;
        if (!quoted && (ch == '}' || ch == ']')) { if (!depth) return PET_MESSAGE_INVALID; depth--; }
    }
    if (quoted || depth) return PET_MESSAGE_INVALID;
    const char *end = NULL;
    cJSON *object = cJSON_ParseWithLengthOpts(line, length, &end, false);
    pet_message_t result = PET_MESSAGE_INVALID;
    unsigned version;
    if (!object || !cJSON_IsObject(object) || !unique_keys(object) || !number(object, "v", 1, &version) || version != 1) goto done;
    while (end && end < line + length && (*end == ' ' || *end == '\r' || *end == '\t' || *end == '\n')) end++;
    if (end != line + length) goto done;
    const cJSON *type = field(object, "type");
    if (!cJSON_IsString(type)) goto done;
    if (!strcmp(type->valuestring, "ble_provision") || !strcmp(type->valuestring, "auth")) {
        if (!key || !text(object, "key", key, 65) || strlen(key) != 64) goto done;
        for (unsigned i = 0; i < 64; i++)
            if (!((key[i] >= '0' && key[i] <= '9') || (key[i] >= 'a' && key[i] <= 'f'))) goto done;
        result = !strcmp(type->valuestring, "auth") ? PET_MESSAGE_AUTH : PET_MESSAGE_BLE_KEY;
        goto done;
    }
    if (!strcmp(type->valuestring, "status")) { result = PET_MESSAGE_STATUS; goto done; }
    if (!strcmp(type->valuestring, "capture")) { result = PET_MESSAGE_CAPTURE; goto done; }
    if (!strcmp(type->valuestring, "input")) {
        unsigned button, event;
        if (!control || !number(object,"button",2,&button) || !number(object,"event",3,&event) || event < 1) goto done;
        control->button = button; control->event = event; result = PET_MESSAGE_INPUT; goto done;
    }
    if (!strcmp(type->valuestring, "action_result")) {
        unsigned code;
        if (!control || !text(object,"request",control->request,33) || strlen(control->request)!=32 || !number(object,"code",1,&code)) goto done;
        control->code = code; result = PET_MESSAGE_RESULT; goto done;
    }
    if (!strcmp(type->valuestring, "companion")) {
        if (!companion) goto done;
        memset(companion,0,sizeof(*companion));
        if (!cJSON_IsBool(field(object,"available")) || !cJSON_IsBool(field(object,"quota_valid"))) goto done;
        companion->available = cJSON_IsTrue(field(object,"available")); companion->quota_valid = cJSON_IsTrue(field(object,"quota_valid"));
        unsigned remaining, reset;
        if (!number(object,"remaining",1000,&remaining) || !number(object,"reset_after",604800,&reset) || !text(object,"reset_text",companion->reset_text,24)) goto done;
        companion->remaining=remaining; companion->reset_after=reset; companion->live=cJSON_IsTrue(field(object,"live"));
        const cJSON *reference=field(object,"reference"), *today=field(object,"today");
        if (!cJSON_IsNull(reference)) { unsigned n; if (!number(object,"reference",1000,&n)) goto done; companion->reference=n; companion->reference_valid=true; }
        if (!cJSON_IsNull(today)) {
            if (!cJSON_IsNumber(today) || !isfinite(today->valuedouble) || today->valuedouble < -1000 || today->valuedouble > 1000 || floor(today->valuedouble)!=today->valuedouble) goto done;
            companion->today=(int16_t)today->valuedouble; companion->today_valid=true;
        }
        const cJSON *rows=field(object,"sessions"), *row;
        if (!cJSON_IsArray(rows) || cJSON_GetArraySize(rows)>3) goto done;
        cJSON_ArrayForEach(row,rows) {
            pet_session_t *target=&companion->sessions[companion->session_count];
            if (!text(row,"handle",target->handle,17) || strlen(target->handle)!=16 || !text(row,"title",target->title,73) || !text(row,"source",target->source,17) || !cJSON_IsBool(field(row,"openable"))) goto done;
            for (unsigned i=0;i<16;i++) if (!((target->handle[i]>='a'&&target->handle[i]<='f')||(target->handle[i]>='0'&&target->handle[i]<='9'))) goto done;
            target->openable=cJSON_IsTrue(field(row,"openable")); companion->session_count++;
        }
        result=PET_MESSAGE_COMPANION; goto done;
    }
    if (strcmp(type->valuestring, "snapshot")) goto done;
    memset(snapshot, 0, sizeof(*snapshot));
    unsigned family, level, progress;
    const cJSON *seq = field(object, "seq");
    if (!cJSON_IsNumber(seq) || !isfinite(seq->valuedouble) || seq->valuedouble < 0 ||
        seq->valuedouble > 9007199254740991.0 || floor(seq->valuedouble) != seq->valuedouble ||
        !number(object, "family", 5, &family) || !number(object, "level", 12, &level) || level < 1 ||
        !number(object, "progress", 100, &progress) ||
        !text(object, "epoch", snapshot->epoch, sizeof(snapshot->epoch)) || strlen(snapshot->epoch) != 32 ||
        !text(object, "date", snapshot->date, sizeof(snapshot->date)) || strlen(snapshot->date) != 10 ||
        !count(object, "tokens_today", &snapshot->today) || !count(object, "pet_tokens_total", &snapshot->total)) goto done;
    for (unsigned i = 0; i < 32; i++) if (!((snapshot->epoch[i] >= '0' && snapshot->epoch[i] <= '9') || (snapshot->epoch[i] >= 'a' && snapshot->epoch[i] <= 'f'))) goto done;
    for (unsigned i = 0; i < 10; i++) {
        if (i == 4 || i == 7) { if (snapshot->date[i] != '-') goto done; }
        else if (snapshot->date[i] < '0' || snapshot->date[i] > '9') goto done;
    }
    const cJSON *source = field(object, "source");
    if (!cJSON_IsString(source) || (strcmp(source->valuestring, "local") && strcmp(source->valuestring, "account"))) goto done;
    snapshot->account_source = !strcmp(source->valuestring, "account");
    const cJSON *adopted = field(object,"adopted");
    if (adopted && !cJSON_IsBool(adopted)) goto done;
    snapshot->adopted = cJSON_IsTrue(adopted);
    snapshot->seq = (uint64_t)seq->valuedouble;
    snapshot->family = (uint8_t)family; snapshot->level = (uint8_t)level; snapshot->progress = (uint8_t)progress;
    const cJSON *foods = field(object, "food");
    if (!cJSON_IsArray(foods) || cJSON_GetArraySize(foods) > PET_FOOD_COUNT) goto done;
    const cJSON *food;
    cJSON_ArrayForEach(food, foods) {
        pet_food_t *target = &snapshot->food[snapshot->food_count];
        if (!text(food, "model", target->model, sizeof(target->model)) || !*target->model || !count(food, "tokens", &target->tokens)) goto done;
        for (const char *ch = target->model; *ch; ch++)
            if (!( (*ch >= 'a' && *ch <= 'z') || (*ch >= 'A' && *ch <= 'Z') || (*ch >= '0' && *ch <= '9') || *ch == '.' || *ch == '-' || *ch == '_' || *ch == '/')) goto done;
        snapshot->food_count++;
    }
    if (snapshot->today > snapshot->total) goto done;
    result = PET_MESSAGE_SNAPSHOT;
done:
    cJSON_Delete(object);
    return result;
}

pet_message_t pet_decode(const char *line, size_t length, pet_state_t *snapshot)
{
    return pet_decode_control(line, length, snapshot, NULL);
}

pet_message_t pet_decode_control(const char *line, size_t length, pet_state_t *snapshot, char key[65])
{
    return pet_decode_extended(line,length,snapshot,key,NULL,NULL);
}
