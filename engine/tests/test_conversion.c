/*
 * (c) 2026 CrystalGipsy, for LyrionPlay. GNU General Public License v3 or later, as the
 * engine it tests (../LICENSE.txt).
 *
 * Exhaustive check of ca_s32_to_float() (output_coreaudio_conv.h): every one of the 2^24
 * possible 24-bit samples, left-justified in 32 bits as squeezelite holds them, must come back
 * exactly from the Float32 the HAL receives -- both as a 24-bit integer (what an int24 DAC
 * format gets) and as the original 32-bit word (an int32 DAC format).
 *
 * Anti-test: a value with 25 significant bits must NOT survive, which proves the comparison can
 * see a rounding at all.
 */
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "../output_coreaudio_conv.h"

static bool survives(int32_t s32, int32_t expect24) {
	float f = ca_s32_to_float(s32);
	double as24 = (double)f * 8388608.0;     /* 2^23 */
	double as32 = (double)f * 2147483648.0;  /* 2^31 */
	return as24 == (double)expect24 && as32 == (double)s32;
}

int main(void) {
	unsigned long checked = 0, failed = 0;
	int32_t v, first_fail = 0;
	bool anti;

	for (v = -(1 << 23); v < (1 << 23); v++) {
		int32_t s32 = (int32_t)((uint32_t)v << 8);
		if (!survives(s32, v)) {
			if (!failed) first_fail = v;
			failed++;
		}
		checked++;
	}

	/* 0x01000001 has 25 significant bits: Float32 keeps 24, so this must round */
	anti = (double)ca_s32_to_float(0x01000001) * 2147483648.0 != (double)0x01000001;

	printf("conversion: %lu values checked, %lu failed", checked, failed);
	if (failed) printf(" (first: %d)", first_fail);
	printf("; anti-test (25 significant bits must round): %s\n", anti ? "rounded, as expected" : "DID NOT ROUND");
	printf("result: %s\n", failed == 0 && anti && checked == (1ul << 24) ? "PASS" : "FAIL");
	return failed == 0 && anti && checked == (1ul << 24) ? 0 : 1;
}
