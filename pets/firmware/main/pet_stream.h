#pragma once
#include "pet_protocol.h"
#include <stdint.h>
typedef struct { char line[PET_LINE_MAX + 1]; size_t length; bool discarding; } pet_stream_t;
typedef void (*pet_line_callback_t)(const char *, size_t, void *);
void pet_stream_feed(pet_stream_t *stream, const uint8_t *bytes, size_t count, pet_line_callback_t callback, void *context);
