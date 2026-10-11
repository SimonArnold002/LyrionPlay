/*
 * Regression suite for output_coreaudio.c, run against a fake HAL: no audio device is touched.
 *
 * The file is compiled with its HAL calls, clock, sleeps and stdout redirected to the fakes below
 * (OCA_SOURCE names it, so the suite can be built against an older copy to prove a test fails
 * there). It is linked with upstream's output.c, buffer.c, output_pack.c and dop.c, unchanged, so
 * the IOProc drives the real _output_frames, output_flush, gain and DoP markers. Until 2026-10-11
 * the suite carried hand-made copies of _output_frames and output_flush instead, and twice a rule
 * missing from a copy hid a bug (/code-review 2026-10-11 (2) finding 4, (3) finding 5).
 *
 * The fake HAL behaves as the real HAL was measured to behave:
 *   - removing a property listener waits for a call of it that is in flight (macOS 26.7.1,
 *     2026-10-10: 1001 ms for a listener that slept 1 s);
 *   - notifications arrive on the HAL's own thread, also for this process's own changes;
 *   - setting kAudioDevicePropertyHogMode toggles it (AudioHardware.h: the value is ignored).
 *
 * Two kinds of test:
 *   - named tests, one per behaviour or past finding;
 *   - the scenario matrix ("matrix"): every combination of the last track, the gap, the next track,
 *     when the decoder finds it, an interruption, a rate delay and a gapless follower, played
 *     through LMS's strm commands as slimproto.c runs them, with every frame the device got checked
 *     against the invariants in check_invariants (no DoP pattern at a PCM rate, the format of the
 *     silence around each track, to the idle release's close, music only at its own rate and in
 *     order, no stretched delay, one rate switch when the decoder was in time). The monitor thread
 *     is gated there, so a stop or a new album can land at an exact point: before it notices the
 *     play, during its wait for the decoder, or inside the open.
 *
 * Each test, and each scenario, runs in its own child process, so no state leaks between them and
 * a hang is caught by a timeout instead of stopping the suite. Prints one line per test and a
 * summary line; exits 0 only if every test passed. `./test_output_coreaudio <words>` runs the
 * tests whose name contains them; `MATRIX_ONE=<n> VERBOSE=1 ./test_output_coreaudio matrix` replays
 * one scenario with the engine's log and the device's frames; `MATRIX_SIG=<dir>` writes every
 * scenario's frames, to diff two builds (write_sig).
 *
 * Anti-run, to see a new test fail on the code before a fix (from engine/, into another file so
 * the suite's own binary is left alone):
 *   cc -arch arm64 -O1 -std=gnu99 -D_FORTIFY_SOURCE=0 -DCOREAUDIO -DDSD -DRESAMPLE -DLINKALL \
 *      -DALAC -DOPUS -DNO_MAD -I. -I../deps/out/include -DOCA_SOURCE='"/path/to/old/output_coreaudio.c"' \
 *      -o /tmp/oca-old tests/test_output_coreaudio.c output.c buffer.c output_pack.c dop.c \
 *      -framework CoreAudio -framework CoreFoundation
 */
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static Boolean fake_HasProperty(AudioObjectID, const AudioObjectPropertyAddress *);
static OSStatus fake_GetPropertyData(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *, void *);
static OSStatus fake_GetPropertyDataSize(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
static OSStatus fake_SetPropertyData(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, const void *);
static OSStatus fake_IsPropertySettable(AudioObjectID, const AudioObjectPropertyAddress *, Boolean *);
static OSStatus fake_AddPropertyListener(AudioObjectID, const AudioObjectPropertyAddress *, AudioObjectPropertyListenerProc, void *);
static OSStatus fake_RemovePropertyListener(AudioObjectID, const AudioObjectPropertyAddress *, AudioObjectPropertyListenerProc, void *);
static OSStatus fake_CreateIOProcID(AudioObjectID, AudioDeviceIOProc, void *, AudioDeviceIOProcID *);
static OSStatus fake_DestroyIOProcID(AudioObjectID, AudioDeviceIOProcID);
static OSStatus fake_DeviceStart(AudioObjectID, AudioDeviceIOProcID);
static OSStatus fake_DeviceStop(AudioObjectID, AudioDeviceIOProcID);
static uint64_t fake_clock_ns(clockid_t);
static unsigned fake_sleep(unsigned);
static int fake_usleep(useconds_t);
static int fake_printf(const char *, ...);
static int fake_pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);

#define AudioObjectHasProperty            fake_HasProperty
#define AudioObjectGetPropertyData        fake_GetPropertyData
#define AudioObjectGetPropertyDataSize    fake_GetPropertyDataSize
#define AudioObjectSetPropertyData        fake_SetPropertyData
#define AudioObjectIsPropertySettable     fake_IsPropertySettable
#define AudioObjectAddPropertyListener    fake_AddPropertyListener
#define AudioObjectRemovePropertyListener fake_RemovePropertyListener
#define AudioDeviceCreateIOProcID         fake_CreateIOProcID
#define AudioDeviceDestroyIOProcID        fake_DestroyIOProcID
#define AudioDeviceStart                  fake_DeviceStart
#define AudioDeviceStop                   fake_DeviceStop
#define clock_gettime_nsec_np             fake_clock_ns
#define sleep                             fake_sleep
#define usleep                            fake_usleep
#define printf                            fake_printf
#define pthread_create                    fake_pthread_create

#ifndef OCA_SOURCE
#define OCA_SOURCE "../output_coreaudio.c"
#endif
#include OCA_SOURCE

#undef sleep
#undef usleep
#undef printf
#undef pthread_create
#undef clock_gettime_nsec_np

// ---------------------------------------------------------------------------------------------
// The rest of squeezelite
//
// output.c, buffer.c, output_pack.c and dop.c are linked as they are. What is left here are leaf
// functions of files too big to link (dsd.c, utils.c, slimproto.c), each as small as the original.

extern bool user_rates; // output.c; main.c sets it for -r

void dsd_invert(u32_t *ptr, frames_t frames) { // dsd.c
	while (frames--) {
		*ptr = ~(*ptr);
		++ptr;
		*ptr = ~(*ptr);
		++ptr;
	}
}
void dsd_silence_frames(u32_t *ptr, frames_t frames) { // dsd.c: 10101100 (0x69), DSD's silence
	while (frames--) {
		*ptr++ = 0x69696969;
		*ptr++ = 0x69696969;
	}
}
void wake_controller(void) {}
u32_t gettime_ms(void) { return (u32_t)(fake_clock_ns(CLOCK_UPTIME_RAW) / 1000000); }
const char *logtime(void) { return ""; }

char *next_param(char *src, char c) { // utils.c
	static char *str = NULL;
	char *ptr, *ret;
	if (src) str = src;
	if (str && (ptr = strchr(str, c))) {
		ret = str;
		*ptr = '\0';
		str = ptr + 1;
	} else {
		ret = str;
		str = NULL;
	}
	return ret && ret[0] ? ret : NULL;
}

// the engine's log, kept so a test can count lines
static pthread_mutex_t loglock = PTHREAD_MUTEX_INITIALIZER;
static char logbuf[1 << 16];
static size_t loglen;
void logprint(const char *fmt, ...) {
	char line[1024];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	pthread_mutex_lock(&loglock);
	if (loglen + strlen(line) < sizeof(logbuf)) {
		memcpy(logbuf + loglen, line, strlen(line) + 1);
		loglen += strlen(line);
	}
	pthread_mutex_unlock(&loglock);
	if (getenv("VERBOSE")) fprintf(stderr, "    | %s", line);
}

static unsigned log_count(const char *needle) {
	unsigned n = 0;
	const char *p = logbuf;
	pthread_mutex_lock(&loglock);
	while ((p = strstr(p, needle))) { n++; p += strlen(needle); }
	pthread_mutex_unlock(&loglock);
	return n;
}

// ---------------------------------------------------------------------------------------------
// The fake HAL

#define MAXDEV 4
#define STREAM(id) ((id) + 100)

typedef struct {
	AudioObjectID id;
	bool present;
	const char *uid, *name;
	unsigned channels;
	Float64 rate;
	Float64 rates[8];
	unsigned nrates;
	bool refuse_rate;           // the device refuses a rate change
	unsigned rate_changes;      // times its rate was changed
	pid_t hog;                  // -1, or the process holding it
	unsigned hog_taken;         // times this process took it
	bool volume;                // a settable main-element volume
	Float32 db, db_min, db_max;
	Float32 step;               // levels move in steps of this many dB (0: exact)
	bool mute_ctl;
	UInt32 mute;
	bool virt_float32;          // the stream's virtual format is 32-bit float
	AudioStreamBasicDescription phys;
	int procs, started;
} fdev;

static fdev devs[MAXDEV];
static int ndev;
static AudioObjectID default_out;
static pthread_mutex_t hal = PTHREAD_MUTEX_INITIALIZER;

static fdev *dev_by_id(AudioObjectID id) {
	for (int i = 0; i < ndev; i++) if (devs[i].id == id || STREAM(devs[i].id) == id) return &devs[i];
	return NULL;
}

static fdev *dev_by_uid(const char *uid) {
	for (int i = ndev - 1; i >= 0; i--) if (!strcmp(devs[i].uid, uid)) return &devs[i];
	return NULL;
}

static fdev *add_dev(const char *uid, const char *name) {
	fdev *d = &devs[ndev];
	memset(d, 0, sizeof(*d));
	d->id = 40 + ndev++;
	d->present = true;
	d->uid = uid;
	d->name = name;
	d->channels = 2;
	d->rate = 44100;
	d->rates[0] = 44100; d->rates[1] = 48000; d->rates[2] = 88200; d->rates[3] = 96000;
	d->rates[4] = 176400;                     // DSD64 as DoP
	d->nrates = 5;
	d->hog = -1;
	d->virt_float32 = true;
	d->db_min = -63.5f;
	d->db_max = 0;
	return d;
}

static fdev *add_speakers(void) {
	fdev *d = add_dev("BuiltInSpeakerDevice", "MacBook Pro Speakers");
	d->volume = true;
	d->db = -20;
	d->mute_ctl = true;
	if (!default_out) default_out = d->id;
	return d;
}

static fdev *add_dac(void) {
	fdev *d = add_dev("AppleUSBAudioEngine:Test:DAC:1", "Test DAC");
	if (!default_out) default_out = d->id;
	return d;
}

static Float32 quantise(const fdev *d, Float32 db) {
	if (db < d->db_min) db = d->db_min;
	if (db > d->db_max) db = d->db_max;
	return d->step ? d->db_min + roundf((db - d->db_min) / d->step) * d->step : db;
}

// --- listeners, called on a HAL thread as the real HAL does

typedef struct {
	bool used;
	AudioObjectID obj;
	AudioObjectPropertySelector sel;
	AudioObjectPropertyListenerProc proc;
	void *ctx;
	int inflight;
} flistener;

static flistener listeners[32];
static pthread_cond_t calls_done = PTHREAD_COND_INITIALIZER;
static bool inflight_on_remove;    // the next Remove finds a call of that listener already running
static unsigned removes_armed, remove_timeouts;

struct batch { int pending; };
struct call { int slot; AudioObjectID obj; AudioObjectPropertySelector sel; struct batch *batch; };

static void *call_listener(void *arg) {
	struct call c = *(struct call *)arg;
	AudioObjectPropertyAddress a = { c.sel, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
	free(arg);
	listeners[c.slot].proc(c.obj, 1, &a, listeners[c.slot].ctx);
	pthread_mutex_lock(&hal);
	listeners[c.slot].inflight--;
	if (c.batch) c.batch->pending--;
	pthread_cond_broadcast(&calls_done);
	pthread_mutex_unlock(&hal);
	return NULL;
}

// starts one call of a listener on its own thread, as the HAL's notification thread; hal held
static void start_call(int slot, AudioObjectID obj, AudioObjectPropertySelector sel, struct batch *b) {
	pthread_t t;
	struct call *c = malloc(sizeof(*c));
	*c = (struct call){ slot, obj, sel, b };
	listeners[slot].inflight++;
	if (b) b->pending++;
	pthread_create(&t, NULL, call_listener, c);
	pthread_detach(t);
}

// with hal held, waits until cond is false; false if it gave up after 2 s
#define WAIT_HAL(cond) ({ struct timespec _u; bool _ok = true; clock_gettime(CLOCK_REALTIME, &_u); _u.tv_sec += 2; \
	while (cond) if (pthread_cond_timedwait(&calls_done, &hal, &_u)) { _ok = false; break; } _ok; })

// a property changed: call its listeners and wait for them (bounded, so a stuck one is counted)
static unsigned notify_timeouts;
static void notify(AudioObjectID obj, AudioObjectPropertySelector sel) {
	struct batch *b = calloc(1, sizeof(*b)); // left allocated if a call never returns
	pthread_mutex_lock(&hal);
	for (int i = 0; i < 32; i++) {
		if (listeners[i].used && listeners[i].obj == obj && listeners[i].sel == sel) start_call(i, obj, sel, b);
	}
	if (WAIT_HAL(b->pending > 0)) free(b);
	else notify_timeouts++;
	pthread_mutex_unlock(&hal);
}

static OSStatus fake_AddPropertyListener(AudioObjectID obj, const AudioObjectPropertyAddress *a,
										 AudioObjectPropertyListenerProc proc, void *ctx) {
	pthread_mutex_lock(&hal);
	for (int i = 0; i < 32; i++) {
		if (!listeners[i].used) {
			listeners[i] = (flistener){ true, obj, a->mSelector, proc, ctx, 0 };
			break;
		}
	}
	pthread_mutex_unlock(&hal);
	return noErr;
}

static OSStatus fake_RemovePropertyListener(AudioObjectID obj, const AudioObjectPropertyAddress *a,
											AudioObjectPropertyListenerProc proc, void *ctx) {
	pthread_mutex_lock(&hal);
	for (int i = 0; i < 32; i++) {
		if (!listeners[i].used || listeners[i].obj != obj || listeners[i].sel != a->mSelector || listeners[i].proc != proc) continue;
		if (inflight_on_remove) {
			// the user pressed a volume key just before: that notification is being delivered now
			inflight_on_remove = false;
			removes_armed++;
			start_call(i, obj, a->mSelector, NULL);
		}
		// as measured: Remove returns only once no call of this listener is running. A call that
		// waits for something the remover holds never returns: a deadlock, counted after 2 s.
		if (!WAIT_HAL(listeners[i].inflight > 0)) remove_timeouts++;
		listeners[i].used = false;
	}
	pthread_mutex_unlock(&hal);
	return noErr;
}

// --- properties

static bool is_sys(AudioObjectID o) { return o == kAudioObjectSystemObject; }

static Boolean fake_HasProperty(AudioObjectID obj, const AudioObjectPropertyAddress *a) {
	fdev *d;
	if (is_sys(obj)) return true;
	if (!(d = dev_by_id(obj)) || !d->present) return false;
	switch (a->mSelector) {
	case kAudioDevicePropertyVolumeScalar:
	case kAudioDevicePropertyVolumeDecibels:
	case kAudioDevicePropertyVolumeRangeDecibels:
	case kAudioDevicePropertyVolumeScalarToDecibels:
	case kAudioDevicePropertyVolumeDecibelsToScalar:
		return d->volume && a->mElement == kAudioObjectPropertyElementMain;
	case kAudioDevicePropertyMute:
		return d->mute_ctl;
	default:
		return true;
	}
}

static OSStatus fake_IsPropertySettable(AudioObjectID obj, const AudioObjectPropertyAddress *a, Boolean *s) {
	*s = false;
	if (!fake_HasProperty(obj, a)) return kAudioHardwareUnknownPropertyError;
	switch (a->mSelector) {
	case kAudioDevicePropertyVolumeScalar:
	case kAudioDevicePropertyVolumeDecibels:
	case kAudioDevicePropertyMute:
	case kAudioDevicePropertyNominalSampleRate:
	case kAudioDevicePropertyHogMode:
	case kAudioStreamPropertyPhysicalFormat:
		*s = true;
	}
	return noErr;
}

static OSStatus fake_GetPropertyDataSize(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 q,
										 const void *qd, UInt32 *size) {
	fdev *d = dev_by_id(obj);
	int n = 0;
	switch (a->mSelector) {
	case kAudioHardwarePropertyDevices:
		for (int i = 0; i < ndev; i++) n += devs[i].present;
		*size = n * sizeof(AudioObjectID);
		return noErr;
	case kAudioDevicePropertyStreamConfiguration:
		if (!d || !d->present) return kAudioHardwareBadObjectError;
		*size = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
		return noErr;
	case kAudioDevicePropertyAvailableNominalSampleRates:
		*size = d && d->present ? d->nrates * sizeof(AudioValueRange) : 0;
		return noErr;
	case kAudioDevicePropertyStreams:
		*size = d && d->present ? sizeof(AudioStreamID) : 0;
		return noErr;
	case kAudioStreamPropertyAvailablePhysicalFormats:
		*size = d && d->present ? sizeof(AudioStreamRangedDescription) : 0;
		return noErr;
	}
	return kAudioHardwareUnknownPropertyError;
}

static AudioStreamBasicDescription int32_format(Float64 rate) {
	AudioStreamBasicDescription f = { 0 };
	f.mSampleRate = rate;
	f.mFormatID = kAudioFormatLinearPCM;
	f.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
	f.mBitsPerChannel = 32;
	f.mChannelsPerFrame = 2;
	f.mBytesPerFrame = f.mBytesPerPacket = 8;
	f.mFramesPerPacket = 1;
	return f;
}

#define PUT(type, value) do { if (*size < sizeof(type)) return kAudioHardwareBadPropertySizeError; *(type *)data = (value); *size = sizeof(type); } while (0)

static OSStatus fake_GetPropertyData(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 q, const void *qd,
									 UInt32 *size, void *data) {
	fdev *d = dev_by_id(obj);
	OSStatus st = noErr;
	pthread_mutex_lock(&hal);
	if (is_sys(obj)) {
		if (a->mSelector == kAudioHardwarePropertyDefaultOutputDevice) {
			if (*size >= sizeof(AudioObjectID)) *(AudioObjectID *)data = default_out;
		} else if (a->mSelector == kAudioHardwarePropertyDevices) {
			UInt32 n = 0;
			for (int i = 0; i < ndev && (n + 1) * sizeof(AudioObjectID) <= *size; i++) {
				if (devs[i].present) ((AudioObjectID *)data)[n++] = devs[i].id;
			}
			*size = n * sizeof(AudioObjectID);
		} else {
			st = kAudioHardwareUnknownPropertyError;
		}
		pthread_mutex_unlock(&hal);
		return st;
	}
	if (!d || !d->present) {
		pthread_mutex_unlock(&hal);
		return kAudioHardwareBadObjectError;
	}
	switch (a->mSelector) {
	case kAudioDevicePropertyStreamConfiguration: {
		AudioBufferList *l = data;
		l->mNumberBuffers = 1;
		l->mBuffers[0].mNumberChannels = d->channels;
		break;
	}
	case kAudioDevicePropertyDeviceUID:
	case kAudioObjectPropertyName:
	case kAudioObjectPropertyManufacturer:
		*(CFStringRef *)data = CFStringCreateWithCString(NULL, a->mSelector == kAudioDevicePropertyDeviceUID ? d->uid : d->name,
														 kCFStringEncodingUTF8);
		break;
	case kAudioDevicePropertyAvailableNominalSampleRates:
		for (unsigned i = 0; i < d->nrates; i++) ((AudioValueRange *)data)[i] = (AudioValueRange){ d->rates[i], d->rates[i] };
		*size = d->nrates * sizeof(AudioValueRange);
		break;
	case kAudioDevicePropertyNominalSampleRate: *(Float64 *)data = d->rate; break;
	case kAudioDevicePropertyHogMode: *(pid_t *)data = d->hog; break;
	case kAudioDevicePropertyVolumeDecibels: *(Float32 *)data = d->db; break;
	case kAudioDevicePropertyVolumeScalar: *(Float32 *)data = (d->db - d->db_min) / (d->db_max - d->db_min); break;
	case kAudioDevicePropertyVolumeRangeDecibels: *(AudioValueRange *)data = (AudioValueRange){ d->db_min, d->db_max }; break;
	case kAudioDevicePropertyVolumeScalarToDecibels: {
		Float32 *v = data;
		*v = d->db_min + *v * (d->db_max - d->db_min);
		break;
	}
	case kAudioDevicePropertyVolumeDecibelsToScalar: {
		Float32 *v = data;
		*v = (*v - d->db_min) / (d->db_max - d->db_min);
		break;
	}
	case kAudioDevicePropertyMute: *(UInt32 *)data = d->mute; break;
	case kAudioDevicePropertyStreams: *(AudioStreamID *)data = STREAM(d->id); break;
	case kAudioDevicePropertyLatency: *(UInt32 *)data = 0; break; // also kAudioStreamPropertyLatency, the same selector
	case kAudioDevicePropertyTransportType: *(UInt32 *)data = kAudioDeviceTransportTypeUSB; break;
	case kAudioStreamPropertyVirtualFormat: {
		AudioStreamBasicDescription f = int32_format(d->rate);
		if (d->virt_float32) f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
		else f.mBitsPerChannel = 16;
		*(AudioStreamBasicDescription *)data = f;
		break;
	}
	case kAudioStreamPropertyPhysicalFormat: *(AudioStreamBasicDescription *)data = d->phys; break;
	case kAudioStreamPropertyAvailablePhysicalFormats: {
		AudioStreamRangedDescription *r = data;
		r->mFormat = int32_format(0);
		r->mSampleRateRange = (AudioValueRange){ d->rates[0], d->rates[d->nrates - 1] };
		break;
	}
	default:
		st = kAudioHardwareUnknownPropertyError;
	}
	pthread_mutex_unlock(&hal);
	return st;
}

// called once, from inside the next level change on a device, before it lands: lets a test have
// something else happen in the middle of one (another thread's audg, say)
static void (*during_next_level_change)(void);
// the same, inside the next rate change (a USB DAC relocking, while the open is unlocked)
static void (*during_next_rate_change)(void);

static OSStatus fake_SetPropertyData(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 q, const void *qd,
									 UInt32 size, const void *data) {
	fdev *d = dev_by_id(obj);
	AudioObjectPropertySelector changed = 0;
	OSStatus st = noErr;
	if (is_sys(obj)) return noErr; // the run loop
	if (a->mSelector == kAudioDevicePropertyVolumeDecibels && during_next_level_change) {
		void (*hook)(void) = during_next_level_change;
		during_next_level_change = NULL;
		hook();
	}
	if (a->mSelector == kAudioDevicePropertyNominalSampleRate && during_next_rate_change) {
		void (*hook)(void) = during_next_rate_change;
		during_next_rate_change = NULL;
		hook();
	}
	pthread_mutex_lock(&hal);
	if (!d || !d->present) {
		pthread_mutex_unlock(&hal);
		return kAudioHardwareBadObjectError;
	}
	switch (a->mSelector) {
	case kAudioDevicePropertyNominalSampleRate:
		if (d->refuse_rate) st = kAudioHardwareIllegalOperationError;
		else if (d->rate != *(const Float64 *)data) { d->rate = *(const Float64 *)data; d->rate_changes++; }
		break;
	case kAudioDevicePropertyHogMode:
		// the value passed is ignored: free -> this process, this process -> free, another -> unchanged
		if (d->hog == -1) { d->hog = getpid(); d->hog_taken++; }
		else if (d->hog == getpid()) d->hog = -1;
		break;
	case kAudioDevicePropertyVolumeDecibels:
		d->db = quantise(d, *(const Float32 *)data);
		changed = kAudioDevicePropertyVolumeScalar;
		break;
	case kAudioDevicePropertyVolumeScalar:
		d->db = quantise(d, d->db_min + *(const Float32 *)data * (d->db_max - d->db_min));
		changed = kAudioDevicePropertyVolumeScalar;
		break;
	case kAudioDevicePropertyMute:
		d->mute = *(const UInt32 *)data;
		changed = kAudioDevicePropertyMute;
		break;
	case kAudioStreamPropertyPhysicalFormat:
		d->phys = *(const AudioStreamBasicDescription *)data;
		break;
	case kAudioDevicePropertyBufferFrameSize:
		break;
	default:
		st = kAudioHardwareUnknownPropertyError;
	}
	pthread_mutex_unlock(&hal);
	if (changed) notify(d->id, changed);
	return st;
}

// called once, from inside the next IOProc creation: the last device call of an open before it
// takes the lock again and records what it opened (a stop that lands here finds the output still
// not open, output.error_opening set)
static void (*during_next_ioproc_create)(void);
static OSStatus fake_CreateIOProcID(AudioObjectID obj, AudioDeviceIOProc proc, void *ctx, AudioDeviceIOProcID *id) {
	fdev *d = dev_by_id(obj);
	if (!d || !d->present) return kAudioHardwareBadObjectError;
	if (during_next_ioproc_create) {
		void (*hook)(void) = during_next_ioproc_create;
		during_next_ioproc_create = NULL;
		hook();
	}
	d->procs++;
	*id = (AudioDeviceIOProcID)proc;
	return noErr;
}
static OSStatus fake_DestroyIOProcID(AudioObjectID obj, AudioDeviceIOProcID id) {
	fdev *d = dev_by_id(obj);
	if (d) d->procs--;
	return noErr;
}
// called once, from inside the next AudioDeviceStart, before the device runs (a USB DAC takes
// ~0.7 s here after a rate change, measured 2026-10-11)
static void (*during_next_start)(void);
static _Atomic unsigned device_starts;    // every start: a new run of the device at one rate
static OSStatus fake_DeviceStart(AudioObjectID obj, AudioDeviceIOProcID id) {
	fdev *d = dev_by_id(obj);
	if (!d || !d->present) return kAudioHardwareBadObjectError;
	if (during_next_start) {
		void (*hook)(void) = during_next_start;
		during_next_start = NULL;
		hook();
	}
	d->started++;
	atomic_fetch_add(&device_starts, 1);
	return noErr;
}
static OSStatus fake_DeviceStop(AudioObjectID obj, AudioDeviceIOProcID id) {
	fdev *d = dev_by_id(obj);
	if (d && d->started) d->started--;
	return noErr;
}

// --- the user, pressing volume keys

static void user_set_db(fdev *d, Float32 db) {
	pthread_mutex_lock(&hal);
	d->db = quantise(d, db);
	pthread_mutex_unlock(&hal);
	notify(d->id, kAudioDevicePropertyVolumeScalar);
}

static void user_set_mute(fdev *d, UInt32 m) {
	pthread_mutex_lock(&hal);
	d->mute = m;
	pthread_mutex_unlock(&hal);
	notify(d->id, kAudioDevicePropertyMute);
}

// --- clock, sleeps, stdout, threads

static _Atomic uint64_t clock_offset;
static uint64_t fake_clock_ns(clockid_t c) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + atomic_load(&clock_offset); }
static void advance_ms(unsigned ms) { atomic_fetch_add(&clock_offset, (uint64_t)ms * 1000000); }

// the engine's sleeps are recorded, and taken 500 times faster
static pthread_mutex_t sleeplock = PTHREAD_MUTEX_INITIALIZER;
static unsigned sleeps[256], nsleeps;
static unsigned sleep_us_per_s = 2000;
static unsigned fake_sleep(unsigned s) {
	pthread_mutex_lock(&sleeplock);
	if (nsleeps < 256) sleeps[nsleeps++] = s;
	pthread_mutex_unlock(&sleeplock);
	usleep(s * sleep_us_per_s);
	return 0;
}
// short sleeps 50 times faster, unless a test needs real ones; the monitor's looks for a play's
// first track rate (TRACK_WAIT_US) are counted
static unsigned usleep_div = 50;
static _Atomic unsigned track_waits;
// The matrix gates the monitor: its looks for the output coming on (OFF_POLL_US) and for the
// play's first track (TRACK_WAIT_US) each wait for the test's monitor_step(), so a stop or a new
// album lands at an exact point of its work. (set_rate's 10 ms looks never sleep here: the fake
// HAL's rate changes land at once.)
static bool gate_monitor;
static pthread_mutex_t gate_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_cond = PTHREAD_COND_INITIALIZER;
static unsigned gate_grants, gate_parks;
static bool gate_parked;
static int fake_usleep(useconds_t us) {
	if (us == TRACK_WAIT_US) atomic_fetch_add(&track_waits, 1);
	if (gate_monitor && (us == OFF_POLL_US || us == TRACK_WAIT_US)) {
		pthread_mutex_lock(&gate_lock);
		gate_parked = true;
		gate_parks++;
		pthread_cond_broadcast(&gate_cond);
		while (!gate_grants) pthread_cond_wait(&gate_cond, &gate_lock);
		gate_grants--;
		gate_parked = false;
		pthread_mutex_unlock(&gate_lock);
		return 0;
	}
	return usleep(us / usleep_div + 1);
}

// the engine's stdout lines, which the agent reads
static pthread_mutex_t outlock = PTHREAD_MUTEX_INITIALIZER;
static char reports[16][96];
static unsigned nreports;
static int fake_printf(const char *fmt, ...) {
	char line[256];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	pthread_mutex_lock(&outlock);
	if (!strncmp(line, "lyrionplay:volume", 17) && nreports < 16) {
		line[strcspn(line, "\n")] = 0;
		strncpy(reports[nreports++], line, sizeof(reports[0]) - 1);
	}
	pthread_mutex_unlock(&outlock);
	return n;
}

static _Atomic int live_threads;
struct trampoline { void *(*fn)(void *); void *arg; };
static void *run_counted(void *p) {
	struct trampoline t = *(struct trampoline *)p;
	void *r;
	free(p);
	r = t.fn(t.arg);
	atomic_fetch_sub(&live_threads, 1);
	return r;
}
static int fake_pthread_create(pthread_t *th, const pthread_attr_t *attr, void *(*fn)(void *), void *arg) {
	struct trampoline *t = malloc(sizeof(*t));
	int r;
	*t = (struct trampoline){ fn, arg };
	atomic_fetch_add(&live_threads, 1);
	if ((r = pthread_create(th, attr, run_counted, t))) atomic_fetch_sub(&live_threads, 1);
	return r;
}

// ---------------------------------------------------------------------------------------------
// Helpers for the tests

static int failed;
#define CHECK(cond, ...) do { if (!(cond)) { failed = 1; fprintf(stderr, "    FAILED %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

// waits up to 3 s of real time for a condition the engine's threads bring about
#define WAIT_FOR(cond) do { for (int _i = 0; _i < 300 && !(cond); _i++) usleep(10000); } while (0)

static unsigned gain_for_db(float db) { return (unsigned)lrint(65536.0 * pow(10.0, db / 20.0)); }

static void advance_us(uint64_t us) { atomic_fetch_add(&clock_offset, us * 1000); }

// --- the engine, started and stopped as main.c does

#define IDLE_MS 30000                     // -C 30: main.c passes it in ms
static unsigned start_rate_delay;         // -r …:<ms>, "Silence on a rate change"

// every write_cb call passes through here: calls are counted, and the delay's silence (pause
// frames, OUTPUT_PAUSE_FRAMES) is added up in seconds at the device's rate
static int (*engine_write)(frames_t, bool, s32_t, s32_t, u8_t, s32_t, s32_t, s32_t **);
static unsigned write_calls;
static double silence_s, tick_pause_s;
static int counting_write(frames_t f, bool silence, s32_t gl, s32_t gr, u8_t flags, s32_t ci, s32_t co, s32_t **cp) {
	int w = engine_write(f, silence, gl, gr, flags, ci, co, cp);
	write_calls++;
	if (silence && w > 0 && output.state == OUTPUT_PAUSE_FRAMES) {
		silence_s += (double)w / ca.rate;
		tick_pause_s += (double)w / ca.rate;
	}
	return w;
}

// As main.c: the agent passes -r (the device's rates and the delay) only with a rate delay, and -r
// sets user_rates; without it output_init_common asks the device (test_open), and exits if it is
// absent, so a test that starts with the device away passes the rates as -r would. The level is
// unity, as after LMS's first audg at 100%: until one comes it is 0 (memset).
static void start(const char *uid, const char *params, unsigned idle, bool hw, bool linear) {
	static char p[32];
	static unsigned rates[MAX_SUPPORTED_SAMPLERATES];
	fdev *d = dev_by_uid(uid);
	strncpy(p, params, sizeof(p) - 1);
	memset(rates, 0, sizeof(rates));
	if (d && (start_rate_delay || !d->present)) {
		unsigned n = 0, last = UINT_MAX;
		while (n < MAX_SUPPORTED_SAMPLERATES) {   // sorted down, as main.c sorts -r's list
			unsigned best = 0;
			for (unsigned i = 0; i < d->nrates; i++) {
				if ((unsigned)d->rates[i] < last && (unsigned)d->rates[i] > best) best = (unsigned)d->rates[i];
			}
			if (!best) break;
			rates[n++] = last = best;
		}
		user_rates = true;
	}
	output_init_coreaudio(lINFO, uid, OUTPUTBUF_SIZE, p, rates, start_rate_delay, idle, hw, linear);
	LOCK;
	output.gainL = output.gainR = FIXED_ONE;
	engine_write = output.write_cb;
	output.write_cb = counting_write;
	UNLOCK;
}

static void reopen(void) {
	LOCK;
	_ca_open();
	UNLOCK;
}

static void stop(void) {
	pthread_mutex_lock(&gate_lock);          // a gated monitor is let go, so it can see the close
	gate_monitor = false;
	gate_grants += 1000;
	pthread_cond_broadcast(&gate_cond);
	pthread_mutex_unlock(&gate_lock);
	output_close_coreaudio();
	WAIT_FOR(atomic_load(&live_threads) == 0);
}

static bool device_open(void) {
	bool open;
	LOCK;
	open = ca.dev != kAudioObjectUnknown && ca.procid;
	UNLOCK;
	return open;
}

// one IOProc call, as the HAL makes it: io_frames frames; io_samples holds what it handed the device
#define IO_MAX 4096
static float io_samples[2 * IO_MAX];
static unsigned io_frames = 512;
static void run_ioproc(void) {
	AudioBufferList list = { 1, { { 2, io_frames * 2 * sizeof(float), io_samples } } };
	AudioTimeStamp now = { 0 }, out = { 0 };
	ioproc(ca.dev, &now, NULL, NULL, &list, &out, NULL);
}

// --- the decoder. Every decoder sets the next track's rate and format and track_start (writep)
// under the lock before it writes the track's first frames (flac.c, pcm.c, dsd.c, ...). Each frame
// carries its track and position, so what reached the device says what played where:
//   PCM  (0x10 + track) << 24 | position << 8     24 significant bits: exact through the Float32
//   DoP  (0x30 + track) << 16 | position << 8     the DSD bytes; update_dop puts the marker on top
#define MAXTRK 12
static struct {
	unsigned rate;
	dsd_format fmt;
	u8_t *start;
	unsigned written, target, played, misorder, start_tick, first_tick;
	bool started, flushed;
} trk[MAXTRK + 1];
static unsigned ntrk, dec_track;
static bool decoder_done;                 // the stream has ended: the decoder has written all of it

static s32_t music_frame(unsigned t, unsigned pos) {
	return trk[t].fmt == PCM ? (s32_t)((0x10u + t) << 24 | (pos & 0xFFFF) << 8) : (s32_t)((0x30u + t) << 16 | (pos & 0xFF) << 8);
}

// n more frames of the decoder's track. Called locked.
static void _decoder_writes(unsigned n) {
	while (n-- && _buf_space(outputbuf) >= BYTES_PER_FRAME) {
		s32_t *f = (s32_t *)outputbuf->writep;
		f[0] = f[1] = music_frame(dec_track, trk[dec_track].written++);
		_buf_inc_writep(outputbuf, BYTES_PER_FRAME);
	}
}

// the decoder finds a track at `rate` in `fmt`, whose start is the next frame, and writes n frames
// of it. Called locked.
static unsigned _decoder_starts(unsigned rate, dsd_format fmt, unsigned n) {
	unsigned t = ntrk < MAXTRK ? ++ntrk : ntrk;
	memset(&trk[t], 0, sizeof(trk[t]));
	trk[t].rate = rate;
	trk[t].fmt = fmt;
	trk[t].start = outputbuf->writep;
	trk[t].target = n;                     // all of it now; a slow stream raises it and writes on
	output.next_sample_rate = rate;
	output.next_fmt = fmt;
	output.track_start = outputbuf->writep;
	dec_track = t;
	_decoder_writes(n);
	return t;
}

// the track's first frame, at `rate`, in the format the test set (output.next_fmt). Called locked.
static void _decoder_finds(unsigned rate) {
	_decoder_starts(rate, output.next_fmt, 1);
}

// the track whose start a track_start pointer is: the last one written there
static unsigned track_at(u8_t *p) {
	for (unsigned t = ntrk; t > 0; t--) if (trk[t].start == p) return t;
	return 0;
}

// --- LMS's commands and slimproto's loop, as slimproto.c runs them

// strm q (slimproto.c:288): a stop, and the first step of every new stream. What the decoder had
// written and the device not played is gone.
static unsigned nticks;                    // IOProc calls so far (the recorder, below)
static unsigned flush_ticks[64], nflush;   // the IOProc call each strm q came before
static void strm_q(void) {
	if (nflush < 64) flush_ticks[nflush++] = nticks;
	output_flush();
	LOCK;
	for (unsigned t = 1; t <= ntrk; t++) if (trk[t].played < trk[t].target) trk[t].flushed = true;
	UNLOCK;
	decoder_done = true;
}

// strm s (slimproto.c:344-395, its part for the output); threshold in tenths of a second
static void strm_s(unsigned threshold) {
	LOCK;
	output.threshold = threshold;
	output.next_replay_gain = 0;
	output.fade_mode = FADE_NONE;
	output.invert = false;
	output.channels = 0;
	UNLOCK;
	decoder_done = false;
}

// once decoding runs with autostart 1, a stopped or off output buffers (slimproto.c:676-684, 723)
static void start_output(void) {
	LOCK;
	if (output.state == OUTPUT_STOPPED || output.state == OUTPUT_OFF) output.state = OUTPUT_BUFFER;
	UNLOCK;
}

// strm p with no interval: pause (slimproto.c:306-318)
static void strm_p(void) {
	LOCK;
	output.pause_frames = 0;
	if (output.state != OUTPUT_OFF) {
		output.state = OUTPUT_STOPPED;
		output.stop_time = gettime_ms();
	}
	UNLOCK;
}

// strm u: unpause, at once or at a time (a synced start) (slimproto.c:332-339)
static void strm_u(u32_t jiffies) {
	LOCK;
	output.state = jiffies ? OUTPUT_START_AT : OUTPUT_RUNNING;
	output.start_at = jiffies;
	UNLOCK;
}

// one turn of slimproto's loop for the output (slimproto.c:716-743): the reopen the IOProc asked
// for, the end of the music (the underrun once the stream has ended), the idle timeout
static void controller(void) {
	u32_t now = gettime_ms();
	LOCK;
	if (output.ca_reopen) {
		output.ca_reopen = false;
		_ca_open();
	}
	if (output.state == OUTPUT_RUNNING && !_buf_used(outputbuf) && decoder_done) {
		output.state = OUTPUT_STOPPED;
		output.stop_time = now;
	}
	if (output.state == OUTPUT_STOPPED && output.idle_to && now - output.stop_time > output.idle_to) {
		output.state = OUTPUT_OFF;
	}
	UNLOCK;
}

// --- what the device got: every frame of every IOProc call, classified

enum kind { K_ZERO, K_DOPSIL, K_PCM, K_DOP, K_JUNK };
static const char *kind_name[] = { "zeros", "DoP silence", "PCM music", "DoP music", "junk" };
struct seg {
	unsigned tick, run, rate, track, frames;
	enum kind kind;
	bool tail;                             // left zero by the IOProc (after it stopped taking frames)
	u32_t hash;                            // FNV-1a of every sample's bits, for write_sig
};
struct tickinfo {
	unsigned run, rate;
	unsigned pend;                         // the track whose start was the next frame, at this rate
	unsigned started;                      // the track whose start output.c took in this call
	double pause_s;                        // the delay's silence in this call
	bool reopen;                           // the IOProc asked for a reopen
	bool after_close;                      // the device was closed since the previous call (the monitor opened it)
	bool off;                              // the output was off (the call before an idle release's close)
};
#define MAXSEG 200000
#define MAXTICK 100000
static struct seg *segs;
static struct tickinfo *ticks;
static unsigned nsegs, nticks;

static u32_t fnv(u32_t h, float l, float r) {
	u32_t b[2];
	memcpy(b, &l, 4);
	memcpy(b + 1, &r, 4);
	for (unsigned i = 0; i < 8; i++) h = (h ^ ((const unsigned char *)b)[i]) * 16777619u;
	return h;
}

static enum kind classify(float l, float r, unsigned *track, unsigned *pos) {
	s32_t s = (s32_t)lrint((double)l * 2147483648.0), sr = (s32_t)lrint((double)r * 2147483648.0);
	u32_t u = (u32_t)s, top = u >> 24, mid = (u >> 16) & 0xFF, low = (u >> 8) & 0xFF;
	if (s != sr || (u & 0xFF)) return K_JUNK;
	if (!s) return K_ZERO;
	if (top == 0x05 || top == 0xFA) {
		if (mid == 0x69 && low == 0x69) return K_DOPSIL;
		if (mid > 0x30 && mid <= 0x30 + MAXTRK) {
			*track = mid - 0x30;
			*pos = low;
			return K_DOP;
		}
		return K_JUNK;
	}
	if (top > 0x10 && top <= 0x10 + MAXTRK) {
		*track = top - 0x10;
		*pos = (u >> 8) & 0xFFFF;
		return K_PCM;
	}
	return K_JUNK;
}

static void record(void) {
	unsigned run = atomic_load(&device_starts);
	if (!segs) {
		segs = calloc(MAXSEG, sizeof(*segs));
		ticks = calloc(MAXTICK, sizeof(*ticks));
	}
	for (unsigned i = 0; i < io_frames; i++) {
		unsigned t = 0, pos = 0;
		bool tail = i >= io_pos;
		enum kind k = classify(io_samples[2 * i], io_samples[2 * i + 1], &t, &pos);
		struct seg *last = nsegs ? &segs[nsegs - 1] : NULL;
		if (k == K_PCM || k == K_DOP) {
			if (pos != (trk[t].played & (trk[t].fmt == PCM ? 0xFFFF : 0xFF))) trk[t].misorder++;
			if (!trk[t].played) trk[t].first_tick = nticks;
			trk[t].played++;
		}
		if (last && last->tick == nticks && last->kind == k && last->track == t && last->tail == tail) {
			last->frames++;
			last->hash = fnv(last->hash, io_samples[2 * i], io_samples[2 * i + 1]);
		} else if (nsegs < MAXSEG) {
			segs[nsegs++] = (struct seg){ nticks, run, ca.rate, t, 1, k, tail,
										  fnv(2166136261u, io_samples[2 * i], io_samples[2 * i + 1]) };
		}
	}
}

// one IOProc call while the device runs (or 10 ms while it is closed), then slimproto's loop. The
// clock moves on by the call's length.
static bool closed_since_tick;
static void tick(void) {
	struct tickinfo ti = { 0 };
	bool open;
	u8_t *ts;
	LOCK;
	open = ca.dev != kAudioObjectUnknown && ca.procid;
	ts = output.track_start;
	if (open && ts && ts == outputbuf->readp && _buf_used(outputbuf) && output.next_sample_rate == ca.rate) {
		ti.pend = track_at(ts);
	}
	ti.off = output.state == OUTPUT_OFF;
	UNLOCK;
	if (open) {
		unsigned rate = ca.rate;
		tick_pause_s = 0;
		run_ioproc();
		LOCK;
		if (ts && !output.track_start && (ti.started = track_at(ts))) {
			trk[ti.started].started = true;
			trk[ti.started].start_tick = nticks;
		}
		ti.reopen = output.ca_reopen;
		ti.run = atomic_load(&device_starts);
		ti.rate = rate;
		ti.pause_s = tick_pause_s;
		ti.after_close = closed_since_tick;
		closed_since_tick = false;
		UNLOCK;
		record();
		if (nticks < MAXTICK) ticks[nticks] = ti;
		nticks++;
		advance_us((uint64_t)io_frames * 1000000 / rate);
	} else {
		closed_since_tick = true;
		advance_ms(10);
	}
	controller();
	if (!device_open()) closed_since_tick = true; // the reopen for the output going off closed it
}

// --- the gated monitor (the matrix)

// waits until the gated monitor is parked in a look, or there is none; called with gate_lock held
static void _monitor_settle(void) {
	for (int i = 0; i < 2000 && !gate_parked && atomic_load(&live_threads) > 0; i++) {
		struct timespec t;
		clock_gettime(CLOCK_REALTIME, &t);
		t.tv_nsec += 1000000;
		if (t.tv_nsec >= 1000000000) {
			t.tv_sec++;
			t.tv_nsec -= 1000000000;
		}
		pthread_cond_timedwait(&gate_cond, &gate_lock, &t);
	}
}
static void monitor_settle(void) {
	pthread_mutex_lock(&gate_lock);
	_monitor_settle();
	pthread_mutex_unlock(&gate_lock);
}

// lets the parked monitor finish its look and go on until it parks again or is gone (it opened,
// or failed and handed over to a new monitor, which parks); false if none was parked
static bool monitor_step(void) {
	bool ok;
	pthread_mutex_lock(&gate_lock);
	_monitor_settle();
	if ((ok = gate_parked)) {
		unsigned parks = gate_parks;
		gate_grants++;
		pthread_cond_broadcast(&gate_cond);
		for (int i = 0; i < 2000 && gate_parks == parks && atomic_load(&live_threads) > 0; i++) {
			struct timespec t;
			clock_gettime(CLOCK_REALTIME, &t);
			t.tv_nsec += 1000000;
			if (t.tv_nsec >= 1000000000) {
				t.tv_sec++;
				t.tv_nsec -= 1000000000;
			}
			pthread_cond_timedwait(&gate_cond, &gate_lock, &t);
		}
		_monitor_settle();
	}
	pthread_mutex_unlock(&gate_lock);
	return ok;
}

static output_state output_state_now(void) {
	output_state s;
	LOCK;
	s = output.state;
	UNLOCK;
	return s;
}

// the device closed and the output on: the monitor opens it (stepped through, if gated)
static void open_device(void) {
	if (gate_monitor) {
		for (int i = 0; i < 40 && !device_open() && output_state_now() != OUTPUT_OFF; i++) {
			if (!monitor_step()) break;
		}
	} else {
		WAIT_FOR(device_open() || output_state_now() == OUTPUT_OFF);
	}
}

// --- playing tracks the way LMS does

// a play as slimproto starts it: strm q, strm s, then the output comes on to buffer; the decoder
// first, or not yet. A 2 s threshold, so the one frame the decoder writes keeps it buffering.
static void play_from_idle_fmt(unsigned rate, dsd_format fmt, bool decoder_first) {
	strm_q();
	strm_s(20);
	if (decoder_first) {
		LOCK;
		_decoder_starts(rate, fmt, 1);
		UNLOCK;
	}
	start_output();
}
static void play_from_idle(unsigned rate, bool decoder_first) {
	play_from_idle_fmt(rate, output.next_fmt, decoder_first);
}

// plays a whole track (frames of it), from wherever the engine is, the way LMS starts one, to the
// underrun at the stream's end: the output is then stopped, the device still open. Threshold 0:
// output.c starts on the first frame (with 1, a track shorter than 0.1 s would buffer for ever).
static unsigned play_track(unsigned rate, dsd_format fmt, unsigned frames) {
	unsigned t;
	strm_q();
	strm_s(0);
	LOCK;
	t = _decoder_starts(rate, fmt, frames);
	UNLOCK;
	decoder_done = true;
	start_output();
	for (int i = 0; i < 20000 && (trk[t].played < trk[t].written || output_state_now() != OUTPUT_STOPPED); i++) {
		if (!device_open()) open_device();
		tick();
	}
	return t;
}

// the idle timeout: the output goes off, the IOProc asks for the reopen that closes the device, and
// a monitor waits for the output to come on again
static void idle_release(void) {
	advance_ms(output.idle_to + 1000);
	controller();
	for (int i = 0; i < 4 && device_open(); i++) tick();
	if (gate_monitor) monitor_settle();
}

static unsigned nreports_now(void) {
	unsigned n;
	pthread_mutex_lock(&outlock);
	n = nreports;
	pthread_mutex_unlock(&outlock);
	return n;
}

// ---------------------------------------------------------------------------------------------
// The tests

// LYRIONPLAY review 2026-10-10, finding 2: vrec.lock was held across RemovePropertyListener, and
// the listener takes vrec.lock, so a volume key pressed as the engine exits deadlocked.
static void listener_removed_at_exit_while_a_call_is_running(void) {
	add_speakers();
	start("BuiltInSpeakerDevice", "0:0", 0, true, false);
	inflight_on_remove = true;
	stop();
	CHECK(removes_armed == 1, "the remove with a call in flight never happened (%u)", removes_armed);
	CHECK(remove_timeouts == 0, "RemovePropertyListener waited %u time(s) for a listener blocked on vrec.lock", remove_timeouts);
}

// the same lock order when the volume moves to another device ID (the device re-enumerated)
static void listener_moved_to_a_new_device_while_a_call_is_running(void) {
	fdev *a = add_speakers(), *b;
	start("BuiltInSpeakerDevice", "0:0", 0, true, false);
	a->present = false;
	b = add_speakers(); // same UID, new ID
	default_out = b->id;
	inflight_on_remove = true;
	reopen();                              // the new engine watches the new device here,
	set_volume(gain_for_db(-30), gain_for_db(-30));      // the old one only here
	CHECK(removes_armed == 1, "the old device's listeners were never removed (%u)", removes_armed);
	CHECK(remove_timeouts == 0, "RemovePropertyListener waited %u time(s) for a listener blocked on vrec.lock", remove_timeouts);
	stop();
}

// finding 3: a rate the device refuses left it held exclusively, locking other apps out while
// nothing played
static void refused_rate_gives_exclusive_access_back(void) {
	fdev *d = add_dac();
	d->rate = 48000;
	d->refuse_rate = true;
	sleep_us_per_s = 1000000;                // real seconds: the monitor's first retry comes after the checks
	start(d->uid, "0:1", 0, false, false);  // stopped, 44.1 kHz wanted
	CHECK(d->hog_taken >= 1, "control: exclusive access was never taken (%u)", d->hog_taken);
	CHECK(d->hog == -1, "still held exclusively by pid %d after the open failed", d->hog);
	CHECK(d->started == 0, "control: nothing should be running");
	stop();
}

// finding 3, and the review of its fix: a device held by another app (Audirvana, Roon) must start
// playing within 5 s of being let go. The first fix backed off to 30 s, which this test's older
// form could not see: it checked the waits chosen, with time running 500 times faster.
static void busy_device_plays_within_5s_of_being_let_go(void) {
	fdev *d = add_dac();
	d->hog = 4242; // another app's exclusive access
	start(d->uid, "0:1", 0, false, false);
	WAIT_FOR(nsleeps >= 12);
	unsigned want[] = { 2, 4, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 };
	for (unsigned i = 0; i < 12; i++) CHECK(sleeps[i] == want[i], "retry %u waited %u s, not %u", i + 1, sleeps[i], want[i]);
	// the other app lets go: at most one more wait, of at most 5 s, before it opens
	pthread_mutex_lock(&sleeplock);
	unsigned before = nsleeps;
	pthread_mutex_lock(&hal);
	d->hog = -1;
	pthread_mutex_unlock(&hal);
	pthread_mutex_unlock(&sleeplock);
	WAIT_FOR(d->started == 1);
	CHECK(d->started == 1, "not opened once the other app let go");
	CHECK(nsleeps - before <= 1, "%u waits after it was let go, not 1", nsleeps - before);
	for (unsigned i = 0; i < nsleeps; i++) CHECK(sleeps[i] <= 5, "a %u s wait (wait %u)", sleeps[i], i + 1);
	CHECK(d->hog == getpid(), "not exclusive after the retry (owner %d)", d->hog);
	stop();
}

// finding 3: the reason a device will not open was logged on every try, several MB a day; it is
// logged on the first three tries and then every 60th (5 minutes at 5 s)
static void busy_device_says_why_at_first_then_every_5_minutes(void) {
	fdev *d = add_dac();
	d->hog = 4242;
	start(d->uid, "0:1", 0, false, false);
	WAIT_FOR(nsleeps >= 70); // 70 or so tries: the 1st, 2nd, 3rd and 61st speak
	unsigned held = log_count("held exclusively by another process"), retrying = log_count("retrying ");
	CHECK(nsleeps >= 70, "only %u tries", nsleeps);
	CHECK(held == 4, "the reason logged %u times in %u tries, not 4", held, nsleeps);
	CHECK(retrying == 3, "'retrying' logged %u times, not 3", retrying);
	stop();
}

// control for the above: a device that is missing is still looked for every 2 s
static void missing_device_is_looked_for_every_2s(void) {
	fdev *d = add_dac();
	d->present = false;
	start(d->uid, "0:1", 0, false, false);
	WAIT_FOR(nsleeps >= 4);
	for (unsigned i = 0; i < 4; i++) CHECK(sleeps[i] == 2, "look %u waited %u s, not 2", i + 1, sleeps[i]);
	d->present = true;
	WAIT_FOR(d->started == 1);
	CHECK(d->started == 1, "not opened when it came back");
	stop();
}

// finding 7: with -V, LMS's level was lost if it arrived while the device was absent at init
static void lms_level_reaches_a_device_absent_at_init(void) {
	fdev *d = add_speakers();
	d->present = false;
	start(d->uid, "0:0", 0, true, false);
	set_volume(gain_for_db(-30), gain_for_db(-30));         // a track starts while the device is away
	CHECK(fabsf(d->db - -20) < 0.01f, "control: the device was changed while absent (%.2f)", d->db);
	d->present = true;
	WAIT_FOR(d->started == 1);
	WAIT_FOR(fabsf(d->db - -30) < 0.05f);
	CHECK(fabsf(d->db - -30) < 0.05f, "LMS's -30 dB never reached the device (%.2f dB)", d->db);
	stop();
}

// finding 7, second half: a device absent at init was never watched, so the Mac's volume keys
// did not reach LMS until a track started
static void device_absent_at_init_is_watched_once_open(void) {
	fdev *d = add_speakers();
	d->present = false;
	start(d->uid, "0:0", 0, true, false);
	d->present = true;
	WAIT_FOR(d->started == 1);
	user_set_db(d, -35);
	WAIT_FOR(nreports_now() >= 1);
	CHECK(nreports_now() == 1, "%u reports of the volume key, not 1", nreports_now());
	stop();
}

// review of finding 7's fix: with no device open, a level is left pending for _ca_open, so the
// monitor opening the device and set_volume can apply at once. On a resume after the idle
// release LMS fades in, an audg every 50 ms (RESUME IS ONE AUDG): a newer level landing during
// the monitor's apply must still be the one the device ends at.
static _Atomic bool newer_done;
static void *newer_audg(void *arg) {
	set_volume(gain_for_db(-20), gain_for_db(-20));
	atomic_store(&newer_done, true);
	return NULL;
}
static void newer_audg_lands_meanwhile(void) {
	pthread_t t;
	pthread_create(&t, NULL, newer_audg, NULL);
	pthread_detach(t);
	usleep(100000); // unserialised, the newer level lands now, before this older one
}
static void newer_level_wins_over_one_being_applied(void) {
	fdev *d = add_speakers();
	d->present = false;
	sleep_us_per_s = 1000000;                 // the engine's own monitor stays out of the way
	start(d->uid, "0:0", 0, true, false);
	set_volume(gain_for_db(-30), gain_for_db(-30)); // pending: the device is away
	d->present = true;
	during_next_level_change = newer_audg_lands_meanwhile;
	reopen();                                 // as the monitor: puts the pending -30 dB on
	WAIT_FOR(atomic_load(&newer_done));
	CHECK(atomic_load(&newer_done), "the newer audg never finished");
	CHECK(fabsf(d->db - -20) < 0.05f, "the device ended at %.2f dB, not the newer -20 dB", d->db);
	stop();
}

// findings 5 and 6: each report says what the engine knows of LMS's volume, so the agent asks
// LMS only when it must: -1 before any audg (fixed or not is unknown), 1 a level, 0 silence
static void reports_carry_lms_state(void) {
	fdev *d = add_speakers();
	start(d->uid, "0:0", 0, true, false);
	user_set_db(d, -30);
	set_volume(gain_for_db(-25), gain_for_db(-25));
	advance_ms(600);                          // past the settle window
	user_set_db(d, -40);
	set_volume(0, 0);                         // LMS muted
	advance_ms(600);
	user_set_mute(d, 0);
	user_set_db(d, -45);
	CHECK(nreports >= 3, "%u reports, not 3 or more", nreports);
	CHECK(nreports >= 1 && !strcmp(reports[0], "lyrionplay:volume -30.00 0 -1"), "before any audg: '%s'", reports[0]);
	CHECK(nreports >= 2 && !strcmp(reports[1], "lyrionplay:volume -40.00 0 1"), "after a level: '%s'", reports[1]);
	CHECK(nreports >= 3 && !strcmp(reports[nreports - 1], "lyrionplay:volume -45.00 0 0"), "after LMS muted: '%s'",
		  reports[nreports - 1]);
	stop();
}

// pins FIXED VOLUME LEAVES THE DEVICE ALONE: no level put on the device, nothing reported
static void fixed_volume_leaves_the_device_alone(void) {
	fdev *d = add_speakers();
	start(d->uid, "0:0", 0, true, false);
	output.volume_fixed = true;
	set_volume(FIXED_ONE, FIXED_ONE);
	CHECK(fabsf(d->db - -20) < 0.01f, "the device moved to %.2f dB under fixed volume", d->db);
	advance_ms(600);
	user_set_db(d, -33);
	CHECK(nreports == 0, "%u reports under fixed volume", nreports);
	stop();
}

// pins READ-BACK IS NOT THE LEVEL SET: a device that lands 1 dB off the level set is not mistaken
// for the user
static void own_change_with_a_coarse_read_back_is_not_reported(void) {
	fdev *d = add_speakers();
	d->step = 2.0f;
	start(d->uid, "0:0", 0, true, false);
	set_volume(gain_for_db(-24.5f), gain_for_db(-24.5f));
	CHECK(fabsf(d->db - -24.5f) > 0.6f, "control: the read-back should miss the level set (%.2f)", d->db);
	advance_ms(600);
	notify(d->id, kAudioDevicePropertyVolumeScalar); // a late duplicate notification
	CHECK(nreports == 0, "%u report(s) of the engine's own change", nreports);
	stop();
}

// pins VOLUME BOTH WAYS: a user change is reported once; a jitter within 0.6 dB is not; a mute is
static void user_change_reported_once_and_mute_reported(void) {
	fdev *d = add_speakers();
	start(d->uid, "0:0", 0, true, false);
	user_set_db(d, -30);
	notify(d->id, kAudioDevicePropertyVolumeScalar); // the same change, announced twice
	user_set_db(d, -30.4f);
	CHECK(nreports == 1, "%u reports, not 1", nreports);
	user_set_mute(d, 1);
	int muted = -1;
	CHECK(nreports == 2 && sscanf(reports[1], "lyrionplay:volume %*f %d", &muted) == 1 && muted == 1, "mute: '%s'",
		  nreports == 2 ? reports[1] : "(none)");
	stop();
}

// pins: -X (linear) reports nothing
static void linear_mode_reports_nothing(void) {
	fdev *d = add_speakers();
	start(d->uid, "0:0", 0, true, true);
	user_set_db(d, -30);
	CHECK(nreports == 0, "%u reports in linear mode", nreports);
	stop();
}

// pins the idle release: exclusive access only while the output is on
static void exclusive_released_when_the_output_goes_off(void) {
	fdev *d = add_dac();
	start(d->uid, "0:1", 0, false, false);
	CHECK(d->hog == getpid() && d->started == 1, "control: not opened exclusively (owner %d)", d->hog);
	output.state = OUTPUT_OFF;
	reopen();
	CHECK(d->hog == -1, "still exclusive with the output off (owner %d)", d->hog);
	stop();
}

// pins bit-perfect rate switching: the device takes the track's rate, in 32-bit integer
static void device_follows_the_track_rate(void) {
	fdev *d = add_dac();
	start(d->uid, "0:1", 0, false, false);
	output.current_sample_rate = 96000;
	reopen();
	CHECK(d->rate == 96000, "device at %.0f Hz, not 96000", d->rate);
	CHECK(d->phys.mBitsPerChannel == 32 && !(d->phys.mFormatFlags & kAudioFormatFlagIsFloat), "physical format %u-bit%s",
		  (unsigned)d->phys.mBitsPerChannel, (d->phys.mFormatFlags & kAudioFormatFlagIsFloat) ? " float" : "");
	CHECK(log_count("opened Test DAC at 96000 Hz, exclusive") == 1, "no 'opened ... exclusive' line");
	stop();
}

// review after 0.2.2, finding 4: the agent stops the engine (a settings change, Off) while the
// monitor is opening the device, unlocked, for up to 3 s of relock. Close found nothing open and
// returned, and the engine then freed the output buffer while the monitor went on to take
// exclusive access and start an IOProc on it.
static _Atomic bool opening;
static void relock_takes_a_while(void) {
	atomic_store(&opening, true);
	usleep(300000);
}
static void close_while_the_monitor_opens_leaves_nothing_running(void) {
	fdev *d = add_dac();
	d->rate = 48000;                          // so the open changes the rate
	start(d->uid, "0:1", 30, false, false);   // -C 30: off, the monitor waits for output on
	CHECK(d->started == 0 && d->hog == -1, "control: opened while off");
	during_next_rate_change = relock_takes_a_while;
	output.state = OUTPUT_STOPPED;            // a play from idle: the monitor opens
	WAIT_FOR(atomic_load(&opening));
	CHECK(atomic_load(&opening), "control: the monitor never started opening");
	output_close_coreaudio();
	unsigned started = d->started, procs = d->procs;
	pid_t hog = d->hog;
	WAIT_FOR(atomic_load(&live_threads) == 0); // the old code's monitor carries on meanwhile
	CHECK(started == 0 && d->started == 0, "an IOProc is running after close (%u at return, %u after)", started, d->started);
	CHECK(procs == 0 && d->procs == 0, "an IOProc exists after close (%u at return, %u after)", procs, d->procs);
	CHECK(hog == -1 && d->hog == -1, "exclusive after close (owner %d at return, %d after)", hog, d->hog);
}

// the same, a moment later, as it happened live (2026-10-11 10:06:41, FiiO): the monitor has passed
// its last look at `running` and is starting the device when close comes. Close must wait for the
// start, then stop the device and give it back, before the engine frees the output buffer.
static void close_while_the_monitor_starts_the_device_stops_it(void) {
	fdev *d = add_dac();
	d->rate = 48000;
	start(d->uid, "0:1", 30, false, false);
	during_next_start = relock_takes_a_while;
	output.state = OUTPUT_STOPPED;
	WAIT_FOR(atomic_load(&opening));
	CHECK(atomic_load(&opening), "control: the monitor never started the device");
	output_close_coreaudio();
	unsigned started = d->started, procs = d->procs;
	pid_t hog = d->hog;
	WAIT_FOR(atomic_load(&live_threads) == 0);
	CHECK(started == 0 && d->started == 0, "the device runs after close (%u at return, %u after)", started, d->started);
	CHECK(procs == 0 && d->procs == 0, "an IOProc exists after close (%u at return, %u after)", procs, d->procs);
	CHECK(hog == -1 && d->hog == -1, "exclusive after close (owner %d at return, %d after)", hog, d->hog);
	CHECK(log_count("opened Test DAC") == 1, "control: the open did not finish (%u)", log_count("opened Test DAC"));
}

// the fix above must not make close wait out a monitor that is only waiting to retry (up to 5 s):
// the agent kills an engine that has not stopped within 3 s
static void close_does_not_wait_for_a_monitor_between_retries(void) {
	fdev *d = add_dac();
	struct timespec t0, t1;
	d->hog = 4242;                            // another app holds it: the monitor waits 2 s, 4 s, ...
	sleep_us_per_s = 1000000;                 // real seconds
	start(d->uid, "0:1", 0, false, false);
	WAIT_FOR(nsleeps >= 1);
	CHECK(nsleeps >= 1, "control: the monitor is not waiting to retry");
	clock_gettime(CLOCK_MONOTONIC, &t0);
	output_close_coreaudio();
	clock_gettime(CLOCK_MONOTONIC, &t1);
	long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
	CHECK(ms < 500, "close took %ld ms with the monitor between retries", ms);
}

// review after 0.2.2, finding 3 (TWO RATE SWITCHES AT PLAY): a play from idle opened the DAC at
// the last track's rate (44.1 kHz), then the track start reopened it at the track's own: two
// switches, ~0.7 s later than one (engine.log 2026-10-10, FiiO and DragonFly, 48 kHz tracks)
static void a_play_from_idle_switches_the_rate_once(void) {
	fdev *d = add_dac();
	d->rate = 96000;                          // where another app left it
	start(d->uid, "0:1", 30, false, false);   // -C 30: off; the last track was 44.1 kHz
	play_from_idle(48000, true);
	WAIT_FOR(d->started == 1);
	CHECK(d->started == 1, "control: never opened");
	CHECK(d->rate == 48000, "opened at %.0f Hz, not the track's 48000", d->rate);
	CHECK(d->rate_changes == 1, "%u rate changes, not 1", d->rate_changes);
	// the IOProc plays it at that rate: through the buffering and the track start, no reopen
	run_ioproc();
	CHECK(write_calls > 0, "the IOProc took nothing while the track buffered");
	CHECK(!output.ca_reopen, "reopen asked while the track buffered");
	output.state = OUTPUT_RUNNING;
	run_ioproc();
	CHECK(output.current_sample_rate == 48000 && !output.track_start, "control: the track start was not reached");
	CHECK(!output.ca_reopen, "reopen asked at the track start");
	CHECK(d->rate_changes == 1 && log_count("opened Test DAC") == 1, "%u rate changes, %u opens", d->rate_changes,
		  log_count("opened Test DAC"));
	stop();
}

// the monitor sees the play before the decoder has found the track's rate (half the plays on the
// DragonFly, 2026-10-10): it waits for it, then opens once at that rate
static void a_play_waits_for_the_decoder_and_switches_the_rate_once(void) {
	fdev *d = add_dac();
	d->rate = 96000;
	usleep_div = 1;                           // real 10 ms looks, so the decoder lands among them
	start(d->uid, "0:1", 30, false, false);
	play_from_idle(48000, false);             // the output is on; the rate is not known yet
	WAIT_FOR(atomic_load(&track_waits) >= 2);
	CHECK(atomic_load(&track_waits) >= 2 && d->started == 0, "control: the monitor did not wait (%u looks, started %d)",
		  atomic_load(&track_waits), d->started);
	LOCK;
	_decoder_finds(48000);                    // the decoder finds the first track
	UNLOCK;
	WAIT_FOR(d->started == 1);
	CHECK(d->rate == 48000 && d->rate_changes == 1, "at %.0f Hz after %u changes, not 48000 after 1", d->rate,
		  d->rate_changes);
	CHECK(log_count("track rate found after") == 1, "no 'track rate found' line");
	stop();
}

// the wait is capped: a decoder that has found nothing after 150 ms (a slow stream) is not waited
// for any longer; the monitor opens at the last track's rate, and the track start reopens, as
// before the fix
static void a_play_the_decoder_is_slow_for_opens_after_150_ms_as_before(void) {
	fdev *d = add_dac();
	struct timespec t0, t1;
	d->rate = 96000;
	usleep_div = 1;
	start(d->uid, "0:1", 30, false, false);
	clock_gettime(CLOCK_MONOTONIC, &t0);
	play_from_idle(48000, false);
	WAIT_FOR(d->started == 1);
	clock_gettime(CLOCK_MONOTONIC, &t1);
	long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
	CHECK(d->started == 1 && d->rate == 44100, "opened at %.0f Hz (started %d), not at the last rate 44100", d->rate, d->started);
	CHECK(atomic_load(&track_waits) == TRACK_WAIT_POLLS, "%u looks, not %u", atomic_load(&track_waits), TRACK_WAIT_POLLS);
	CHECK(log_count("track rate not found after 150 ms") == 1, "no 'not found after 150 ms' line");
	CHECK(ms < 600, "opened %ld ms after the play: up to 100 ms to notice it, 150 ms of waiting, then the open", ms);
	LOCK;
	_decoder_finds(48000);                    // the decoder, after the open
	output.state = OUTPUT_RUNNING;
	UNLOCK;
	run_ioproc();
	CHECK(output.ca_reopen, "no reopen for the track's 48 kHz");
	output.ca_reopen = false;
	reopen();                                 // as slimproto
	CHECK(d->rate == 48000, "reopened at %.0f Hz", d->rate);
	stop();
}

// the wait is only for a play: a resume after the idle release (LMS sends 'u', so the output goes
// straight to running) opens at once at the paused track's rate
static void a_resume_does_not_wait(void) {
	fdev *d = add_dac();
	usleep_div = 1;
	start(d->uid, "0:1", 30, false, false);
	LOCK;
	output.state = OUTPUT_RUNNING;
	UNLOCK;
	WAIT_FOR(d->started == 1);
	CHECK(d->started == 1 && d->rate == 44100, "not opened at the paused track's rate (%.0f Hz)", d->rate);
	CHECK(atomic_load(&track_waits) == 0, "a resume waited %u looks for a track rate", atomic_load(&track_waits));
	stop();
}

// pins the gapless boundary: a track at another rate starting while the device plays still stops
// the IOProc and reopens at the new rate (the opening-rate rule must not cover a running device)
static void a_gapless_track_at_another_rate_reopens(void) {
	fdev *d = add_dac();
	start(d->uid, "0:1", 0, false, false);   // playing at 44.1 kHz
	CHECK(d->started == 1 && d->rate == 44100, "control: not playing at 44100");
	LOCK;
	outputbuf->readp = outputbuf->writep = outputbuf->buf;
	output.state = OUTPUT_RUNNING;
	_decoder_finds(96000);                    // the next track's start is the next frame
	UNLOCK;
	run_ioproc();
	CHECK(output.current_sample_rate == 96000, "control: the track start was not reached");
	CHECK(output.ca_reopen, "no reopen at a 44.1 -> 96 kHz boundary");
	output.ca_reopen = false;
	reopen();
	CHECK(d->rate == 96000 && d->rate_changes == 1, "at %.0f Hz after %u changes", d->rate, d->rate_changes);
	stop();
}

// plays IOProc calls until the pending track has started and its silence is over (or a reopen is
// asked); false if that took too many calls
static bool play_through_the_track_start(void) {
	for (int i = 0; i < 100000; i++) {
		run_ioproc();
		if (output.ca_reopen) return true;
		if (!output.track_start && output.state == OUTPUT_RUNNING) return true;
	}
	return false;
}

// RATE DELAY STRETCHED AT PLAY (found 2026-10-11 in the TWO RATE SWITCHES fix): with "Silence on a
// rate change" set, a play from idle after a higher-rate track opened the device at the new rate,
// and output.c's first half of the silence, counted at the old rate, then lasted old/new times as
// long: here 96k -> 44.1k with 2000 ms, 2.18 s + 1 s, where the old code left 1 s after the switch
static void the_rate_delay_is_not_stretched_on_a_play_from_idle(void) {
	fdev *d = add_dac();
	d->rate = 96000;
	start_rate_delay = 2000;
	start(d->uid, "0:1", 30, false, false);
	LOCK;
	output.current_sample_rate = 96000;       // the last track was 96 kHz
	UNLOCK;
	play_from_idle(44100, true);
	WAIT_FOR(d->started == 1);
	CHECK(d->started == 1 && d->rate == 44100, "control: not opened at the track's 44100 (%.0f Hz)", d->rate);
	output.state = OUTPUT_RUNNING;
	CHECK(play_through_the_track_start(), "the track start was never reached");
	CHECK(!output.ca_reopen, "a reopen was asked");
	CHECK(fabs(silence_s - 1.0) < 0.01, "%.2f s of silence before the music, not the 1.00 s after the switch", silence_s);
	CHECK(output.current_sample_rate == 44100 && !output.delay_active, "control: the start was not taken cleanly");
	stop();
}

// pins the rate delay at a gapless boundary, where the device plays the old rate: half before the
// switch at the old rate, half after it at the new one
static void the_rate_delay_at_a_gapless_boundary_is_both_halves(void) {
	fdev *d = add_dac();
	start_rate_delay = 2000;
	start(d->uid, "0:1", 0, false, false);   // playing at 44.1 kHz
	LOCK;
	outputbuf->readp = outputbuf->writep = outputbuf->buf;
	output.state = OUTPUT_RUNNING;
	_decoder_finds(96000);
	UNLOCK;
	CHECK(play_through_the_track_start() && output.ca_reopen, "no reopen at the 44.1 -> 96 kHz boundary");
	CHECK(fabs(silence_s - 1.0) < 0.01, "%.2f s of silence before the switch, not 1.00", silence_s);
	output.ca_reopen = false;
	reopen();
	CHECK(d->rate == 96000, "control: reopened at %.0f Hz", d->rate);
	for (int i = 0; i < 100000 && output.state == OUTPUT_PAUSE_FRAMES; i++) run_ioproc();
	CHECK(fabs(silence_s - 2.0) < 0.01, "%.2f s of silence in all, not 2.00 (1 before, 1 after)", silence_s);
	stop();
}

// frames of the last IOProc call of one kind
static unsigned frames_of(enum kind k) {
	unsigned n = 0, t, pos;
	for (unsigned i = 0; i < io_frames; i++) n += classify(io_samples[2 * i], io_samples[2 * i + 1], &t, &pos) == k;
	return n;
}

// /code-review 2026-10-11, finding 1: a play from idle after a DoP track opened at the PCM track's
// rate while outfmt was still DOP (it changes at the track start), so the buffering silence was
// DoP markers on the 0x69 DSD pattern, played as PCM: a full-scale-path square wave at Nyquist
// (~-27 dBFS) for the whole buffering. Played for real since (3): the DSD64 track, then the release.
static void a_play_from_idle_after_dop_buffers_in_pcm_silence(void) {
	fdev *d = add_dac();
	unsigned w;
	start(d->uid, "0:1", IDLE_MS, false, false);
	play_track(176400, DOP, 4000);            // DSD64 as DoP, to its end
	idle_release();                           // the DAC let go; the last track's rate and format stay
	CHECK(!device_open() && output.outfmt == DOP, "control: not released after DoP (open %d, outfmt %d)", device_open(),
		  output.outfmt);
	play_from_idle_fmt(44100, PCM, true);
	open_device();
	CHECK(device_open() && d->rate == 44100, "control: not opened at the track's 44100 (%.0f Hz)", d->rate);
	w = write_calls;
	run_ioproc();
	CHECK(write_calls > w && !output.ca_reopen, "control: the IOProc did not play the buffering");
	CHECK(frames_of(K_ZERO) == io_frames, "%u of %u frames DoP silence while the 44.1k track buffered: DoP silence at a PCM rate",
		  frames_of(K_DOPSIL), io_frames);
	stop();
}

// /code-review 2026-10-11 (3), finding 1: output_flush resets current_sample_rate to the default
// when the output is not open (error_opening, which the idle release sets) and leaves outfmt. A
// stop landing in a play from idle before the open was done (here inside it, while the DAC
// relocks) left the device at 44.1 kHz with outfmt still DOP, and _silence_fmt read "the device is
// at the current rate" as "outfmt plays here": DoP silence as PCM until the idle release, 30 s.
static void stop_now(void) {
	strm_q();
}
static void a_stop_inside_the_open_after_dop_leaves_pcm_silence(void) {
	fdev *d = add_dac();
	start(d->uid, "0:1", IDLE_MS, false, false);
	play_track(176400, DOP, 4000);
	idle_release();
	during_next_ioproc_create = stop_now;     // the user presses stop while the DAC relocks
	play_from_idle_fmt(44100, PCM, true);
	open_device();
	CHECK(device_open() && d->rate == 44100, "control: not opened at 44100 (%.0f Hz)", d->rate);
	CHECK(output.state == OUTPUT_STOPPED && output.current_sample_rate == 44100 && output.outfmt == DOP,
		  "control: not stopped with the rate reset and outfmt left (state %d, %u Hz, outfmt %d)", output.state,
		  output.current_sample_rate, output.outfmt);
	run_ioproc();
	CHECK(frames_of(K_ZERO) == io_frames, "%u of %u frames DoP silence at 44.1 kHz after the stop: a square wave at Nyquist",
		  frames_of(K_DOPSIL), io_frames);
	stop();
}

// the same with the stop before the monitor has seen the play (the decoder had not found the track
// either): the monitor opens for a stopped output, at the reset rate
static void a_stop_before_the_open_after_dop_leaves_pcm_silence(void) {
	fdev *d = add_dac();
	gate_monitor = true;
	start(d->uid, "0:1", IDLE_MS, false, false);
	play_track(176400, DOP, 4000);
	idle_release();
	play_from_idle_fmt(44100, PCM, false);    // the output comes on to buffer
	strm_q();                                 // and is stopped before the monitor's next look
	open_device();
	CHECK(device_open() && d->rate == 44100, "control: not opened at 44100 (%.0f Hz)", d->rate);
	run_ioproc();
	CHECK(frames_of(K_ZERO) == io_frames, "%u of %u frames DoP silence at 44.1 kHz after the stop", frames_of(K_DOPSIL),
		  io_frames);
	stop();
}

// pins upstream's DoP silence where it is DoP: at a DoP track's rate, after it ends, after a stop
// and in a pause inside one, the DAC is kept locked in DSD (dsd.c's pattern under DoP markers)
static void dop_silence_at_the_dop_rate_is_kept(void) {
	fdev *d = add_dac();
	unsigned t;
	start(d->uid, "0:1", IDLE_MS, false, false);
	play_track(176400, DOP, 4000);            // to its end: stopped, the device still at 176.4k
	CHECK(device_open() && d->rate == 176400, "control: not at 176400 (%.0f Hz)", d->rate);
	run_ioproc();
	CHECK(frames_of(K_DOPSIL) == io_frames, "%u of %u frames DoP silence after a DoP track ended at its rate",
		  frames_of(K_DOPSIL), io_frames);
	strm_q();
	run_ioproc();
	CHECK(frames_of(K_DOPSIL) == io_frames, "%u of %u frames DoP silence after a stop at the DoP rate", frames_of(K_DOPSIL),
		  io_frames);
	strm_s(1);
	LOCK;
	t = _decoder_starts(176400, DOP, 40000);
	UNLOCK;
	start_output();
	for (int i = 0; i < 1000 && trk[t].played < 2000; i++) tick();
	CHECK(trk[t].played >= 2000, "control: the second DoP track did not play");
	strm_p();
	run_ioproc();
	CHECK(frames_of(K_DOPSIL) == io_frames, "%u of %u frames DoP silence in a pause inside a DoP track", frames_of(K_DOPSIL),
		  io_frames);
	stop();
}

// LIVE TEST of 0.2.9, 2026-10-11 (output tap, FiiO): the IOProc's last call before the idle release
// closes the device was left zero, 512 frames of PCM after DoP silence at 176.4k, so a DoP DAC lost
// its lock just before the stream stopped. Upstream's PortAudio callback still calls _output_frames
// while off, which plays silence in the format of what played. After PCM: zeros, as before.
static void the_idle_release_keeps_the_silence_of_what_played_to_the_close(void) {
	fdev *d = add_dac();
	start(d->uid, "0:1", IDLE_MS, false, false);
	play_track(176400, DOP, 4000);            // to its end: stopped, the device still at 176.4k
	CHECK(device_open() && d->rate == 176400, "control: not at 176400 (%.0f Hz)", d->rate);
	advance_ms(IDLE_MS + 1000);
	controller();                             // the idle timeout
	CHECK(output_state_now() == OUTPUT_OFF && device_open(), "control: not off with the device still open");
	run_ioproc();                             // the call that asks for the close
	CHECK(frames_of(K_DOPSIL) == io_frames, "%u of %u frames DoP silence in the last call before the idle release "
		  "after DoP (%u zero)", frames_of(K_DOPSIL), io_frames, frames_of(K_ZERO));
	controller();
	CHECK(!device_open(), "control: the idle release did not close the device");

	play_track(44100, PCM, 4000);
	CHECK(device_open() && d->rate == 44100, "control: not at 44100 (%.0f Hz)", d->rate);
	advance_ms(IDLE_MS + 1000);
	controller();
	CHECK(output_state_now() == OUTPUT_OFF && device_open(), "control: not off with the device still open (PCM)");
	run_ioproc();
	CHECK(frames_of(K_ZERO) == io_frames, "%u of %u frames zero in the last call before the idle release after PCM",
		  frames_of(K_ZERO), io_frames);
	controller();
	CHECK(!device_open(), "control: the idle release did not close the device (PCM)");
	stop();
}

// a play from idle into DoP opens at the DoP rate: its buffering is already DoP silence, so the DAC
// locks before the music, as upstream does on a device that stays at that rate
static void a_play_from_idle_into_dop_buffers_in_dop_silence(void) {
	fdev *d = add_dac();
	start(d->uid, "0:1", IDLE_MS, false, false);   // the last track was 44.1k PCM (none yet)
	play_from_idle_fmt(176400, DOP, true);
	open_device();
	CHECK(device_open() && d->rate == 176400, "control: not opened at the DoP rate (%.0f Hz)", d->rate);
	run_ioproc();
	CHECK(frames_of(K_DOPSIL) == io_frames, "%u of %u frames DoP silence while the DoP track buffered at its rate",
		  frames_of(K_DOPSIL), io_frames);
	stop();
}

// /code-review 2026-10-11 (2), finding 2: _silence_fmt took outfmt whenever the device was at the
// current rate, so a play from idle at the LAST track's rate in the other format buffered in the
// last track's format: DoP silence before a PCM track (here a 176.4k album after DSD64)
static void a_play_from_idle_after_dop_at_its_rate_buffers_in_pcm_silence(void) {
	fdev *d = add_dac();
	start(d->uid, "0:1", IDLE_MS, false, false);
	play_track(176400, DOP, 4000);
	idle_release();
	play_from_idle_fmt(176400, PCM, true);    // a 176.4k PCM album
	open_device();
	CHECK(device_open() && d->rate == 176400, "control: not opened at 176400 (%.0f Hz)", d->rate);
	run_ioproc();
	CHECK(frames_of(K_ZERO) == io_frames, "%u of %u frames DoP silence while a PCM track buffered: DoP silence before it",
		  frames_of(K_DOPSIL), io_frames);
	stop();
}

// the reverse: DSD64 from idle after a 176.4k PCM album buffered in PCM zeros, so the DAC locked to
// DSD only at the music
static void a_play_from_idle_into_dop_at_the_last_rate_buffers_in_dop_silence(void) {
	fdev *d = add_dac();
	start(d->uid, "0:1", IDLE_MS, false, false);
	play_track(176400, PCM, 4000);            // a 176.4k PCM album
	idle_release();
	play_from_idle_fmt(176400, DOP, true);
	open_device();
	CHECK(device_open() && d->rate == 176400 && d->rate_changes == 1, "control: not opened at 176400 with no switch (%.0f Hz, %u)",
		  d->rate, d->rate_changes);
	run_ioproc();
	CHECK(frames_of(K_DOPSIL) == io_frames, "%u of %u frames zeros, not DoP silence, while the DoP track buffered at the last rate",
		  frames_of(K_ZERO), io_frames);
	stop();
}

// the same on a synced start (LMS sync group: autostart 0, then strm u at a time): the output goes
// from off straight to waiting for the start time (OUTPUT_START_AT, never OUTPUT_BUFFER), and
// output.c plays silence through write_cb while it waits
static void a_synced_start_waits_in_the_pending_tracks_format(void) {
	fdev *d = add_dac();
	start(d->uid, "0:1", IDLE_MS, false, false);
	play_track(176400, DOP, 4000);            // DSD64 as DoP
	idle_release();
	strm_q();
	strm_s(1);                                // autostart 0: decoding starts, the output stays off
	LOCK;
	_decoder_starts(176400, PCM, 4000);       // a 176.4k PCM album, decoded while it waits
	UNLOCK;
	decoder_done = true;
	strm_u(gettime_ms() + 1000);
	open_device();
	CHECK(device_open() && d->rate == 176400, "control: not opened at 176400 (%.0f Hz)", d->rate);
	run_ioproc();
	CHECK(output.state == OUTPUT_START_AT, "control: not waiting to start (state %d)", output.state);
	CHECK(frames_of(K_ZERO) == io_frames, "%u of %u frames DoP silence while a synced PCM track waited to start",
		  frames_of(K_DOPSIL), io_frames);
	stop();
}

// pins the rate half of the rule _silence_fmt shares (_at_pending_rate, /code-review 2026-10-11 (2)
// finding 6): a decoder slower than the 150 ms wait leaves the device at the LAST track's rate
// while the pending DoP track buffers, and DoP silence there would be played as PCM
static void a_slow_decoder_into_dop_buffers_in_pcm_at_the_last_rate(void) {
	fdev *d = add_dac();
	start(d->uid, "0:1", IDLE_MS, false, false);   // the last track was 44.1k PCM (none yet)
	play_from_idle_fmt(176400, DOP, false);   // DSD64; the decoder has not found it yet
	open_device();
	CHECK(device_open() && d->rate == 44100, "control: opened at %.0f Hz, not the last rate 44100", d->rate);
	LOCK;
	_decoder_starts(176400, DOP, 1);          // found after the open, still buffering
	UNLOCK;
	run_ioproc();
	CHECK(!output.ca_reopen, "control: a reopen while it buffered");
	CHECK(frames_of(K_ZERO) == io_frames, "%u of %u frames DoP silence while buffering at 44.1k before a DoP track",
		  frames_of(K_DOPSIL), io_frames);
	stop();
}

// /code-review 2026-10-11 (2), finding 4: the fake played output.c's pause frames (the rate delay)
// without write_cb, so the silence format during a delay was never seen. Between two DoP tracks
// both halves must be DoP silence, or the DAC drops out of DSD mode inside the silence meant to
// cover its relock (DSD64 -> DSD128, gapless, "Silence on a rate change" 2000 ms)
static void the_rate_delay_between_dop_tracks_is_dop_silence(void) {
	fdev *d = add_dac();
	unsigned a, b, dop = 0, other = 0;
	bool between = false;
	d->rates[5] = 352800;                     // DSD128 as DoP
	d->nrates = 6;
	start_rate_delay = 2000;
	start(d->uid, "0:1", IDLE_MS, false, false);
	strm_q();
	strm_s(1);
	LOCK;
	a = _decoder_starts(176400, DOP, 44100);  // DSD64, 1/4 s
	UNLOCK;
	start_output();
	for (int i = 0; i < 1000 && !trk[a].played; i++) {
		if (!device_open()) open_device();
		tick();
	}
	LOCK;
	b = _decoder_starts(352800, DOP, 4000);   // then DSD128, gapless
	UNLOCK;
	decoder_done = true;
	for (int i = 0; i < 20000 && trk[b].played < trk[b].written; i++) {
		if (!device_open()) open_device();
		tick();
	}
	CHECK(trk[a].played == trk[a].written && trk[b].played == trk[b].written, "control: not both played (%u/%u, %u/%u)",
		  trk[a].played, trk[a].written, trk[b].played, trk[b].written);
	CHECK(d->rate == 352800, "control: at %.0f Hz, not 352800", d->rate);
	// every frame between DSD64's last and DSD128's first, but for the IOProc's unfilled rest of the
	// call that asked for the reopen (THE BOUNDARY AND THE REOPEN FLAG)
	for (unsigned i = 0; i < nsegs; i++) {
		struct seg *s = &segs[i];
		if (s->kind == K_DOP && s->track == a) {
			between = true;
			dop = other = 0;
		} else if (s->kind == K_DOP && s->track == b) {
			break;
		} else if (between) {
			if (s->kind == K_DOPSIL) dop += s->frames;
			else if (!(s->tail && ticks[s->tick].reopen)) other += s->frames;
		}
	}
	CHECK(dop > 0 && other == 0, "%u frames between the DoP tracks were not DoP silence (%u were)", other, dop);
	CHECK(fabs(silence_s - 2.0) < 0.01, "%.2f s of silence between them, not 2.00 (1 before the switch, 1 after)", silence_s);
	stop();
}

// /code-review 2026-10-11, finding 2: the mark that the open made the switch was set once, in the
// open; a stop or a new album while the first one buffers (strm q: output_flush clears the mark)
// left the device at the new rate with no mark, and the next start stretched the first half again
// (96k -> 44.1k: 2.18 s + 1 s)
static void the_rate_delay_is_not_stretched_after_a_flush_while_buffering(void) {
	fdev *d = add_dac();
	d->rate = 96000;
	start_rate_delay = 2000;
	start(d->uid, "0:1", 30, false, false);
	LOCK;
	output.current_sample_rate = 96000;       // the last track was 96 kHz
	UNLOCK;
	play_from_idle(44100, true);
	WAIT_FOR(d->started == 1);
	CHECK(d->started == 1 && d->rate == 44100, "control: not opened at the track's 44100 (%.0f Hz)", d->rate);
	run_ioproc();                             // buffering
	strm_q();                                  // the user picks another 44.1k album
	run_ioproc();
	play_from_idle(44100, true);              // its stream: same rate, the device stays open
	run_ioproc();
	CHECK(!output.ca_reopen && d->started == 1, "control: the device did not stay open at 44100");
	output.state = OUTPUT_RUNNING;
	CHECK(play_through_the_track_start() && !output.ca_reopen, "control: no clean track start");
	CHECK(fabs(silence_s - 1.0) < 0.01, "%.2f s of silence before the music, not the 1.00 s after the switch", silence_s);
	stop();
}

// /code-review 2026-10-11, finding 3: the mark was set in the open from the track it chose BEFORE
// its unlocked device calls. A stop meanwhile (strm q: output_flush clears the mark, empties the
// buffer, leaves track_start and the old rate) had it set again on relocking, by the flushed
// track; the next album at the last rate took no delay, so nothing took the mark, and a later
// gapless rate change skipped its silence before the switch
static void a_stop_during_the_open(void) {
	strm_q();
}
static void a_stop_during_the_open_leaves_no_rate_delay_mark(void) {
	fdev *d = add_dac();
	d->rate = 48000;
	start_rate_delay = 2000;
	start(d->uid, "0:1", 30, false, false);   // the last track was 44.1 kHz
	during_next_rate_change = a_stop_during_the_open;
	play_from_idle(96000, true);
	WAIT_FOR(d->started == 1);
	CHECK(d->started == 1 && d->rate == 96000, "control: not opened at 96000 (%.0f Hz)", d->rate);
	run_ioproc();
	LOCK;
	_decoder_finds(44100);                    // the next album, at the last track's 44.1 kHz
	output.state = OUTPUT_BUFFER;
	UNLOCK;
	run_ioproc();
	if (output.ca_reopen) {
		output.ca_reopen = false;
		reopen();
	}
	CHECK(d->rate == 44100, "control: at %.0f Hz for the 44.1k album", d->rate);
	output.state = OUTPUT_RUNNING;
	CHECK(play_through_the_track_start() && !output.ca_reopen && output.current_sample_rate == 44100,
		  "control: no clean start of the 44.1k album");
	silence_s = 0;
	LOCK;
	_decoder_finds(96000);                    // later, a gapless 44.1 -> 96 kHz boundary
	UNLOCK;
	CHECK(play_through_the_track_start() && output.ca_reopen, "control: no reopen at the boundary");
	CHECK(fabs(silence_s - 1.0) < 0.01, "%.2f s of silence before the switch, not 1.00", silence_s);
	stop();
}

// the same leftover track_start, from idle: a stop while an album buffered, the idle release, then
// a play. LMS flushes and starts the new stream, and the monitor saw the flushed track as the
// pending one: it opened at that track's rate without waiting, and the new track reopened
static void a_play_after_a_stop_while_buffering_opens_at_its_own_rate(void) {
	fdev *d = add_dac();
	usleep_div = 1;
	start(d->uid, "0:1", 30, false, false);
	LOCK;
	output.threshold = 20;
	_decoder_finds(96000);                    // an album that was stopped while it buffered:
	UNLOCK;
	strm_q();                                 // flushed (the output is off), its track_start and rate left
	start_output();                           // the next play; its decoder has not found the rate
	WAIT_FOR(atomic_load(&track_waits) >= 2 || d->started);
	CHECK(d->started == 0, "opened at %.0f Hz, the stopped album's rate, before the new track was found", d->rate);
	LOCK;
	_decoder_finds(48000);
	UNLOCK;
	WAIT_FOR(d->started == 1);
	CHECK(d->started == 1 && d->rate == 48000 && d->rate_changes == 1, "at %.0f Hz after %u changes, not 48000 after 1",
		  d->rate, d->rate_changes);
	stop();
}

// ---------------------------------------------------------------------------------------------
// The scenario matrix
//
// Each scenario plays, through LMS's strm commands as slimproto.c runs them: a last track (or
// none), then the device kept open or let go by the idle timeout, then a play of the next track,
// with the decoder finding it before the monitor looks, during the monitor's wait, or after it
// gave up and opened; with or without an interruption (a stop, a new album, a pause) at one point
// of the play, a rate delay, a gapless follower or a synced start. Every frame the device gets is
// then checked against the invariants below, which say what a listener would notice, not how the
// engine decides it.

enum { C44, C96, C176, D64, D128, NCAT };
static const struct { const char *name; unsigned rate; dsd_format fmt; } cat[NCAT] = {
	{ "44.1k PCM", 44100, PCM }, { "96k PCM", 96000, PCM }, { "176.4k PCM", 176400, PCM },
	{ "DSD64 as DoP", 176400, DOP }, { "DSD128 as DoP", 352800, DOP },
};
enum { GAP_KEPT, GAP_RELEASED, GAP_MOVED }; // the device kept open; let go; let go, and another app set it to 48 kHz
enum { DEC_EARLY, DEC_WAIT, DEC_LATE };
enum { I_NONE, I_STOP, I_ALBUM, I_PAUSE, I_SYNC, I_STOP_ALBUM, I_STOP_IDLE_ALBUM };
enum { AT_A, AT_B, AT_C, AT_D, AT_E };
static const char *at_name[] = { "before the monitor's next look", "during its wait for the decoder", "inside the open",
								 "while it buffers", "once it plays" };
struct scen { int prev, gap, next, dec, intr, at, album, delay, follow, slow; };

static void describe(const struct scen *s, char *buf, size_t len) {
	static const char *dec[] = { "the decoder first", "the decoder during the monitor's wait", "the decoder after the open" };
	char intr[96] = "";
	if (s->intr == I_STOP) snprintf(intr, sizeof(intr), ", a stop %s", at_name[s->at]);
	if (s->intr == I_ALBUM) snprintf(intr, sizeof(intr), ", a new album (%s) %s", cat[s->album].name, at_name[s->at]);
	if (s->intr == I_PAUSE) snprintf(intr, sizeof(intr), ", a pause and resume once it plays");
	if (s->intr == I_STOP_ALBUM || s->intr == I_STOP_IDLE_ALBUM) {
		snprintf(intr, sizeof(intr), ", a stop %s, then%s a new album (%s)", at_name[s->at],
				 s->intr == I_STOP_IDLE_ALBUM ? ", after the idle release," : "", cat[s->album].name);
	}
	snprintf(buf, len, "%s%s%s, %s %s, %s%s%s%s%s", s->prev < 0 ? "fresh" : "after ", s->prev < 0 ? "" : cat[s->prev].name,
			 s->gap == GAP_MOVED ? " (the DAC since set to 48 kHz by another app)" : s->prev < 0 ? "" :
			 s->gap == GAP_KEPT ? " (device kept)" : " (device let go)",
			 s->intr == I_SYNC ? "a synced start of" : "play", cat[s->next].name,
			 s->intr == I_SYNC ? "decoded first" : dec[s->dec], intr, s->follow >= 0 ? ", then gapless " : "",
			 s->follow >= 0 ? cat[s->follow].name : "", s->delay ? ", rate delay 200 ms" : "");
	if (s->slow) strncat(buf, ", a slow stream", len - strlen(buf) - 1);
}

#define MAXSCEN 40000
static unsigned make_scenarios(struct scen *out) {
	unsigned n = 0;
	for (int prev = -1; prev < NCAT; prev++) {
		for (int gap = prev < 0 ? GAP_RELEASED : GAP_KEPT; gap <= GAP_MOVED; gap++) {
			for (int next = 0; next < NCAT; next++) {
				for (int delay = 0; delay <= 200; delay += 200) {
					struct scen b = { prev, gap, next, DEC_EARLY, I_NONE, AT_A, -1, delay, -1, 0 };
					out[n] = b;
					out[n++].intr = I_SYNC;
					for (int slow = 0; slow <= 1; slow++)
					for (int dec = DEC_EARLY; dec <= DEC_LATE; dec++) {
						b.slow = slow;
						if (gap == GAP_KEPT && dec == DEC_WAIT) continue; // no monitor: the decoder is early or late
						b.dec = dec;
						out[n++] = b;
						if (gap == GAP_MOVED) continue;                 // that gap matters for the open's rate only
						int followers[2] = { (next + 1) % NCAT, (next + 3) % NCAT };
						for (int f = 0; f < 2; f++) {
							out[n] = b;
							out[n++].follow = followers[f];
						}
						for (int at = AT_A; at <= AT_E; at++) {
							if (at == AT_B && (gap == GAP_KEPT || dec == DEC_EARLY)) continue; // the monitor waits only for a late decoder
							if (at == AT_C && gap == GAP_KEPT) continue;                     // no open by the monitor
							out[n] = b;
							out[n].intr = I_STOP;
							out[n++].at = at;
							if (at == AT_E) continue;
							int albums[3] = { C44, C176, D64 };
							for (int a = 0; a < 3; a++) { // a stop, then a new album (with or without the idle
								out[n] = b;                // release between) and a gapless track after it
								out[n].intr = I_STOP_ALBUM;
								out[n].at = at;
								out[n].album = albums[a];
								out[n++].follow = (albums[a] + 1) % NCAT;
								out[n] = out[n - 1];
								out[n++].intr = I_STOP_IDLE_ALBUM;
							}
							for (int a = 0; a < 3; a++) {
								out[n] = b;
								out[n].intr = I_ALBUM;
								out[n].at = at;
								out[n++].album = albums[a];
								out[n] = out[n - 1];         // and a gapless track after it, at another rate
								out[n++].follow = (albums[a] + 1) % NCAT;
							}
						}
						out[n] = b;
						out[n].intr = I_PAUSE;
						out[n++].at = AT_E;
						if (n > MAXSCEN - 100) abort();  // the table outgrew MAXSCEN
					}
				}
			}
		}
	}
	return n;
}

static struct scen S;                     // the scenario this child plays
static unsigned t_next, t_lead;           // the next track; the one a gapless follower follows
static bool interrupted;

static unsigned frames_for(int c) { return cat[c].rate / 4; } // 1/4 s

// the decoder finds a track of the catalogue: all of it at once, or, from a slow stream, 25 ms of
// it per IOProc call (decoder_tick); the stream has ended once all of it is written
static bool follow_queued;
static unsigned decode(int c) {
	unsigned t;
	LOCK;
	t = _decoder_starts(cat[c].rate, cat[c].fmt, S.slow ? cat[c].rate / 40 : frames_for(c));
	trk[t].target = frames_for(c);
	UNLOCK;
	decoder_done = !S.slow && !follow_queued;
	return t;
}
static void decoder_tick(void) {
	if (!S.slow || !dec_track || trk[dec_track].flushed) return;
	LOCK;
	if (trk[dec_track].written < trk[dec_track].target) {
		unsigned left = trk[dec_track].target - trk[dec_track].written, chunk = trk[dec_track].rate / 40;
		_decoder_writes(left < chunk ? left : chunk);
	}
	UNLOCK;
	if (trk[dec_track].written >= trk[dec_track].target && !follow_queued) decoder_done = true;
}

// the decoder finds the next track (a follower is streamed once it has been decoded and has
// started, as LMS streams the next track)
static void decode_next(void) {
	follow_queued = S.follow >= 0 && S.intr != I_ALBUM && S.intr != I_STOP_ALBUM && S.intr != I_STOP_IDLE_ALBUM;
	t_lead = t_next = decode(S.next);
}

// the interruption; at AT_C it runs on the monitor's thread, inside the open
static void event(void) {
	interrupted = true;
	if (S.intr == I_STOP || S.intr == I_STOP_ALBUM || S.intr == I_STOP_IDLE_ALBUM) {
		strm_q();
	} else if (S.intr == I_ALBUM) {
		strm_q();
		strm_s(1);
		follow_queued = S.follow >= 0;
		t_lead = decode(S.album);
		start_output();
	} else if (S.intr == I_PAUSE) {
		strm_p();
		for (int i = 0; i < 4; i++) tick();
		strm_u(0);
	}
}

static bool all_played(void) {
	for (unsigned t = 1; t <= ntrk; t++) if (!trk[t].flushed && trk[t].played < trk[t].target) return false;
	return true;
}

// the first failure of each invariant, so one scenario can show several
static char whyc[9][200], why[1100];
static unsigned check_no;
#define FAIL(...) do { if (!whyc[check_no][0]) snprintf(whyc[check_no], sizeof(whyc[0]), __VA_ARGS__); } while (0)

static bool dop_rate(unsigned rate) {
	for (unsigned t = 1; t <= ntrk; t++) if (trk[t].fmt != PCM && trk[t].rate == rate) return true;
	return false;
}
static enum kind silence_of(unsigned t) { return trk[t].fmt == PCM ? K_ZERO : K_DOPSIL; }
static bool is_music(enum kind k) { return k == K_PCM || k == K_DOP; }
// the zeros after the last frame of the old rate, in the call that asks for the rate switch (upstream
// pads there too); not the call before an idle release, which is silence of what played (as upstream's
// _output_frames gives while off; LIVE TEST of 0.2.9 found it zero)
static bool boundary_pad(const struct seg *s) { return s->tail && ticks[s->tick].reopen && !ticks[s->tick].off; }

static unsigned rate_changes_at_play;

static void check_invariants(void) {
	check_no = 1;
	// 1. nothing but music, DSD silence under DoP markers, and zeros; DoP silence only at a rate a
	// DoP track of the scenario plays at (anywhere else the DAC plays it as PCM: a square wave at
	// Nyquist, ~-27 dBFS); music only at its own rate, in its own format
	for (unsigned i = 0; i < nsegs; i++) {
		struct seg *s = &segs[i];
		if (s->kind == K_JUNK) FAIL("%u frames that are neither music nor silence at %u Hz (call %u)", s->frames, s->rate, s->tick);
		if (s->kind == K_DOPSIL && !dop_rate(s->rate)) {
			FAIL("%u frames of DoP silence at %u Hz, a rate no DoP track plays at (call %u)", s->frames, s->rate, s->tick);
		}
		if (is_music(s->kind) && s->rate != trk[s->track].rate) {
			FAIL("track %u (%u Hz) played at %u Hz (call %u)", s->track, trk[s->track].rate, s->rate, s->tick);
		}
		if (is_music(s->kind) && (s->kind == K_DOP) != (trk[s->track].fmt != PCM)) {
			FAIL("track %u played as %s (call %u)", s->track, kind_name[s->kind], s->tick);
		}
	}
	check_no = 2;
	// 2. every track in order, none twice, and all of it unless it was stopped
	for (unsigned t = 1; t <= ntrk; t++) {
		if (trk[t].misorder) FAIL("track %u: %u frames out of order", t, trk[t].misorder);
		if (trk[t].played > trk[t].written) FAIL("track %u: %u frames played of %u written", t, trk[t].played, trk[t].written);
		if (!trk[t].flushed && trk[t].played != trk[t].target) {
			FAIL("track %u (%u Hz %s) not stopped, but %u of its %u frames played", t, trk[t].rate,
				 trk[t].fmt == PCM ? "PCM" : "DoP", trk[t].played, trk[t].target);
		}
	}
	check_no = 3;
	// 3. inside a track, in one run of the device (a pause, an underrun): its own silence, so a
	// DoP track keeps the DAC locked and a PCM track gets zeros
	for (unsigned t = 1; t <= ntrk; t++) {
		for (unsigned i = 0; i < nsegs; i++) {
			if (!(is_music(segs[i].kind) && segs[i].track == t)) continue;
			unsigned j = i + 1, last = i;
			for (unsigned k = j; k < nsegs && segs[k].run == segs[i].run; k++) {
				if (is_music(segs[k].kind) && segs[k].track == t) last = k;
				if (is_music(segs[k].kind) && segs[k].track != t) break;
			}
			for (unsigned k = j; k < last; k++) {
				if (!is_music(segs[k].kind) && segs[k].kind != silence_of(t)) {
					FAIL("%u frames of %s inside track %u (%s) at %u Hz (call %u)", segs[k].frames, kind_name[segs[k].kind], t,
						 trk[t].fmt == PCM ? "PCM" : "DoP", segs[k].rate, segs[k].tick);
				}
			}
			i = last;
		}
	}
	check_no = 4;
	// 4. after a track, in the same run, until another is due: its silence (upstream keeps a DoP
	// DAC locked after a stop; a PCM track is followed by zeros)
	{
		unsigned last = 0, run = 0;
		bool due = false;
		for (unsigned i = 0; i < nsegs; i++) {
			struct seg *s = &segs[i];
			if (s->run != run) {
				run = s->run;
				last = 0;
				due = false;
			}
			if (is_music(s->kind)) {
				last = s->track;
				due = false;
				continue;
			}
			if (ticks[s->tick].pend || ticks[s->tick].started) due = true;
			if (!last || due || boundary_pad(s)) continue;
			if (s->kind != silence_of(last)) {
				FAIL("%u frames of %s after track %u (%s) at %u Hz, nothing else due yet (call %u)", s->frames, kind_name[s->kind],
					 last, trk[last].fmt == PCM ? "PCM" : "DoP", s->rate, s->tick);
			}
		}
	}
	check_no = 5;
	// 5. before a track: once its start is the next frame at the device's rate, or output.c has
	// taken its start (the delay's second half), its silence, so the DAC is in the right mode for
	// the music
	for (unsigned i = 0; i < nsegs; i++) {
		struct seg *s = &segs[i];
		unsigned p = ticks[s->tick].pend;
		if (is_music(s->kind) || boundary_pad(s)) continue;
		if (p && s->kind != silence_of(p)) {
			FAIL("%u frames of %s at %u Hz while track %u (%s) was due at that rate (call %u)", s->frames, kind_name[s->kind],
				 s->rate, p, trk[p].fmt == PCM ? "PCM" : "DoP", s->tick);
		}
		for (unsigned t = 1; t <= ntrk; t++) {
			if (trk[t].started && trk[t].played && s->tick > trk[t].start_tick && s->tick < trk[t].first_tick &&
				s->kind != silence_of(t)) {
				FAIL("%u frames of %s at %u Hz after track %u (%s) started, before its music (call %u)", s->frames,
					 kind_name[s->kind], s->rate, t, trk[t].fmt == PCM ? "PCM" : "DoP", s->tick);
			}
		}
	}
	check_no = 6;
	// 6. the delay ("Silence on a rate change"): never longer than set, from one track's music to the
	// next's; between gapless tracks at two rates in one format, all of it (half before the switch,
	// half after)
	for (unsigned a = 1; a <= ntrk; a++) {
		unsigned b = 0, last_a = 0;
		if (!trk[a].played) continue;
		for (unsigned t = 1; t <= ntrk; t++) {
			if (trk[t].played && trk[t].first_tick > trk[a].first_tick && (!b || trk[t].first_tick < trk[b].first_tick)) b = t;
		}
		if (!b) continue;
		for (unsigned i = 0; i < nsegs; i++) if (is_music(segs[i].kind) && segs[i].track == a) last_a = segs[i].tick;
		// a strm q in between (a stop, a new album) restarts the delay, as output.c's flush does
		for (unsigned f = 0; f < nflush; f++) if (flush_ticks[f] > last_a && flush_ticks[f] <= trk[b].first_tick) last_a = flush_ticks[f];
		double pause = 0;
		for (unsigned k = last_a; k <= trk[b].first_tick && k < nticks; k++) pause += ticks[k].pause_s;
		if (pause > S.delay / 1000.0 + 0.002) {
			FAIL("%.3f s of delay silence between track %u (%u Hz) and track %u (%u Hz), more than the %d ms set", pause, a,
				 trk[a].rate, b, trk[b].rate, S.delay);
		}
		bool gapless = S.follow >= 0 && trk[b].rate == cat[S.follow].rate && trk[b].fmt == cat[S.follow].fmt && b == ntrk;
		if (gapless && S.delay && trk[a].rate != trk[b].rate && trk[a].fmt == trk[b].fmt && fabs(pause - S.delay / 1000.0) > 0.002) {
			FAIL("%.3f s of delay silence between gapless tracks %u (%u Hz) and %u (%u Hz), not the %d ms set", pause, a,
				 trk[a].rate, b, trk[b].rate, S.delay);
		}
	}
	check_no = 7;
	// 7. one rate switch for a play whose decoder found the track before the monitor opened (two
	// when it did not), plus one for a gapless follower at another rate
	if (S.intr == I_NONE || S.intr == I_PAUSE || S.intr == I_SYNC) {
		fdev *d = &devs[0];
		unsigned allowed = (S.intr != I_SYNC && S.dec == DEC_LATE ? 2 : 1) + (S.follow >= 0);
		if (d->rate_changes - rate_changes_at_play > allowed) {
			FAIL("%u rate switches for the play, not at most %u", d->rate_changes - rate_changes_at_play, allowed);
		}
	}
	check_no = 0;
	// 0. the scenario ran as described: its next track was decoded unless something replaced it
	if (!t_next && !interrupted) FAIL("the next track was never decoded: the scenario did not run as described");
	check_no = 8;
	// 8. no wasted switch: a reopen the IOProc asked for goes to the rate of the track it just started,
	// or of one then due or played (a reopen for the output going off closes the device: no new run)
	for (unsigned k = 1; k < nticks && k < MAXTICK; k++) {
		if (!ticks[k - 1].reopen || ticks[k].run == ticks[k - 1].run || ticks[k].after_close) continue;
		// a reopen for the track whose start output.c just took is used, whatever comes after it
		bool used = ticks[k - 1].started && trk[ticks[k - 1].started].rate == ticks[k].rate;
		for (unsigned j = k; j < nticks && j < MAXTICK && ticks[j].run == ticks[k].run && !used; j++) {
			used = ticks[j].pend || ticks[j].started;
		}
		for (unsigned i = 0; i < nsegs && !used; i++) used = segs[i].run == ticks[k].run && is_music(segs[i].kind);
		if (!used) FAIL("the device was switched to %u Hz (call %u), where no track was then due or played", ticks[k].rate, k);
	}
	for (unsigned c = 0; c < 9; c++) {
		if (!whyc[c][0]) continue;
		if (why[0]) strncat(why, "\n        ", sizeof(why) - strlen(why) - 1);
		strncat(why, whyc[c], sizeof(why) - strlen(why) - 1);
	}
}

static void run_scenario(void) {
	fdev *d = add_dac();
	unsigned r[] = { 44100, 48000, 88200, 96000, 176400, 192000, 352800 };
	bool done_e = false;
	for (unsigned i = 0; i < 7; i++) d->rates[i] = r[i];
	d->nrates = 7;
	io_frames = 1024;
	start_rate_delay = S.delay;
	gate_monitor = true;
	start(d->uid, "0:1", IDLE_MS, false, false);
	monitor_settle();                         // parked in its first look, the output off
	if (S.prev >= 0) {
		play_track(cat[S.prev].rate, cat[S.prev].fmt, frames_for(S.prev));
		if (S.gap != GAP_KEPT) idle_release();
		else for (int i = 0; i < 3; i++) tick();
	}
	if (S.gap == GAP_MOVED) d->rate = 48000;  // no track of the catalogue is at 48 kHz
	rate_changes_at_play = d->rate_changes;
	strm_q();
	strm_s(1);
	if (S.intr == I_SYNC) {
		decode_next();                        // autostart 0: decoded while the output waits
		strm_u(gettime_ms() + 200);
	} else {
		if (S.dec == DEC_EARLY) decode_next();
		start_output();
		if (S.intr && S.at == AT_A) event();
		if (!device_open()) {
			if (S.intr && S.at == AT_C) during_next_ioproc_create = event;
			monitor_step();                   // its look: the output is on
			if (!device_open() && S.dec == DEC_WAIT) {
				monitor_step();               // one look of its wait for the decoder
				if (S.intr && S.at == AT_B) event();
				if (!interrupted) decode_next();
			} else if (!device_open() && S.dec == DEC_LATE && S.intr && S.at == AT_B) {
				monitor_step();
				event();
			}
			open_device();
			during_next_ioproc_create = NULL;
			if (S.dec == DEC_WAIT && !t_next && !interrupted) decode_next(); // it opened without waiting
		}
		if (S.dec == DEC_LATE && !interrupted) {
			tick();
			tick();
			decode_next();
		}
		if (S.intr && S.at == AT_D) {
			decoder_tick();
			tick();
			event();
		}
		if ((S.intr == I_STOP_ALBUM || S.intr == I_STOP_IDLE_ALBUM) && S.at != AT_E) { // the user picks another album
			if (!device_open() && output_state_now() != OUTPUT_OFF) open_device();
			tick();
			tick();
			if (S.intr == I_STOP_IDLE_ALBUM) idle_release();
			strm_q();
			strm_s(1);
			follow_queued = S.follow >= 0;
			t_lead = decode(S.album);
			start_output();
		}
	}
	for (int i = 0, quiet = 0; i < 8000 && quiet < 6; i++) {
		if (!device_open()) {
			if (output_state_now() == OUTPUT_OFF) break;
			open_device();
			if (!device_open()) break;
		}
		decoder_tick();
		tick();
		if (S.intr && S.at == AT_E && !done_e && t_next && trk[t_next].played >= 2048) {
			done_e = true;
			event();
		}
		if (follow_queued && t_lead && trk[t_lead].started && trk[t_lead].written >= trk[t_lead].target) {
			follow_queued = false;
			decode(S.follow);
		}
		quiet = all_played() && output_state_now() == OUTPUT_STOPPED ? quiet + 1 : 0;
	}
	idle_release();
	check_invariants();
}

static void dump_segments(void) {
	unsigned tick = UINT_MAX;
	for (unsigned i = 0; i < nsegs; i++) {
		struct seg *s = &segs[i];
		if (s->tick != tick) {
			tick = s->tick;
			fprintf(stderr, "  call %u run %u %u Hz%s%s%s:", s->tick, s->run, s->rate,
					ticks[tick].pend ? " [due]" : "", ticks[tick].started ? " [start]" : "", ticks[tick].reopen ? " [reopen]" : "");
		}
		fprintf(stderr, " %u %s%s%s", s->frames, kind_name[s->kind], is_music(s->kind) ? "" : "", s->tail ? " (unfilled)" : "");
		if (is_music(s->kind)) fprintf(stderr, " #%u", s->track);
		if (i + 1 == nsegs || segs[i + 1].tick != tick) fprintf(stderr, "\n");
	}
}

// MATRIX_SIG=<dir>: every scenario's frames, one file each (per segment: run, rate, kind, the
// track for music, frames, and a hash of every sample in it; then PASS or the failures), so two
// builds can be diffed scenario by scenario (`diff -rq`): a change shows every scenario whose output
// it changed, sample for sample, also those no invariant speaks of, so it cannot quietly change what
// already worked. Synced starts are timed by the clock, so they can slip a call, under the parallel
// run's load and now and then even alone (`THE MATRIX IS FRAME-EXACT BUT ONE`): a difference in one
// is the build's only if MATRIX_ONE reruns of both builds never give the same output. A signature
// that cannot be written fails its scenario, so an empty directory never diffs as "no change".
static void write_sig(unsigned idx) {
	char path[1024];
	int n = snprintf(path, sizeof(path), "%s/%u", getenv("MATRIX_SIG"), idx);
	FILE *f = n > 0 && (size_t)n < sizeof(path) ? fopen(path, "w") : NULL;
	bool ok = f != NULL;
	for (unsigned i = 0; ok && i < nsegs; i++) {
		fprintf(f, "%u %u %s", segs[i].run, segs[i].rate, kind_name[segs[i].kind]);
		if (is_music(segs[i].kind)) fprintf(f, " #%u", segs[i].track);
		fprintf(f, " %u %08x%s%s\n", segs[i].frames, segs[i].hash, segs[i].tail ? " tail" : "",
				ticks[segs[i].tick].off ? " off" : "");
	}
	if (ok) fprintf(f, "%s\n", why[0] ? why : "PASS");
	if (f && (ferror(f) | fclose(f))) ok = false;
	if (!ok) {
		int len = (int)strlen(why);
		snprintf(why + len, sizeof(why) - len, "%ssignature not written: %s: %s", len ? "\n        " : "", path,
				 (size_t)n < sizeof(path) ? strerror(errno) : "path too long");
	}
}

// MATRIX_SIG must name a directory this run can write, before any scenario runs
static bool sig_dir_ok(void) {
	const char *dir = getenv("MATRIX_SIG");
	struct stat st;
	if (!dir || (stat(dir, &st) == 0 && S_ISDIR(st.st_mode) && access(dir, W_OK) == 0)) return true;
	fprintf(stderr, "    MATRIX_SIG=%s is not a directory this run can write\n", dir);
	return false;
}

static void matrix(void) {
	static struct scen all[MAXSCEN];
	unsigned n = make_scenarios(all), bad = 0, shown = 0, done = 0, started = 0, slots;
	const char *one = getenv("MATRIX_ONE"), *find = getenv("MATRIX_FIND");
	char desc[300];
	if (find) {                               // lists the scenarios whose description contains it
		for (unsigned i = 0; i < n; i++) {
			describe(&all[i], desc, sizeof(desc));
			if (strstr(desc, find)) fprintf(stderr, "    %u: %s\n", i, desc);
		}
		return;
	}
	if (!sig_dir_ok()) {
		failed = true;
		return;
	}
	if (one) {
		S = all[atoi(one)];
		describe(&S, desc, sizeof(desc));
		fprintf(stderr, "    scenario %s: %s\n", one, desc);
		run_scenario();
		if (getenv("MATRIX_SIG")) write_sig((unsigned)atoi(one));
		if (getenv("VERBOSE")) dump_segments();
		if (why[0]) fprintf(stderr, "    %s\n", why);
		failed = why[0] != 0;
		return;
	}
	struct { pid_t pid; int fd; unsigned idx; } slot[16] = { 0 };
	long cpus = sysconf(_SC_NPROCESSORS_ONLN);
	slots = cpus < 2 ? 2 : cpus > 16 ? 16 : (unsigned)cpus;
	while (done < n) {
		for (unsigned k = 0; k < slots && started < n; k++) {
			if (slot[k].pid) continue;
			int p[2];
			if (pipe(p)) continue;
			pid_t c = fork();
			if (c < 0) {                      // not started: tried again once a child exits
				close(p[0]);
				close(p[1]);
				break;
			}
			if (c == 0) {
				close(p[0]);
				alarm(20);
				S = all[started];
				run_scenario();
				if (getenv("MATRIX_SIG")) write_sig(started);
				if (why[0]) {
					char line[1600];
					describe(&S, desc, sizeof(desc));
					int len = snprintf(line, sizeof(line), "%u: %s\n        %s\n", started, desc, why);
					write(p[1], line, (size_t)len < sizeof(line) ? (size_t)len : sizeof(line) - 1);
				}
				_exit(why[0] ? 1 : 0);
			}
			close(p[1]);
			slot[k].pid = c;
			slot[k].fd = p[0];
			slot[k].idx = started++;
		}
		int status;
		pid_t c = waitpid(-1, &status, 0);
		if (c <= 0) {                         // no child to wait for (a fork failed with none running)
			usleep(100000);
			continue;
		}
		for (unsigned k = 0; k < slots; k++) {
			if (slot[k].pid != c) continue;
			char line[1600];
			ssize_t len = read(slot[k].fd, line, sizeof(line) - 1);
			close(slot[k].fd);
			bool ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
			if (!ok) {
				bad++;
				if (shown++ < 12 || getenv("MATRIX_ALL")) {
					if (len > 0) {
						line[len] = 0;
						fprintf(stderr, "    FAILED scenario %s", line);
					} else {
						describe(&all[slot[k].idx], desc, sizeof(desc));
						fprintf(stderr, "    FAILED scenario %u: %s\n        %s\n", slot[k].idx, desc,
								WIFSIGNALED(status) ? (WTERMSIG(status) == SIGALRM ? "hung" : "crashed") : "no reason given");
					}
				}
			}
			slot[k].pid = 0;
			done++;
		}
	}
	fprintf(stderr, "    matrix: %u scenarios, %u failed\n", n, bad);
	failed = bad != 0;
}

// ---------------------------------------------------------------------------------------------

static const struct { const char *name; void (*fn)(void); } tests[] = {
	{ "listener removed at exit while a call is running", listener_removed_at_exit_while_a_call_is_running },
	{ "listener moved to a new device while a call is running", listener_moved_to_a_new_device_while_a_call_is_running },
	{ "refused rate gives exclusive access back", refused_rate_gives_exclusive_access_back },
	{ "busy device plays within 5 s of being let go", busy_device_plays_within_5s_of_being_let_go },
	{ "busy device says why at first, then every 5 minutes", busy_device_says_why_at_first_then_every_5_minutes },
	{ "missing device is looked for every 2 s", missing_device_is_looked_for_every_2s },
	{ "LMS level reaches a device absent at init", lms_level_reaches_a_device_absent_at_init },
	{ "device absent at init is watched once open", device_absent_at_init_is_watched_once_open },
	{ "a newer level wins over one being applied", newer_level_wins_over_one_being_applied },
	{ "reports carry what the engine knows of LMS", reports_carry_lms_state },
	{ "fixed volume leaves the device alone", fixed_volume_leaves_the_device_alone },
	{ "own change with a coarse read-back is not reported", own_change_with_a_coarse_read_back_is_not_reported },
	{ "user change reported once, mute reported", user_change_reported_once_and_mute_reported },
	{ "linear mode reports nothing", linear_mode_reports_nothing },
	{ "exclusive released when the output goes off", exclusive_released_when_the_output_goes_off },
	{ "device follows the track rate", device_follows_the_track_rate },
	{ "close while the monitor opens leaves nothing running", close_while_the_monitor_opens_leaves_nothing_running },
	{ "close while the monitor starts the device stops it", close_while_the_monitor_starts_the_device_stops_it },
	{ "close does not wait for a monitor between retries", close_does_not_wait_for_a_monitor_between_retries },
	{ "a play from idle switches the rate once", a_play_from_idle_switches_the_rate_once },
	{ "a play waits for the decoder and switches the rate once", a_play_waits_for_the_decoder_and_switches_the_rate_once },
	{ "a play the decoder is slow for opens after 150 ms, as before", a_play_the_decoder_is_slow_for_opens_after_150_ms_as_before },
	{ "a resume does not wait", a_resume_does_not_wait },
	{ "a gapless track at another rate reopens", a_gapless_track_at_another_rate_reopens },
	{ "the rate delay is not stretched on a play from idle", the_rate_delay_is_not_stretched_on_a_play_from_idle },
	{ "the rate delay at a gapless boundary is both halves", the_rate_delay_at_a_gapless_boundary_is_both_halves },
	{ "a play from idle after DoP buffers in PCM silence", a_play_from_idle_after_dop_buffers_in_pcm_silence },
	{ "a stop inside the open after DoP leaves PCM silence", a_stop_inside_the_open_after_dop_leaves_pcm_silence },
	{ "a stop before the open after DoP leaves PCM silence", a_stop_before_the_open_after_dop_leaves_pcm_silence },
	{ "DoP silence at the DoP rate is kept", dop_silence_at_the_dop_rate_is_kept },
	{ "the idle release keeps the silence of what played to the close", the_idle_release_keeps_the_silence_of_what_played_to_the_close },
	{ "a play from idle into DoP buffers in DoP silence", a_play_from_idle_into_dop_buffers_in_dop_silence },
	{ "a play from idle after DoP at its rate buffers in PCM silence", a_play_from_idle_after_dop_at_its_rate_buffers_in_pcm_silence },
	{ "a play from idle into DoP at the last rate buffers in DoP silence", a_play_from_idle_into_dop_at_the_last_rate_buffers_in_dop_silence },
	{ "a synced start waits in the pending track's format", a_synced_start_waits_in_the_pending_tracks_format },
	{ "a slow decoder into DoP buffers in PCM at the last rate", a_slow_decoder_into_dop_buffers_in_pcm_at_the_last_rate },
	{ "the rate delay between DoP tracks is DoP silence", the_rate_delay_between_dop_tracks_is_dop_silence },
	{ "the rate delay is not stretched after a flush while buffering", the_rate_delay_is_not_stretched_after_a_flush_while_buffering },
	{ "a stop during the open leaves no rate delay mark", a_stop_during_the_open_leaves_no_rate_delay_mark },
	{ "a play after a stop while buffering opens at its own rate", a_play_after_a_stop_while_buffering_opens_at_its_own_rate },
	{ "matrix", matrix },
};

int main(int argc, char **argv) {
	unsigned n = sizeof(tests) / sizeof(tests[0]), passed = 0;
	for (unsigned i = 0; i < n; i++) {
		if (argc > 1 && !strstr(tests[i].name, argv[1])) continue;
		fflush(stdout);
		pid_t child = fork();
		if (child == 0) {
			alarm(strcmp(tests[i].name, "matrix") ? 20 : 600); // a hang fails the test instead of the suite
			tests[i].fn();
			fflush(stderr);
			_exit(failed);
		}
		int status = 0;
		waitpid(child, &status, 0);
		bool ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
		if (ok) passed++;
		fprintf(stdout, "%s %s%s\n", ok ? "ok    " : "FAILED", tests[i].name,
				WIFSIGNALED(status) ? (WTERMSIG(status) == SIGALRM ? " (hung)" : " (crashed)") : "");
	}
	unsigned ran = 0;
	for (unsigned i = 0; i < n; i++) ran += argc <= 1 || strstr(tests[i].name, argv[1]) != NULL;
	printf("output_coreaudio: %u tests, %u passed, %u failed\n", ran, passed, ran - passed);
	printf("result: %s\n", passed == ran && ran > 0 ? "PASS" : "FAIL");
	return passed == ran && ran > 0 ? 0 : 1;
}
