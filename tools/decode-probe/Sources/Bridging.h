#include <stddef.h>
#include <stdint.h>
// rust/src/lib.rs
ptrdiff_t probe_mpa_decode(const uint8_t *input, size_t len, int16_t *out, size_t cap,
                           uint32_t *channels, uint32_t *layer, uint32_t *frames);
