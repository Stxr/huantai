#pragma once
#include <stdbool.h>
#include <stddef.h>
typedef void (*pet_ble_line_callback_t)(const char *, size_t);
bool pet_ble_start(pet_ble_line_callback_t callback);
bool pet_ble_provision(const char key[65]);
bool pet_ble_send(const char *text);
bool pet_ble_connected(void);
bool pet_ble_authenticated(void);
