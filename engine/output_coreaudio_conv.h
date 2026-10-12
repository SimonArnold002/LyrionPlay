/*
 *  output_coreaudio_conv.h - sample conversion for the CoreAudio output (LyrionPlay)
 *  (c) 2026 CrystalGipsy
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 */

#ifndef OUTPUT_COREAUDIO_CONV_H
#define OUTPUT_COREAUDIO_CONV_H

#include <stdint.h>

// squeezelite's output buffer holds signed 32-bit samples with the audio left-justified.
// The HAL takes Float32 in [-1, 1). Converting int -> float rounds only when a value has more
// than 24 significant bits, and the scale is a power of two, so any sample of 24 bits or fewer
// (every PCM source LMS sends, and every DoP word) survives exactly; the HAL's own Float32 ->
// int24/int32 conversion to the DAC then restores the original integer. Pinned for all 2^24
// values by tests/test_conversion.c.
static inline float ca_s32_to_float(int32_t sample) {
	return (float)sample * (1.0f / 2147483648.0f);
}

#endif
