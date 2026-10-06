#include "pet_stream.h"
void pet_stream_feed(pet_stream_t *stream, const uint8_t *bytes, size_t count, pet_line_callback_t callback, void *context)
{
    for (size_t i = 0; i < count; i++) {
        if (bytes[i] == '\n') {
            if (!stream->discarding && stream->length) {
                stream->line[stream->length] = 0;
                callback(stream->line, stream->length, context);
            }
            stream->length = 0; stream->discarding = false;
        } else if (!stream->discarding) {
            if (stream->length == PET_LINE_MAX) { stream->discarding = true; stream->length = 0; }
            else stream->line[stream->length++] = (char)bytes[i];
        }
    }
}
