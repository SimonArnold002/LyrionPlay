/*
 * (c) 2026 CrystalGipsy, for LyrionPlay. GNU General Public License v3 or later, as the
 * engine it tests (../LICENSE.txt).
 *
 * Regression suite for the WAV/AIFF header reader in pcm.c (`_check_header`), which reads every PCM
 * stream since LyrionPlay passes -W (`pcm_check_header`). With -W the PCM codec lists `wav`, so LMS
 * sends WAV and AIFF files with their headers (`wav wav`, `aif aif` unstripped: TranscodingHelper.pm
 * 454-458; prioritizeNative puts `wav` first), SqueezeDSP offers its PCM output, and a header's
 * format wins over LMS's announce, which is always the SOURCE track's.
 *
 * The fixtures are what the writers put out:
 *   - SqueezeDSP's PCM output: 24-bit WAV, its engine's 46-byte header (format tag 1, fmt of 18);
 *   - FFmpeg's AIFF for 16-bit little-endian PCM: an AIFC whose COMM names 'sowt' (aiffenc.c, n7.1),
 *     which LMS plays little-endian when it strips the header (Slim/Formats/AIFF.pm);
 *   - macOS's own AIFF and AIFC (afconvert -f AIFF / -f AIFC -d BEI16, measured 2026-11-05): an FLLR
 *     chunk pads the samples to byte 4096, and the AIFC's COMM is afconvert's own bytes ('twos').
 *
 * pcm.c is #included (PCM_SOURCE names it, so the suite can be built against an older copy to prove
 * a test fails there) and linked with upstream's buffer.c and dop.c; the rest of the engine is
 * stubbed. Each test runs in its own child process (fresh statics) with a timeout. Prints one line
 * per test and a summary line; exits 0 only if every test passed.
 *
 * Build and run: make -f Makefile.coreaudio tests/test_pcm_header && ./tests/test_pcm_header
 * Against an older copy (anti-run), into another file:
 *   cc ... -DPCM_SOURCE='"/path/old_pcm.c"' -o /tmp/t tests/test_pcm_header.c buffer.c dop.c
 */

#ifndef PCM_SOURCE
#define PCM_SOURCE "../pcm.c"
#endif
#include PCM_SOURCE

#include <errno.h>
#include <stdarg.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

// ---- the rest of the engine, stubbed: pcm.c reaches only these ----

static struct buffer stream_buffer, output_buffer;
struct buffer *streambuf = &stream_buffer, *outputbuf = &output_buffer;
struct streamstate stream;
struct outputstate output;
struct decodestate decode;
struct processstate process;
log_level loglevel = lINFO;

// decode.c: the rate the output is asked for; nothing is resampled here
unsigned decode_newstream(unsigned sample_rate, unsigned supported_rates[]) { return sample_rate; }
void _checkfade(bool start) {}

// the engine's log, kept to be searched; pcm_open logs the announce in the same words as the header's
// format, so a header's line is looked for after its chunk's
static char log_text[16384];
static bool logged_after(const char *mark, const char *text) {
	const char *m = strstr(log_text, mark);
	return m && strstr(m, text);
}
const char *logtime(void) { return ""; }
void logprint(const char *fmt, ...) {
	size_t used = strlen(log_text);
	va_list args;
	va_start(args, fmt);
	vsnprintf(log_text + used, sizeof(log_text) - used, fmt, args);
	va_end(args);
}

// ---- harness ----

#define FRAMES 64
#define FIXTURE (8192 + FRAMES * 6)

static int failures = 0;

#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("    FAILED: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void setup(void) {
	buf_init(streambuf, 2 * 1024 * 1024);
	buf_init(outputbuf, 1024 * 1024);
	decode.direct = true;          // no resampler: the decoder writes the output buffer itself
	stream.state = STREAMING_HTTP; // LMS's stream, not a local file: only -W reads its header
}

static void le(u8_t *p, u32_t v, int n) { while (n--) { *p++ = v & 0xFF; v >>= 8; } }
static void be(u8_t *p, u32_t v, int n) { for (int i = n - 1; i >= 0; i--) { p[i] = v & 0xFF; v >>= 8; } }

// LMS's strm: the codec opened as announced, 16-bit ('1') 44.1k ('3') stereo, '0' big-endian or '1'
// little; then the stream's bytes as they arrive, and the decode thread's calls
static struct codec *pcm;
static void announce(u8_t endian) {
	pcm = register_pcm();
	pcm->open('1', '3', '2', endian);
	decode.new_stream = true;
}
static void arrive(const u8_t *bytes, unsigned n) {
	memcpy(streambuf->writep, bytes, n);
	_buf_inc_writep(streambuf, n);
}
static void decode_calls(int n) { while (n--) pcm->decode(); }

static s32_t *played(void) { return (s32_t *)output.track_start; }
static unsigned frames_played(void) {
	return output.track_start ? (outputbuf->writep - output.track_start) / BYTES_PER_FRAME : 0;
}

// the music: 16-bit stereo for the AIFFs (afconvert's test file's), 24-bit for the WAV
static u32_t aif_l(unsigned i) { return 0x1234 + i; }
static u32_t aif_r(unsigned i) { return 0xdcbb - i; }
static u32_t wav_l(unsigned i) { return 0x100000 + i; }
static u32_t wav_r(unsigned i) { return 0x200000 + i * 7; }

static unsigned samples16(u8_t *p, bool big) {
	for (unsigned i = 0; i < FRAMES; i++, p += 4) {
		if (big) { be(p, aif_l(i), 2); be(p + 2, aif_r(i), 2); }
		else { le(p, aif_l(i), 2); le(p + 2, aif_r(i), 2); }
	}
	return FRAMES * 4;
}

// every frame of the 16-bit music, each channel in place
static bool plays_aif_music(void) {
	s32_t *t = played();
	if (!t || frames_played() != FRAMES) return false;
	for (unsigned i = 0; i < FRAMES; i++) {
		if (t[2 * i] != (s32_t)(aif_l(i) << 16) || t[2 * i + 1] != (s32_t)(aif_r(i) << 16)) return false;
	}
	return true;
}

static const u8_t RATE_44100[10] = { 0x40, 0x0e, 0xac, 0x44, 0, 0, 0, 0, 0, 0 }; // 80-bit extended

// SqueezeDSP's PCM output
static unsigned squeezedsp_wav(u8_t *f, unsigned rate) {
	u8_t *p = f;
	unsigned data = FRAMES * 6;
	memcpy(p, "RIFF", 4); le(p + 4, 38 + data, 4); memcpy(p + 8, "WAVE", 4); p += 12;
	memcpy(p, "fmt ", 4); le(p + 4, 18, 4);
	le(p + 8, 1, 2); le(p + 10, 2, 2); le(p + 12, rate, 4); le(p + 16, rate * 6, 4); le(p + 20, 6, 2); le(p + 22, 24, 2);
	le(p + 24, 0, 2); p += 26;
	memcpy(p, "data", 4); le(p + 4, data, 4); p += 8;
	for (unsigned i = 0; i < FRAMES; i++, p += 6) {
		le(p, wav_l(i), 3);
		le(p + 3, wav_r(i), 3);
	}
	return p - f;
}

// FFmpeg's AIFF muxer for pcm_s16le: AIFC, FVER, COMM of 24 (the tag 'sowt', then an empty name),
// SSND with offset and block size 0
static unsigned ffmpeg_sowt(u8_t *f) {
	u8_t *p = f;
	unsigned data = FRAMES * 4;
	memcpy(p, "FORM", 4); be(p + 4, 4 + 12 + 32 + 16 + data, 4); memcpy(p + 8, "AIFC", 4); p += 12;
	memcpy(p, "FVER", 4); be(p + 4, 4, 4); be(p + 8, 0xA2805140, 4); p += 12;
	memcpy(p, "COMM", 4); be(p + 4, 24, 4); be(p + 8, 2, 2); be(p + 10, FRAMES, 4); be(p + 14, 16, 2);
	memcpy(p + 16, RATE_44100, 10); memcpy(p + 26, "sowt", 4); be(p + 30, 0, 2); p += 32;
	memcpy(p, "SSND", 4); be(p + 4, 8 + data, 4); be(p + 8, 0, 4); be(p + 12, 0, 4); p += 16;
	return p - f + samples16(p, false);
}

// afconvert -f AIFC -d BEI16's COMM chunk, as written: 'twos' and "Linear PCM, 16 bit big-endian
// signed integer"
static const u8_t afconvert_comm[76] = {
	0x43, 0x4f, 0x4d, 0x4d, 0x00, 0x00, 0x00, 0x44, 0x00, 0x02, 0x00, 0x00, 0x00, 0x40, 0x00, 0x10,
	0x40, 0x0e, 0xac, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x74, 0x77, 0x6f, 0x73, 0x2c, 0x4c,
	0x69, 0x6e, 0x65, 0x61, 0x72, 0x20, 0x50, 0x43, 0x4d, 0x2c, 0x20, 0x31, 0x36, 0x20, 0x62, 0x69,
	0x74, 0x20, 0x62, 0x69, 0x67, 0x2d, 0x65, 0x6e, 0x64, 0x69, 0x61, 0x6e, 0x20, 0x73, 0x69, 0x67,
	0x6e, 0x65, 0x64, 0x20, 0x69, 0x6e, 0x74, 0x65, 0x67, 0x65, 0x72, 0x00,
};

// macOS's AIFF (aifc false) or AIFC: COMM, an FLLR that pads to 4080, SSND, the samples at 4096
static unsigned afconvert(u8_t *f, bool aifc) {
	u8_t *p = f;
	unsigned data = FRAMES * 4, fill;
	memcpy(p, "FORM", 4); memcpy(p + 8, aifc ? "AIFC" : "AIFF", 4); p += 12;
	if (aifc) {
		memcpy(p, "FVER", 4); be(p + 4, 4, 4); be(p + 8, 0xA2805140, 4); p += 12;
		memcpy(p, afconvert_comm, sizeof(afconvert_comm)); p += sizeof(afconvert_comm);
	} else {
		memcpy(p, "COMM", 4); be(p + 4, 18, 4); be(p + 8, 2, 2); be(p + 10, FRAMES, 4); be(p + 14, 16, 2);
		memcpy(p + 16, RATE_44100, 10); p += 26;
	}
	fill = 4080 - (p - f) - 8; // afconvert's: 4034 in an AIFF, 3972 in an AIFC
	memcpy(p, "FLLR", 4); be(p + 4, fill, 4); memset(p + 8, 0, fill); p += 8 + fill;
	memcpy(p, "SSND", 4); be(p + 4, 8 + data, 4); be(p + 8, 0, 4); be(p + 12, 0, 4); p += 16;
	be(f + 4, p - f - 8 + data, 4);
	return p - f + samples16(p, true);
}

// ---- tests ----

static void test_lists_wav(void) {
	pcm_check_header = true;
	CHECK(!strcmp(register_pcm()->types, "wav,aif,pcm"), "the PCM codec lists %s", register_pcm()->types);
}

static void test_lists_no_wav_without_w(void) {
	CHECK(!strcmp(register_pcm()->types, "aif,pcm"), "without -W the PCM codec lists %s", register_pcm()->types);
}

static void test_wav_header_wins(void) {
	u8_t f[FIXTURE];
	unsigned n = squeezedsp_wav(f, 352800);
	s32_t *t;
	pcm_check_header = true;
	announce('1'); // LMS announces the source track: 16-bit 44.1k
	arrive(f, n);
	decode_calls(2);
	t = played();
	CHECK(output.next_sample_rate == 352800, "the track starts at %u, not the header's 352800", output.next_sample_rate);
	CHECK(output.next_fmt == PCM, "the track is PCM (format %d)", output.next_fmt);
	CHECK(frames_played() == FRAMES, "%u frames played of %u", frames_played(), FRAMES);
	CHECK(t && t[0] == (s32_t)(wav_l(0) << 8) && t[1] == (s32_t)(wav_r(0) << 8) &&
		  t[2 * (FRAMES - 1)] == (s32_t)(wav_l(FRAMES - 1) << 8) && t[2 * FRAMES - 1] == (s32_t)(wav_r(FRAMES - 1) << 8),
		  "the music's 24-bit frames, each channel in place, the header skipped");
}

static void test_wav_header_without_w(void) {
	u8_t f[FIXTURE];
	unsigned n = squeezedsp_wav(f, 352800);
	s32_t *t;
	announce('1');
	arrive(f, n);
	decode_calls(2);
	t = played();
	CHECK(output.next_sample_rate == 44100, "control: without -W the track starts at the announced 44100 (%u)", output.next_sample_rate);
	CHECK(t && t[0] == ('R' << 16 | 'I' << 24), "control: and the header plays as audio");
}

static void test_no_header_plays_as_announced(void) {
	u8_t f[FRAMES * 4];
	samples16(f, false);
	pcm_check_header = true;
	announce('1'); // LMS's own pcm: a WAV file's samples, its header stripped
	arrive(f, sizeof(f));
	decode_calls(2);
	CHECK(output.next_sample_rate == 44100, "the announced 44100 (%u)", output.next_sample_rate);
	CHECK(plays_aif_music(), "every frame as announced, little-endian");
	CHECK(strstr(log_text, "can't parse header") != NULL, "the log says no header was found");
}

static void test_ffmpeg_sowt(void) {
	u8_t f[FIXTURE];
	unsigned n = ffmpeg_sowt(f);
	pcm_check_header = true;
	announce('1'); // LMS reads 'sowt' as little-endian
	arrive(f, n);
	decode_calls(2);
	CHECK(logged_after("header: COMM", "pcm size: 2 rate: 44100 chan: 2 bigendian: 0"), "the header reads as little-endian 16-bit 44.1k");
	CHECK(plays_aif_music(), "every frame of the music, not byte-swapped noise");
}

// an AIFF with a NAME chunk of odd length (5 bytes, then its pad byte) before SSND, as tagging tools
// write one; and a WAV with an odd LIST chunk before data. /code-review 2026-11-22 finding 2: upstream
// read the pad as the next chunk's first byte, missed SSND/data, and played the header as audio
static unsigned aiff_odd_name(u8_t *f) {
	u8_t *p = f;
	unsigned data = FRAMES * 4;
	memcpy(p, "FORM", 4); be(p + 4, 4 + 26 + 14 + 16 + data, 4); memcpy(p + 8, "AIFF", 4); p += 12;
	memcpy(p, "COMM", 4); be(p + 4, 18, 4); be(p + 8, 2, 2); be(p + 10, FRAMES, 4); be(p + 14, 16, 2);
	memcpy(p + 16, RATE_44100, 10); p += 26;
	memcpy(p, "NAME", 4); be(p + 4, 5, 4); memcpy(p + 8, "Hello", 5); p[13] = 0; p += 14;
	memcpy(p, "SSND", 4); be(p + 4, 8 + data, 4); be(p + 8, 0, 4); be(p + 12, 0, 4); p += 16;
	return p - f + samples16(p, true);
}

static void test_aiff_odd_chunk(void) {
	u8_t f[FIXTURE];
	unsigned n = aiff_odd_name(f);
	pcm_check_header = true;
	announce('0');
	arrive(f, n);
	decode_calls(2);
	CHECK(logged_after("header: NAME", "header: SSND"), "SSND found after the odd NAME chunk and its pad");
	CHECK(plays_aif_music(), "every frame of the music, no header played as audio (%u frames)", frames_played());
}

static void test_wav_odd_chunk(void) {
	u8_t f[FIXTURE], g[FIXTURE];
	unsigned n = squeezedsp_wav(f, 44100), head = 12 + 26;   // RIFF + fmt, then data
	s32_t *t;
	// the same file with a LIST chunk of 13 bytes and its pad byte between fmt and data
	memcpy(g, f, head);
	memcpy(g + head, "LIST", 4); le(g + head + 4, 13, 4); memcpy(g + head + 8, "INFOISFT\x01\0\0\0x", 13); g[head + 21] = 0;
	memcpy(g + head + 22, f + head, n - head);
	le(g + 4, 38 + 22 + FRAMES * 6, 4);
	pcm_check_header = true;
	announce('1');
	arrive(g, n + 22);
	decode_calls(2);
	t = played();
	CHECK(logged_after("header: LIST", "header: data"), "data found after the odd LIST chunk and its pad");
	CHECK(frames_played() == FRAMES && t && t[0] == (s32_t)(wav_l(0) << 8) && t[1] == (s32_t)(wav_r(0) << 8),
		  "the music's frames, no header played as audio (%u frames)", frames_played());
}

// a garbage chunk length so large that the step past the chunk (len + 8, plus its pad byte when len is
// odd) wraps round to 0 in 32 bits: 0xFFFFFFF8, and 0xFFFFFFF7 with its pad. /code-review 2026-11-22 (3)
// finding 5: counted in 32 bits the walk reads the same chunk for ever, the decode thread holding the
// stream lock (here the test's alarm ends it: "timed out"); counted in 64 bits it runs out of data
static void test_wav_wrapping_chunk(void) {
	u8_t f[FIXTURE], g[FIXTURE];
	unsigned n = squeezedsp_wav(f, 44100), head = 12 + 26;   // RIFF + fmt, then data
	memcpy(g, f, head);
	memcpy(g + head, "JUNK", 4); le(g + head + 4, 0xFFFFFFF8, 4);
	memcpy(g + head + 8, f + head, n - head);
	pcm_check_header = true;
	announce('1');
	arrive(g, n + 8);
	decode_calls(2);
	CHECK(logged_after("header: JUNK", "run out of data"), "the walk stops at the chunk it cannot step past");
}

static void test_aiff_wrapping_chunk(void) {
	u8_t f[FIXTURE];
	unsigned n = afconvert(f, false), fllr = 12 + 26;          // FORM + COMM, then FLLR
	be(f + fllr + 4, 0xFFFFFFF7, 4);
	pcm_check_header = true;
	announce('0');
	arrive(f, n);
	decode_calls(2);
	CHECK(logged_after("header: FLLR", "run out of data"), "the walk stops at the chunk it cannot step past");
}

// the bounds on the AIFC encoding check (`len >= 22 && bytes >= 30`): it reads COMM's bytes 26-29
// only when COMM holds them and they have arrived
static void test_aifc_comm_without_its_encoding(void) {
	u8_t f[FIXTURE];
	u8_t *p = f;
	unsigned data = FRAMES * 4;
	// a COMM of 18 (no encoding), so its bytes 26-29 are the next chunk's id, here "sowt" (empty)
	memcpy(p, "FORM", 4); be(p + 4, 4 + 26 + 8 + 16 + data, 4); memcpy(p + 8, "AIFC", 4); p += 12;
	memcpy(p, "COMM", 4); be(p + 4, 18, 4); be(p + 8, 2, 2); be(p + 10, FRAMES, 4); be(p + 14, 16, 2);
	memcpy(p + 16, RATE_44100, 10); p += 26;
	memcpy(p, "sowt", 4); be(p + 4, 0, 4); p += 8;
	memcpy(p, "SSND", 4); be(p + 4, 8 + data, 4); be(p + 8, 0, 4); be(p + 12, 0, 4); p += 16;
	unsigned n = p - f + samples16(p, true);
	pcm_check_header = true;
	announce('0');
	arrive(f, n);
	decode_calls(2);
	CHECK(logged_after("header: COMM", "pcm size: 2 rate: 44100 chan: 2 bigendian: 1"), "a COMM of 18 is read big-endian, not from the next chunk's id");
	CHECK(plays_aif_music(), "every frame of the music, not byte-swapped noise");
}

static void test_aifc_comm_cut_before_its_encoding(void) {
	u8_t f[FIXTURE];
	unsigned n = ffmpeg_sowt(f), comm = 12 + 12;              // FORM + FVER, then COMM
	pcm_check_header = true;
	announce('1');
	// the whole file is in the buffer's memory, but only up to COMM's byte 29 has arrived: "sowt" sits
	// in bytes 26-29, so its last byte has not
	memcpy(streambuf->writep, f, n);
	_buf_inc_writep(streambuf, comm + 29);
	decode_calls(1);
	CHECK(logged_after("header: COMM", "pcm size: 2 rate: 44100 chan: 2 bigendian: 1"), "the encoding is not read past the bytes that have arrived");
	CHECK(logged_after("header: COMM", "run out of data"), "and the header waits for the rest");
}

static void test_afconvert_aifc_twos(void) {
	u8_t f[FIXTURE];
	unsigned n = afconvert(f, true);
	pcm_check_header = true;
	announce('0');
	arrive(f, n);
	decode_calls(2);
	CHECK(logged_after("header: COMM", "pcm size: 2 rate: 44100 chan: 2 bigendian: 1"), "control: 'twos' reads as big-endian");
	CHECK(plays_aif_music(), "control: every frame of the music");
}

static void test_afconvert_aiff_at_the_first_read(void) {
	u8_t f[FIXTURE];
	unsigned n = afconvert(f, false);
	pcm_check_header = true;
	announce('0');
	// the decode thread's first call comes once more than the codec's min read (4096) has arrived
	// (decode.c), and the stream buffer starts every stream at its start (stream_sock's buf_flush)
	arrive(f, pcm->min_read_bytes + 1);
	decode_calls(1);
	arrive(f + pcm->min_read_bytes + 1, n - pcm->min_read_bytes - 1);
	decode_calls(2);
	CHECK(strstr(log_text, "run out of data") == NULL, "the header, padded to byte 4096, is read in the first call");
	CHECK(plays_aif_music(), "every frame of the music, big-endian, from byte 4096");
}

// ---- runner ----

struct test { const char *name; void (*run)(void); };

static const struct test tests[] = {
	{ "with -W the PCM codec lists wav", test_lists_wav },
	{ "without -W it lists no wav", test_lists_no_wav_without_w },
	{ "a WAV header's depth and rate win over LMS's announce", test_wav_header_wins },
	{ "without -W a WAV header plays as audio, at the announce", test_wav_header_without_w },
	{ "a stream with no header plays as announced", test_no_header_plays_as_announced },
	{ "FFmpeg's little-endian AIFF ('sowt') plays little-endian", test_ffmpeg_sowt },
	{ "macOS's AIFC ('twos') plays big-endian", test_afconvert_aifc_twos },
	{ "macOS's AIFF, padded to 4096, is read at the decoder's first call", test_afconvert_aiff_at_the_first_read },
	{ "an AIFF with an odd-sized chunk before SSND skips its pad byte", test_aiff_odd_chunk },
	{ "a WAV with an odd-sized chunk before data skips its pad byte", test_wav_odd_chunk },
	{ "a WAV chunk whose length wraps 32 bits (0xFFFFFFF8) ends the walk", test_wav_wrapping_chunk },
	{ "an AIFF chunk whose length and pad wrap 32 bits (0xFFFFFFF7) ends the walk", test_aiff_wrapping_chunk },
	{ "an AIFC COMM without its encoding is not read past its end", test_aifc_comm_without_its_encoding },
	{ "an AIFC COMM cut before its encoding is not read past the bytes arrived", test_aifc_comm_cut_before_its_encoding },
};

int main(int argc, char **argv) {
	int n = sizeof(tests) / sizeof(tests[0]), passed = 0, run = 0;
	for (int i = 0; i < n; i++) {
		if (argc > 1 && !strstr(tests[i].name, argv[1])) continue;
		run++;
		fflush(stdout);
		pid_t pid = fork();
		int fork_errno = errno;
		if (pid == 0) {
			alarm(10);
			setup();
			tests[i].run();
			fflush(stdout);
			_exit(failures ? 1 : 0);
		}
		// a test whose fork failed never ran: it fails
		int status = 0;
		bool waited = pid > 0 && waitpid(pid, &status, 0) == pid;
		bool ok = waited && WIFEXITED(status) && WEXITSTATUS(status) == 0;
		if (ok) passed++;
		char reason[160] = "";
		if (pid < 0) snprintf(reason, sizeof(reason), " (not run: fork: %s)", strerror(fork_errno));
		else if (!waited) snprintf(reason, sizeof(reason), " (its process was not waited for)");
		else if (WIFSIGNALED(status)) snprintf(reason, sizeof(reason), " (crashed or timed out)");
		printf("%s %s%s\n", ok ? "✔" : "✘", tests[i].name, reason);
	}
	printf("%d tests, %d passed\n", run, passed);
	printf("result: %s\n", passed == run && run > 0 ? "PASS" : "FAIL");
	return passed == run && run > 0 ? 0 : 1;
}
