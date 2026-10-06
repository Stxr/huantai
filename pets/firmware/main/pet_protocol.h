#pragma once
#include "pet_model.h"
#include "pet_companion.h"
#include <stddef.h>
#define PET_LINE_MAX 2048
typedef enum { PET_MESSAGE_INVALID = 0, PET_MESSAGE_SNAPSHOT, PET_MESSAGE_STATUS, PET_MESSAGE_CAPTURE, PET_MESSAGE_BLE_KEY, PET_MESSAGE_AUTH, PET_MESSAGE_COMPANION, PET_MESSAGE_RESULT, PET_MESSAGE_INPUT } pet_message_t;
pet_message_t pet_decode(const char *line, size_t length, pet_state_t *snapshot);

pet_message_t pet_decode_control(const char *line, size_t length, pet_state_t *snapshot, char key[65]);
pet_message_t pet_decode_extended(const char *line, size_t length, pet_state_t *snapshot, char key[65], pet_companion_t *companion, pet_control_t *control);
