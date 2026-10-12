/*
 *  Squeezelite - lightweight headless squeezebox emulator
 *
 *  (c) Adrian Smith 2012-2015, triode1@btinternet.com
 *      Ralph Irving 2015-2025, ralph_irving@hotmail.com
 *
 *  output_coreaudio.c - native macOS CoreAudio (HAL) output, written for LyrionPlay
 *  (c) 2026 CrystalGipsy (this file); squeezelite's authors above for the program it is part of
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

// Drives the HAL device directly instead of going through PortAudio, so the player can
//  - take exclusive (hog) access to an external DAC,
//  - set the device's nominal rate and integer physical format for every track (bit-perfect),
//  - put LMS volume on the device's own volume control (hardware, or the macOS volume).
//
// Structure follows output_pa.c. The IOProc pulls frames with _output_frames() under the output
// lock. When the next track needs another rate, the IOProc stops taking frames, pads with zeros and
// raises output.ca_reopen; when the output goes OFF it plays silence in _silence_fmt's format until
// the device is closed (as output_pa.c) and raises it too. The slimproto thread then calls _ca_open(),
// as it calls _pa_open() for pa_reopen. A missing device, or OUTPUT_OFF, hands over to a monitor
// thread that reopens once the device is back or the output is switched on. An open made while a
// track start is the next frame is at that track's rate, so a play from idle switches rate once;
// the monitor waits up to 150 ms for the decoder to find that rate.

#include "squeezelite.h"

#if COREAUDIO

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <limits.h>
#include <math.h>
#include <stdatomic.h>

#include "output_coreaudio_conv.h"

static log_level loglevel;

static bool running = true;

extern struct outputstate output;
extern struct buffer *outputbuf;
extern u8_t *silencebuf;
#if DSD
extern u8_t *silencebuf_dsd;
#endif

#define LOCK   mutex_lock(outputbuf->mutex)
#define UNLOCK mutex_unlock(outputbuf->mutex)

#define MINVOL_DB 72                 // as output_alsa.c: LMS sends roughly -72..0 dB
#define RATE_SWITCH_TIMEOUT_MS 3000  // some USB DACs take over a second to relock
#define DEVICE_RETRY_S 2             // monitor: how often to look for a missing device
#define OPEN_RETRY_MAX_S 5           // monitor: longest wait to retry a device that is there but will not
									 // open: upstream's cadence, so play starts within 5 s of it coming free
#define RETRY_LOG_EVERY 60           // ...and every this many tries (5 minutes) it says why again
#define OFF_POLL_US 100000           // monitor: how often to check for the output coming back on
#define TRACK_WAIT_US 10000          // a play from idle: how often to look for the first track's rate,
#define TRACK_WAIT_POLLS 15          // ...and for how many looks (150 ms) before opening without it

static struct {
	AudioDeviceID dev;          // device being played to; kAudioObjectUnknown when closed
	AudioDeviceIOProcID procid;
	unsigned rate;              // rate the IOProc is running at
	UInt32 latency_frames;      // device + stream latency
	bool exclusive;             // -a :1  take hog mode while open
	bool hogged;                // we hold hog mode on dev
	AudioDeviceID hog_dev;      // the device we hogged (may differ from dev after a failure)
	unsigned buffer_frames;     // -a <frames>; 0 = device default
	bool hw_volume;             // -V
	bool linear_volume;         // -X
	bool dev_has_volume;        // the output device has a settable volume control
	bool volume_known;          // an audg has arrived
	bool volume_pending;        // LMS volume not yet put on the device (it was absent)
	unsigned last_left, last_right;
	bool monitor_running;
	bool monitor_opening;       // the monitor is inside _ca_open: close waits for it (monitor_done)
	unsigned open_failures;     // opens in a row that failed with the device present
	unsigned track_rate;        // the rate and format of the last track whose start the IOProc took
#if DSD
	dsd_format track_fmt;       //   (_silence_fmt); 0 and PCM before any
#endif
} ca;

static pthread_cond_t monitor_done = PTHREAD_COND_INITIALIZER;

// ---------------------------------------------------------------------------------------------
// HAL property helpers

static bool get_prop(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope,
					 AudioObjectPropertyElement elem, void *data, UInt32 size) {
	AudioObjectPropertyAddress a = { sel, scope, elem };
	UInt32 sz = size;
	return AudioObjectHasProperty(obj, &a) && AudioObjectGetPropertyData(obj, &a, 0, NULL, &sz, data) == noErr;
}

static bool set_prop(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope,
					 AudioObjectPropertyElement elem, const void *data, UInt32 size) {
	AudioObjectPropertyAddress a = { sel, scope, elem };
	return AudioObjectSetPropertyData(obj, &a, 0, NULL, size, data) == noErr;
}

static bool settable(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope,
					 AudioObjectPropertyElement elem) {
	AudioObjectPropertyAddress a = { sel, scope, elem };
	Boolean s = false;
	return AudioObjectHasProperty(obj, &a) && AudioObjectIsPropertySettable(obj, &a, &s) == noErr && s;
}

// caller frees; *count is the number of elements
static void *get_prop_array(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope,
							size_t elem_size, UInt32 *count) {
	AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
	UInt32 size = 0;
	void *data;
	*count = 0;
	if (!AudioObjectHasProperty(obj, &a) || AudioObjectGetPropertyDataSize(obj, &a, 0, NULL, &size) != noErr || !size) {
		return NULL;
	}
	if (!(data = malloc(size))) return NULL;
	if (AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, data) != noErr) {
		free(data);
		return NULL;
	}
	*count = size / elem_size;
	return data;
}

static void get_string(AudioObjectID obj, AudioObjectPropertySelector sel, char *buf, size_t len) {
	CFStringRef s = NULL;
	buf[0] = '\0';
	if (get_prop(obj, sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, &s, sizeof(s)) && s) {
		CFStringGetCString(s, buf, len, kCFStringEncodingUTF8);
		CFRelease(s);
	}
}

static unsigned output_channels(AudioDeviceID dev) {
	AudioObjectPropertyAddress a = { kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput,
									 kAudioObjectPropertyElementMain };
	UInt32 size = 0, i;
	unsigned n = 0;
	AudioBufferList *list;
	if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) != noErr || !size || !(list = malloc(size))) return 0;
	if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, list) == noErr) {
		for (i = 0; i < list->mNumberBuffers; i++) n += list->mBuffers[i].mNumberChannels;
	}
	free(list);
	return n;
}

static AudioDeviceID default_output_device(void) {
	AudioDeviceID dev = kAudioObjectUnknown;
	get_prop(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal,
			 kAudioObjectPropertyElementMain, &dev, sizeof(dev));
	return dev;
}

// "default" follows the system default output; otherwise an exact device UID (stable across
// reboots), an exact name, or failing both a case-insensitive part of a name
static AudioDeviceID find_device(const char *device) {
	AudioDeviceID *devs, found = kAudioObjectUnknown;
	UInt32 count, i;
	int pass;

	if (!device || !*device || !strcmp(device, "default")) return default_output_device();

	devs = get_prop_array(kAudioObjectSystemObject, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
						  sizeof(AudioDeviceID), &count);
	for (pass = 0; pass < 3 && found == kAudioObjectUnknown; pass++) {
		for (i = 0; i < count; i++) {
			char s[256];
			if (!output_channels(devs[i])) continue;
			get_string(devs[i], pass == 0 ? kAudioDevicePropertyDeviceUID : kAudioObjectPropertyName, s, sizeof(s));
			if ((pass < 2 && !strcmp(s, device)) || (pass == 2 && strcasestr(s, device))) {
				found = devs[i];
				break;
			}
		}
	}
	free(devs);
	return found;
}

// the standard rates the device accepts, largest first; rates[] has MAX_SUPPORTED_SAMPLERATES slots
static unsigned device_rates(AudioDeviceID dev, unsigned rates[]) {
	unsigned ref[] TEST_RATES;
	AudioValueRange *ranges;
	UInt32 count, j;
	unsigned n = 0;
	int i;

	ranges = get_prop_array(dev, kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal,
							sizeof(AudioValueRange), &count);
	for (i = 0; ref[i] && n < MAX_SUPPORTED_SAMPLERATES - 1; i++) {
		for (j = 0; j < count; j++) {
			if (ref[i] + 0.5 >= ranges[j].mMinimum && ref[i] - 0.5 <= ranges[j].mMaximum) {
				rates[n++] = ref[i];
				break;
			}
		}
	}
	rates[n] = 0;
	free(ranges);
	return n;
}

static const char *transport_name(UInt32 t) {
	switch (t) {
	case kAudioDeviceTransportTypeBuiltIn:     return "builtin";
	case kAudioDeviceTransportTypeUSB:         return "usb";
	case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt";
	case kAudioDeviceTransportTypeFireWire:    return "firewire";
	case kAudioDeviceTransportTypePCI:         return "pci";
	case kAudioDeviceTransportTypeHDMI:        return "hdmi";
	case kAudioDeviceTransportTypeDisplayPort: return "displayport";
	case kAudioDeviceTransportTypeBluetooth:
	case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth";
	case kAudioDeviceTransportTypeAirPlay:     return "airplay";
	case kAudioDeviceTransportTypeAVB:         return "avb";
	case kAudioDeviceTransportTypeVirtual:     return "virtual";
	case kAudioDeviceTransportTypeAggregate:
	case kAudioDeviceTransportTypeAutoAggregate: return "aggregate";
	default:                                   return "unknown";
	}
}

static AudioStreamID first_output_stream(AudioDeviceID dev) {
	UInt32 n;
	AudioStreamID s = kAudioObjectUnknown;
	AudioStreamID *streams = get_prop_array(dev, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput,
											sizeof(AudioStreamID), &n);
	if (n) s = streams[0];
	free(streams);
	return s;
}

// ---------------------------------------------------------------------------------------------
// Volume: the device's own control (main element, else channels 1 and 2)

struct volctl {
	int n;                                // 0 = no settable volume
	AudioObjectPropertyElement elem[2];
	bool db;                              // the dB property is settable
	Float32 db_min, db_max;
	bool mute;
};

static void find_volume(AudioDeviceID dev, struct volctl *v) {
	const AudioObjectPropertyScope out = kAudioDevicePropertyScopeOutput;
	AudioValueRange range;

	memset(v, 0, sizeof(*v));
	if (settable(dev, kAudioDevicePropertyVolumeScalar, out, kAudioObjectPropertyElementMain)) {
		v->n = 1;
		v->elem[0] = kAudioObjectPropertyElementMain;
	} else if (settable(dev, kAudioDevicePropertyVolumeScalar, out, 1)) {
		v->n = 1;
		v->elem[0] = 1;
		if (settable(dev, kAudioDevicePropertyVolumeScalar, out, 2)) {
			v->n = 2;
			v->elem[1] = 2;
		}
	}
	if (!v->n) return;
	v->db = settable(dev, kAudioDevicePropertyVolumeDecibels, out, v->elem[0]);
	if (get_prop(dev, kAudioDevicePropertyVolumeRangeDecibels, out, v->elem[0], &range, sizeof(range))) {
		v->db_min = range.mMinimum;
		v->db_max = range.mMaximum;
	} else {
		v->db_min = -MINVOL_DB;
		v->db_max = 0;
	}
	v->mute = settable(dev, kAudioDevicePropertyMute, out, kAudioObjectPropertyElementMain);
}

// ---------------------------------------------------------------------------------------------
// Mac volume -> LMS. The level this engine last put on the device is recorded BEFORE it is set, so
// a listener can tell its own changes (LMS's volume, fades, mute ramps) from the user's (volume
// keys, the menu bar slider). Only the user's are reported, as one stdout line for the agent,
//   lyrionplay:volume <dB> <muted 0|1> <lms -1|0|1>
// which the agent turns into LMS `mixer volume N`, `mixer muting 1` or `mixer muting 0`. <lms> is
// LMS's last audg as this engine got it: 1 a level (so LMS is not muted), 0 silence (muted, or
// volume 0), -1 none yet (LMS sends one only when a track starts, so whether its volume is fixed
// is not known either). The agent asks LMS only when it is not 1. LMS's reply re-records the
// level it sets, so a report never echoes. dB mode only; -X (linear) is not reported.

#define VOLUME_MOVED_DB 0.6f         // LMS's dBToFixed rounding and read-back jitter stay below this
// After this engine sets a level, the device's own reports are absorbed for this long: the
// MacBook Pro speakers move in coarse steps and report a level up to 2 dB from the one set, and
// LMS fades a mute over 0.31 s. Measured 2026-10-09: without it, LMS volume 50 crept to 57, each
// read-back mistaken for a user change.
#define VOLUME_SETTLE_NS 500000000ULL

static struct {
	_Atomic int centi_db;            // last level applied or reported, 1/100 dB
	_Atomic int muted;               // last mute applied or reported; -1 = the device has no mute
	_Atomic bool valid;              // a level has been recorded, so there is something to compare
	_Atomic uint64_t settle_until;   // CLOCK_UPTIME_RAW ns: until then the listener only records
	_Atomic int lms;                 // LMS's last audg: 1 a level, 0 silence, -1 none yet
	AudioDeviceID dev;               // the device the listeners are on
	struct volctl ctl;               // its controls, as the listeners were added
	pthread_mutex_t lock;            // guards dev and ctl for the listener: held only to copy them
	pthread_mutex_t watch;           // serialises adding and removing the listeners
} vrec = { .muted = -1, .lms = -1, .dev = kAudioObjectUnknown, .lock = PTHREAD_MUTEX_INITIALIZER,
		   .watch = PTHREAD_MUTEX_INITIALIZER };

// the device's level in dB: the louder of its controls
static float read_device_db(AudioDeviceID dev, const struct volctl *v) {
	const AudioObjectPropertyScope out = kAudioDevicePropertyScopeOutput;
	float best = -INFINITY;
	int i;
	for (i = 0; i < v->n; i++) {
		Float32 d;
		if (!get_prop(dev, kAudioDevicePropertyVolumeDecibels, out, v->elem[i], &d, sizeof(d))) {
			AudioObjectPropertyAddress a = { kAudioDevicePropertyVolumeScalarToDecibels, out, v->elem[i] };
			UInt32 size = sizeof(d);
			if (!get_prop(dev, kAudioDevicePropertyVolumeScalar, out, v->elem[i], &d, sizeof(d)) ||
				AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &d) != noErr) continue;
		}
		best = fmaxf(best, d);
	}
	return best;
}

// the device's mute, or -1 if it has none
static int read_device_mute(AudioDeviceID dev, const struct volctl *v) {
	UInt32 m = 0;
	if (!v->mute || !get_prop(dev, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain, &m, sizeof(m))) return -1;
	return m != 0;
}

// record the level the device actually shows, which is what later reports are compared with
static void record_device_volume(AudioDeviceID dev, const struct volctl *v) {
	float dB = read_device_db(dev, v);
	if (isinf(dB)) return;
	atomic_store(&vrec.centi_db, (int)lrintf(dB * 100));
	atomic_store(&vrec.muted, read_device_mute(dev, v));
	atomic_store(&vrec.valid, true);
}

static OSStatus volume_listener(AudioObjectID dev, UInt32 n, const AudioObjectPropertyAddress addrs[], void *ctx) {
	struct volctl v;
	AudioDeviceID watched;
	float dB, was;
	int muted = -1, was_muted;
	(void)n; (void)addrs; (void)ctx;

	if (!atomic_load(&vrec.valid) || ca.linear_volume || output.volume_fixed) return noErr;
	pthread_mutex_lock(&vrec.lock);
	v = vrec.ctl;
	watched = vrec.dev;
	pthread_mutex_unlock(&vrec.lock);
	if (!v.n || dev != watched) return noErr;

	if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < atomic_load(&vrec.settle_until)) {
		record_device_volume(dev, &v); // this engine's own change, still settling
		return noErr;
	}
	dB = read_device_db(dev, &v);
	if (isinf(dB)) return noErr;
	muted = read_device_mute(dev, &v);
	was = atomic_load(&vrec.centi_db) / 100.0f;
	was_muted = atomic_load(&vrec.muted);
	if (fabsf(dB - was) <= VOLUME_MOVED_DB && (muted < 0 || was_muted < 0 || muted == was_muted)) return noErr;

	// recorded, so one change is reported once however many properties announce it
	atomic_store(&vrec.centi_db, (int)lrintf(dB * 100));
	if (muted >= 0) atomic_store(&vrec.muted, muted);
	LOG_INFO("device volume changed outside LMS: %.2f dB%s", dB, muted > 0 ? ", muted" : "");
	printf("lyrionplay:volume %.2f %d %d\n", dB, muted > 0, atomic_load(&vrec.lms));
	fflush(stdout);
	return noErr;
}

static void volume_listeners(AudioDeviceID dev, const struct volctl *v, bool add) {
	const AudioObjectPropertyScope out = kAudioDevicePropertyScopeOutput;
	int i;
	for (i = 0; i < v->n; i++) {
		AudioObjectPropertyAddress a = { kAudioDevicePropertyVolumeScalar, out, v->elem[i] };
		if (add) AudioObjectAddPropertyListener(dev, &a, volume_listener, NULL);
		else AudioObjectRemovePropertyListener(dev, &a, volume_listener, NULL);
	}
	if (v->mute) {
		AudioObjectPropertyAddress a = { kAudioDevicePropertyMute, out, kAudioObjectPropertyElementMain };
		if (add) AudioObjectAddPropertyListener(dev, &a, volume_listener, NULL);
		else AudioObjectRemovePropertyListener(dev, &a, volume_listener, NULL);
	}
}

// Removing a listener waits for a call of it that is in flight (measured 2026-10-10: 1001 ms for a
// listener that slept 1 s), and the listener takes vrec.lock. So vrec.lock is never held across
// AudioObjectAdd/RemovePropertyListener; vrec.watch, which the listener never takes, keeps two
// threads from re-pointing the listeners at once. vrec.dev and vrec.ctl change only under both.
static void point_listeners(AudioDeviceID dev, const struct volctl *v, bool record) {
	AudioDeviceID old = vrec.dev;
	struct volctl oldctl = vrec.ctl;
	if (old != kAudioObjectUnknown) volume_listeners(old, &oldctl, false); // no call of it is left running
	if (record) record_device_volume(dev, v);
	pthread_mutex_lock(&vrec.lock);
	vrec.dev = dev;
	if (v) vrec.ctl = *v; else memset(&vrec.ctl, 0, sizeof(vrec.ctl));
	pthread_mutex_unlock(&vrec.lock);
	if (dev != kAudioObjectUnknown) volume_listeners(dev, v, true);
}

// follow the device the volume is put on (the output device can come back with a new ID).
// record: a device this engine has not set a level on yet, so its current level is the record.
static void watch_volume(AudioDeviceID dev, const struct volctl *v, bool record) {
	pthread_mutex_lock(&vrec.watch);
	if (vrec.dev != dev) point_listeners(dev, v, record);
	pthread_mutex_unlock(&vrec.watch);
}

static void unwatch_volume(void) {
	pthread_mutex_lock(&vrec.watch);
	point_listeners(kAudioObjectUnknown, NULL, false);
	pthread_mutex_unlock(&vrec.watch);
	atomic_store(&vrec.valid, false);
}

// left/right are LMS's 16.16 gains, as handed to set_volume()
static void apply_volume(AudioDeviceID dev, unsigned left, unsigned right) {
	const AudioObjectPropertyScope out = kAudioDevicePropertyScopeOutput;
	struct volctl v;
	float ldB = left ? 20 * log10f(left / 65536.0F) : -INFINITY;
	float rdB = right ? 20 * log10f(right / 65536.0F) : -INFINITY;
	int i;

	find_volume(dev, &v);
	if (!v.n) return;

	if (!ca.linear_volume) {
		// before setting: the HAL may announce the change before set_prop returns
		atomic_store(&vrec.settle_until, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + VOLUME_SETTLE_NS);
		watch_volume(dev, &v, false);
	}

	for (i = 0; i < v.n; i++) {
		// a single main control takes the louder side, so balance never makes it quieter
		float dB = v.n == 1 ? fmaxf(ldB, rdB) : (i == 0 ? ldB : rdB);
		if (ca.linear_volume) {
			Float32 scalar = dB > -MINVOL_DB ? (MINVOL_DB + dB) / MINVOL_DB : 0;
			if (scalar > 1) scalar = 1;
			set_prop(dev, kAudioDevicePropertyVolumeScalar, out, v.elem[i], &scalar, sizeof(scalar));
		} else {
			Float32 d = isinf(dB) || dB < v.db_min ? v.db_min : (dB > v.db_max ? v.db_max : dB);
			if (v.db) {
				set_prop(dev, kAudioDevicePropertyVolumeDecibels, out, v.elem[i], &d, sizeof(d));
			} else {
				// let the HAL map dB onto this device's scalar taper
				AudioObjectPropertyAddress a = { kAudioDevicePropertyVolumeDecibelsToScalar, out, v.elem[i] };
				UInt32 size = sizeof(d);
				if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &d) == noErr) {
					set_prop(dev, kAudioDevicePropertyVolumeScalar, out, v.elem[i], &d, sizeof(d));
				}
			}
		}
	}
	if (v.mute) {
		UInt32 mute = (left == 0 && right == 0);
		set_prop(dev, kAudioDevicePropertyMute, out, kAudioObjectPropertyElementMain, &mute, sizeof(mute));
	}
	if (!ca.linear_volume) {
		record_device_volume(dev, &v);
		atomic_store(&vrec.settle_until, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + VOLUME_SETTLE_NS);
	}
	LOG_DEBUG("device volume left: %.1f dB right: %.1f dB (%s)", ldB, rdB, ca.linear_volume ? "linear" : "dB");
}

// One level change on the device at a time, with LMS's latest level read inside: when a set_volume
// and a _ca_open apply at once (a resume after the idle release, when LMS fades in with an audg
// every 50 ms: RESUME IS ONE AUDG), the later one always puts the newest level on, never an older
// one after it. Taken with no other lock held; apply_volume then takes vrec.watch, vrec.lock.
static pthread_mutex_t apply_lock = PTHREAD_MUTEX_INITIALIZER;

static void apply_latest(AudioDeviceID dev) {
	unsigned left, right;
	pthread_mutex_lock(&apply_lock);
	LOCK;
	left = ca.last_left;
	right = ca.last_right;
	ca.volume_pending = false;
	UNLOCK;
	apply_volume(dev, left, right);
	pthread_mutex_unlock(&apply_lock);
}

void set_volume(unsigned left, unsigned right) {
	AudioDeviceID dev;
	bool hw, fixed;

	atomic_store(&vrec.lms, left || right ? 1 : 0);
	LOCK;
	ca.last_left = left;
	ca.last_right = right;
	ca.volume_known = true;
	hw = ca.hw_volume && ca.dev_has_volume;
	fixed = output.volume_fixed;
	if (hw) {
		output.gainL = output.gainR = FIXED_ONE;
	} else {
		output.gainL = left;
		output.gainR = right;
	}
	dev = ca.dev;
	// -V with no device open: _ca_open puts this level on the device it opens, unless it lands
	// below first. Set here, under the lock, so a monitor thread opening the device meanwhile sees
	// it. Also when the device is not yet known to have a volume control (absent at init).
	if (ca.hw_volume && dev == kAudioObjectUnknown) ca.volume_pending = true;
	UNLOCK;

	if (!hw) {
		LOG_DEBUG("setting internal gain left: %u right: %u", left, right);
		return;
	}
	// LMS "output level fixed at 100%": leave the device's level where the listener set it.
	// (output_alsa.c's -V sets its mixer to 0 dB here; on a headphone DAC that is full volume.)
	if (fixed) {
		LOG_DEBUG("fixed volume: device level left unchanged");
		return;
	}
	if (dev == kAudioObjectUnknown) dev = find_device(output.device);
	if (dev == kAudioObjectUnknown) return; // still pending
	apply_latest(dev);
}

// ---------------------------------------------------------------------------------------------
// Exclusive access, rate and format

// quiet: a retry of a device that keeps failing, whose reason was already logged
static bool hog(AudioDeviceID dev, bool on, bool quiet) {
	pid_t owner = -1, want = on ? getpid() : -1;

	if (!get_prop(dev, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain,
				  &owner, sizeof(owner))) {
		if (!quiet) LOG_WARN("device has no exclusive (hog) mode");
		return false;
	}
	if (owner == want) return true;
	if (on && owner != -1) {
		if (!quiet) LOG_WARN("device is held exclusively by another process (pid %d)", owner);
		return false;
	}
	if (!on && owner != getpid()) return true; // not ours to release
	if (!set_prop(dev, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain,
				  &want, sizeof(want))) {
		if (!quiet) LOG_WARN("cannot %s exclusive mode", on ? "take" : "release");
		return false;
	}
	get_prop(dev, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain,
			 &owner, sizeof(owner));
	LOG_INFO("exclusive mode %s (owner pid %d)", on ? "taken" : "released", owner);
	return on ? owner == getpid() : owner != getpid();
}

static bool set_rate(AudioDeviceID dev, unsigned rate, bool quiet) {
	Float64 cur = 0, want = rate;
	int waited;

	get_prop(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
			 kAudioObjectPropertyElementMain, &cur, sizeof(cur));
	if ((unsigned)cur == rate) return true;

	if (!set_prop(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
				  kAudioObjectPropertyElementMain, &want, sizeof(want))) {
		if (!quiet) LOG_WARN("device refused %u Hz", rate);
		return false;
	}
	// the change lands asynchronously
	for (waited = 0; waited <= RATE_SWITCH_TIMEOUT_MS; waited += 10) {
		if (get_prop(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
					 kAudioObjectPropertyElementMain, &cur, sizeof(cur)) && (unsigned)cur == rate) {
			LOG_INFO("device rate %u Hz after %d ms", rate, waited);
			return true;
		}
		usleep(10000);
	}
	if (!quiet) LOG_WARN("device did not switch to %u Hz within %d ms (now %.0f)", rate, RATE_SWITCH_TIMEOUT_MS, cur);
	return false;
}

// exclusive mode only: an integer physical format at this rate, as many bits as the device offers
static void set_physical_format(AudioDeviceID dev, unsigned rate) {
	AudioStreamID stream = first_output_stream(dev);
	AudioStreamRangedDescription *f;
	AudioStreamBasicDescription cur, want;
	UInt32 n, i;
	int best = -1;

	if (stream == kAudioObjectUnknown) return;
	memset(&cur, 0, sizeof(cur));
	get_prop(stream, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal,
			 kAudioObjectPropertyElementMain, &cur, sizeof(cur));
	f = get_prop_array(stream, kAudioStreamPropertyAvailablePhysicalFormats, kAudioObjectPropertyScopeGlobal,
					   sizeof(AudioStreamRangedDescription), &n);

	for (i = 0; i < n; i++) {
		AudioStreamBasicDescription *d = &f[i].mFormat;
		if (d->mFormatID != kAudioFormatLinearPCM || (d->mFormatFlags & kAudioFormatFlagIsFloat)) continue;
		if (rate + 0.5 < f[i].mSampleRateRange.mMinimum || rate - 0.5 > f[i].mSampleRateRange.mMaximum) continue;
		if (best < 0) {
			best = i;
		} else {
			AudioStreamBasicDescription *b = &f[best].mFormat;
			bool same_ch = d->mChannelsPerFrame == cur.mChannelsPerFrame;
			bool best_same_ch = b->mChannelsPerFrame == cur.mChannelsPerFrame;
			if (same_ch != best_same_ch) {
				if (same_ch) best = i;
			} else if (d->mBitsPerChannel != b->mBitsPerChannel) {
				if (d->mBitsPerChannel > b->mBitsPerChannel) best = i;
			} else if (d->mBytesPerFrame < b->mBytesPerFrame) {
				best = i;
			}
		}
	}
	if (best < 0) {
		LOG_INFO("no integer physical format at %u Hz; keeping %u-bit%s", rate, (unsigned)cur.mBitsPerChannel,
				 (cur.mFormatFlags & kAudioFormatFlagIsFloat) ? " float" : "");
		free(f);
		return;
	}
	want = f[best].mFormat;
	want.mSampleRate = rate;
	free(f);

	if (want.mBitsPerChannel != cur.mBitsPerChannel || want.mChannelsPerFrame != cur.mChannelsPerFrame ||
		want.mFormatFlags != cur.mFormatFlags || want.mBytesPerFrame != cur.mBytesPerFrame ||
		(unsigned)cur.mSampleRate != rate) {
		if (!set_prop(stream, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal,
					  kAudioObjectPropertyElementMain, &want, sizeof(want))) {
			LOG_WARN("cannot set %u-bit integer physical format", (unsigned)want.mBitsPerChannel);
			return;
		}
		get_prop(stream, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal,
				 kAudioObjectPropertyElementMain, &cur, sizeof(cur));
	}
	LOG_INFO("physical format: %u-bit %s, %u ch, %.0f Hz", (unsigned)cur.mBitsPerChannel,
			 (cur.mFormatFlags & kAudioFormatFlagIsFloat) ? "float" : "integer", (unsigned)cur.mChannelsPerFrame,
			 cur.mSampleRate);
}

// ---------------------------------------------------------------------------------------------
// Debug-only output tap: LYRIONPLAY_TAP=<path prefix> records exactly what is handed to CoreAudio
// (left/right Float32, one file per rate) for tools/bitcheck. The IOProc only copies into a
// lock-free ring; a separate thread writes the files, so the audio thread never touches a file.

#define TAP_FRAMES (1u << 20)

static struct {
	bool on;
	char base[PATH_MAX];
	float *ring;                // TAP_FRAMES frames of L,R
	_Atomic size_t w, r;        // frames written / read, ever
	_Atomic size_t dropped;
	pthread_mutex_t drain;      // serialises the two consumers (writer thread, rotation)
	FILE *f;
	unsigned seq;
	pthread_t thread;
} tap;

static void tap_push(const AudioBufferList *out, frames_t frames) {
	size_t w = atomic_load_explicit(&tap.w, memory_order_relaxed);
	size_t r = atomic_load_explicit(&tap.r, memory_order_acquire);
	UInt32 nch = out->mBuffers[0].mNumberChannels;
	frames_t i;

	if (TAP_FRAMES - (w - r) < frames) {
		atomic_fetch_add_explicit(&tap.dropped, frames, memory_order_relaxed);
		return;
	}
	for (i = 0; i < frames; i++) {
		float *slot = tap.ring + ((w + i) & (TAP_FRAMES - 1)) * 2;
		if (out->mNumberBuffers == 1) {
			const float *src = (const float *)out->mBuffers[0].mData + (size_t)i * nch;
			slot[0] = src[0];
			slot[1] = nch > 1 ? src[1] : src[0];
		} else {
			slot[0] = ((const float *)out->mBuffers[0].mData)[(size_t)i * out->mBuffers[0].mNumberChannels];
			slot[1] = ((const float *)out->mBuffers[1].mData)[(size_t)i * out->mBuffers[1].mNumberChannels];
		}
	}
	atomic_store_explicit(&tap.w, w + frames, memory_order_release);
}

static void tap_drain_locked(void) {
	size_t r = atomic_load_explicit(&tap.r, memory_order_relaxed);
	size_t w = atomic_load_explicit(&tap.w, memory_order_acquire);
	while (r < w) {
		size_t idx = r & (TAP_FRAMES - 1);
		size_t n = min(w - r, TAP_FRAMES - idx);
		if (tap.f) fwrite(tap.ring + idx * 2, sizeof(float) * 2, n, tap.f);
		r += n;
	}
	atomic_store_explicit(&tap.r, r, memory_order_release);
}

static void *tap_writer(void *arg) {
	while (running) {
		usleep(20000);
		pthread_mutex_lock(&tap.drain);
		tap_drain_locked();
		if (tap.f) fflush(tap.f);
		pthread_mutex_unlock(&tap.drain);
	}
	return NULL;
}

// called with the IOProc stopped, so everything it produced is already in the ring
static void tap_rotate(unsigned rate) {
	char path[PATH_MAX + 32];
	size_t dropped;
	pthread_mutex_lock(&tap.drain);
	tap_drain_locked();
	if (tap.f) fclose(tap.f);
	snprintf(path, sizeof(path), "%s-%03u-%uHz.f32", tap.base, ++tap.seq, rate);
	tap.f = fopen(path, "wb");
	dropped = atomic_exchange(&tap.dropped, 0);
	pthread_mutex_unlock(&tap.drain);
	if (dropped) LOG_WARN("tap: %zu frames dropped (ring full)", dropped);
	LOG_INFO("tap: recording %s", tap.f ? path : "FAILED");
}

static void tap_init(const char *base) {
	tap.ring = malloc(sizeof(float) * 2 * TAP_FRAMES);
	if (!tap.ring) return;
	strncpy(tap.base, base, sizeof(tap.base) - 1);
	pthread_mutex_init(&tap.drain, NULL);
	atomic_init(&tap.w, 0);
	atomic_init(&tap.r, 0);
	atomic_init(&tap.dropped, 0);
	tap.on = true;
	pthread_create(&tap.thread, NULL, tap_writer, NULL);
	LOG_INFO("output tap on: %s-*.f32", tap.base);
}

static void tap_close(void) {
	if (!tap.on) return;
	pthread_join(tap.thread, NULL);
	pthread_mutex_lock(&tap.drain);
	tap_drain_locked();
	if (tap.f) fclose(tap.f);
	tap.f = NULL;
	pthread_mutex_unlock(&tap.drain);
}

// ---------------------------------------------------------------------------------------------
// The IOProc

static AudioBufferList *io_out; // set for the duration of one IOProc call (output lock held)
static frames_t io_pos;

static void store(const s32_t *src, frames_t frames) {
	frames_t i;
	if (io_out->mNumberBuffers == 1) {
		UInt32 nch = io_out->mBuffers[0].mNumberChannels;
		float *dst = (float *)io_out->mBuffers[0].mData + (size_t)io_pos * nch;
		for (i = 0; i < frames; i++, src += 2, dst += nch) {
			dst[0] = ca_s32_to_float(src[0]);
			if (nch > 1) dst[1] = ca_s32_to_float(src[1]);
		}
	} else {
		UInt32 lch = io_out->mBuffers[0].mNumberChannels, rch = io_out->mBuffers[1].mNumberChannels;
		float *l = (float *)io_out->mBuffers[0].mData + (size_t)io_pos * lch;
		float *r = (float *)io_out->mBuffers[1].mData + (size_t)io_pos * rch;
		for (i = 0; i < frames; i++, src += 2, l += lch, r += rch) {
			*l = ca_s32_to_float(src[0]);
			*r = ca_s32_to_float(src[1]);
		}
	}
	io_pos += frames;
}

// The next frame is the start of a track whose rate the decoder has found. The decoder sets
// track_start and the rate before it writes the track's first frames; output_flush empties the
// buffer but leaves track_start, which then still equals readp with the old stream's rate until
// the next stream's decoder writes. Frames in the buffer tell the two apart. Called locked.
static bool _track_pending(void) {
	return output.track_start && output.track_start == outputbuf->readp && output.next_sample_rate &&
		_buf_used(outputbuf);
}

// ...and the device is at its rate: what plays next at the device's rate is that track. The one
// rule _silence_fmt, _rate_ok and _mark_switch_done share. Called locked.
static bool _at_pending_rate(void) {
	return _track_pending() && ca.rate == output.next_sample_rate;
}

#if DSD
// The format of the silence: that of the track next to it at the device's rate. First the pending
// track, when the device is at its rate (/code-review 2026-10-11 (2): at the LAST track's rate, a
// play from idle or a synced start in the other format otherwise waited in the last track's). Then
// the track playing or last played, when the device is at ITS rate: upstream's DoP lock in a pause,
// an underrun, after a stop and in a rate delay. Anything else is PCM zeros: DoP silence at any other
// rate is played as PCM, a square wave at Nyquist, ~-27 dBFS (/code-review 2026-10-11).
// That track is the last start the IOProc took (ca.track_rate, ca.track_fmt), not output.c's
// current_sample_rate and outfmt: output_flush resets the rate to the default when the output is not
// open (error_opening) and leaves outfmt, so a stop or a new album during a play from idle after DoP
// had a device at 44.1 kHz match that pair and play DoP silence until the idle release
// (/code-review 2026-10-11 (3)). At a gapless boundary this differs from output.c only inside a DSD
// delay (-D <ms>, never set by the app), whose first half then plays in the new format. Called locked.
static dsd_format _silence_fmt(void) {
	if (_at_pending_rate()) return output.next_fmt;
	if (ca.rate == ca.track_rate) return ca.track_fmt;
	return PCM;
}
#endif

static int _write_frames(frames_t out_frames, bool silence, s32_t gainL, s32_t gainR, u8_t flags,
						 s32_t cross_gain_in, s32_t cross_gain_out, s32_t **cross_ptr) {
	if (!silence) {
		if (output.fade == FADE_ACTIVE && output.fade_dir == FADE_CROSS && *cross_ptr) {
			_apply_cross(outputbuf, out_frames, cross_gain_in, cross_gain_out, cross_ptr);
		}
		// at exactly unity (100%, fixed or device volume, no replay gain) samples are not touched
		if (gainL != FIXED_ONE || gainR != FIXED_ONE) {
			_apply_gain(outputbuf, out_frames, gainL, gainR, flags);
		}
		IF_DSD(
			if (output.outfmt == DOP) {
				update_dop((u32_t *) outputbuf->readp, out_frames, output.invert);
			} else if (output.outfmt != PCM && output.invert)
				dsd_invert((u32_t *) outputbuf->readp, out_frames);
		)
		store((s32_t *)outputbuf->readp, out_frames);
	} else {
		u8_t *buf = silencebuf;
		IF_DSD(
			if (_silence_fmt() != PCM) {
				buf = silencebuf_dsd; // DoP silence keeps the DAC locked in DSD mode
				update_dop((u32_t *) buf, out_frames, false);
			}
		)
		store((s32_t *)buf, out_frames);
	}
	return (int)out_frames;
}

// The silence output.c puts around the pending track's start (_output_frames): the rate delay
// (-r …:<ms>, "Silence on a rate change") when the rate changes, the DSD delay when the output
// format does. Half plays before the switch, counted at the old rate, half after. A copy of
// output.c's rule (output.c:128-139; the suite links the real output.c): UPSTREAM.md has an update
// re-check it. Called locked.
static unsigned _start_delay(void) {
	unsigned delay = output.current_sample_rate != output.next_sample_rate ? output.rate_delay : 0;
	IF_DSD( if (output.outfmt != output.next_fmt) delay = output.dsd_delay; )
	return delay;
}

// The IOProc runs at the rate of what plays next: the current track's, or that of the track whose
// start is the next frame, when _ca_open opened at its rate (a play from idle). Stopped or
// buffering with nothing in the buffer (a stop or a new stream after such an open), it plays only
// silence, at any rate: the next stream's first frames decide. Called locked.
static bool _rate_ok(void) {
	return ca.rate == output.current_sample_rate || _at_pending_rate() ||
		(output.state <= OUTPUT_BUFFER && !_buf_used(outputbuf));
}

// When the device already runs at the pending track's rate (_ca_open opened at it), the switch
// output.c's track start would make has been made. The delay's first half is silence before that
// switch, counted at the old rate; played at the new one it would last old/new times as long (x8.7
// from 384k to 44.1k). Marking it done leaves only the second half, at the new rate: the silence
// after the switch, as before the open rule. Set from the live state before each start can be
// taken, so a flush (which clears the mark) or a track that changed meanwhile is followed.
// Called locked.
static void _mark_switch_done(void) {
	if (!output.delay_active && _at_pending_rate() && ca.rate != output.current_sample_rate && _start_delay()) {
		output.delay_active = true;
	}
}

static OSStatus ioproc(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in,
					   const AudioTimeStamp *in_time, AudioBufferList *out, const AudioTimeStamp *out_time,
					   void *context) {
	UInt32 b, nch;
	frames_t wanted;
	int zero = 0;

	if (!out || !out->mNumberBuffers) return noErr;
	nch = out->mBuffers[0].mNumberChannels ? out->mBuffers[0].mNumberChannels : 1;
	wanted = out->mBuffers[0].mDataByteSize / (nch * sizeof(float));
	for (b = 0; b < out->mNumberBuffers; b++) {
		memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
	}

	LOCK;

	if ((now->mFlags & kAudioTimeStampSampleTimeValid) && (out_time->mFlags & kAudioTimeStampSampleTimeValid) &&
		out_time->mSampleTime > now->mSampleTime) {
		output.device_frames = (unsigned)(out_time->mSampleTime - now->mSampleTime) + ca.latency_frames;
	} else {
		output.device_frames = ca.latency_frames;
	}
	output.updated = gettime_ms();
	output.frames_played_dmp = output.frames_played;

	io_out = out;
	io_pos = 0;
	if (output.state == OUTPUT_OFF) {
		// off, until the slimproto thread acts on the reopen below and closes the device (one call or
		// more): silence in _silence_fmt's format, as output_pa.c's callback gets from _output_frames
		// while off, so a DoP DAC keeps its lock to the close. That is the format of the last track
		// played, or of a pending track at the device's rate (a power-off, aude, while one buffers).
		// Left zero, it was 2.9 ms of PCM after DoP silence at every idle release after DSD (LIVE TEST
		// of 0.2.9, 2026-10-11). Off, _output_frames plays only silence: no track start, no frames.
		while (io_pos < wanted) {
			if (!_output_frames(wanted - io_pos)) break;
		}
	} else if (_rate_ok()) {
		while (io_pos < wanted) {
			frames_t f;
			u8_t *start = output.track_start;
			_mark_switch_done();
			f = _output_frames(wanted - io_pos);
			// output.c took a track start (within this locked call nothing else clears track_start; strm f's
			// output_flush_streaming does, from slimproto): what plays at its rate now
			if (start && !output.track_start) {
				ca.track_rate = output.current_sample_rate;
				IF_DSD( ca.track_fmt = output.outfmt; )
			}
			// a track that needs another rate has just started: take nothing more at this one
			if (!_rate_ok()) break;
			// a track boundary at the very start of a call returns 0 once; a second 0 means stop
			if (f == 0 && zero++) break;
		}
	}
	// the rest of the buffer stays zero

	if (running && !output.ca_reopen && (output.state == OUTPUT_OFF || !_rate_ok())) {
		output.ca_reopen = true;
		wake_controller();
	}

	UNLOCK;

	if (tap.on) tap_push(out, wanted);
	return noErr;
}

// ---------------------------------------------------------------------------------------------
// What plays -> the agent's menu. CoreAudio sees DoP as PCM at the DSD rate / 16 and has no DoP
// property (repo ledger, NO DOP PROPERTY IN COREAUDIO), so only the engine can say that 176.4 kHz is
// DSD64. From the last track start the IOProc took (ca.track_rate, ca.track_fmt), one stdout line
// per change while the device is open,
//   lyrionplay:format <rate> <pcm|dop>
// and one when it closes (the idle release, a lost device), as a DAC keeps its rate after we let go
// and another app may then play PCM at it (/code-review 2026-10-12, finding 3),
//   lyrionplay:format idle
// <rate> is the device rate the track plays at; dop: any non-PCM output, which the agent's bare -D
// makes DoP. Called by the slimproto thread every ~100 ms, outside the output lock: printf can
// block on the pipe, and the IOProc is a real-time thread.
void ca_report_format(void) {
	static unsigned said_rate;
	static bool said_dop, said_open;
	unsigned rate;
	bool dop = false, open;
	LOCK;
	rate = ca.track_rate;
	IF_DSD( dop = ca.track_fmt != PCM; )
	open = ca.dev != kAudioObjectUnknown;
	UNLOCK;
	if (!open) {
		if (!said_open) return;
		said_open = false;
		printf("lyrionplay:format idle\n");
	} else {
		if (!rate || (said_open && rate == said_rate && dop == said_dop)) return;
		said_open = true;
		said_rate = rate;
		said_dop = dop;
		printf("lyrionplay:format %u %s\n", rate, dop ? "dop" : "pcm");
	}
	fflush(stdout);
}

// ---------------------------------------------------------------------------------------------
// Open / reopen

static void *monitor(void *arg);
static bool _configure(AudioDeviceID dev, unsigned rate, AudioDeviceIOProcID *proc, bool quiet);

// give back exclusive access, if this engine holds it
static void unhog(void) {
	if (!ca.hogged) return;
	hog(ca.hog_dev, false, false);
	ca.hogged = false;
	ca.hog_dev = kAudioObjectUnknown;
}

// rate, format and IOProc for one device; *proc is created but not started. On failure nothing
// plays, so exclusive access is given back: other apps can use the device while the monitor retries.
// quiet: a retry whose reason was already logged (_ca_open).
static bool configure(AudioDeviceID dev, unsigned rate, AudioDeviceIOProcID *proc, bool quiet) {
	if (_configure(dev, rate, proc, quiet)) return true;
	unhog();
	return false;
}

static bool _configure(AudioDeviceID dev, unsigned rate, AudioDeviceIOProcID *proc, bool quiet) {
	AudioStreamID stream;
	AudioStreamBasicDescription vf;
	UInt32 lat = 0, slat = 0;
	OSStatus st;

	if (ca.exclusive && !(ca.hogged && ca.hog_dev == dev)) {
		if (!hog(dev, true, quiet)) return false; // another process owns the device; the monitor retries
		ca.hogged = true;
		ca.hog_dev = dev;
	}
	if (!set_rate(dev, rate, quiet)) return false;
	if (ca.hogged) set_physical_format(dev, rate);

	if (ca.buffer_frames) {
		UInt32 frames = ca.buffer_frames;
		if (!set_prop(dev, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal,
					  kAudioObjectPropertyElementMain, &frames, sizeof(frames))) {
			LOG_WARN("cannot set device buffer to %u frames", ca.buffer_frames);
		}
	}

	stream = first_output_stream(dev);
	memset(&vf, 0, sizeof(vf));
	if (stream == kAudioObjectUnknown ||
		!get_prop(stream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal,
				  kAudioObjectPropertyElementMain, &vf, sizeof(vf)) ||
		vf.mFormatID != kAudioFormatLinearPCM || !(vf.mFormatFlags & kAudioFormatFlagIsFloat) ||
		vf.mBitsPerChannel != 32) {
		if (!quiet) LOG_ERROR("device does not take 32-bit float (format %u, %u bits)", (unsigned)vf.mFormatID,
							  (unsigned)vf.mBitsPerChannel);
		return false;
	}

	get_prop(dev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain,
			 &lat, sizeof(lat));
	get_prop(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain,
			 &slat, sizeof(slat));
	ca.latency_frames = lat + slat;

	if ((st = AudioDeviceCreateIOProcID(dev, ioproc, NULL, proc)) != noErr) {
		if (!quiet) LOG_WARN("cannot create IOProc: %d", (int)st);
		return false;
	}
	return true;
}

// called with the output lock held, like _pa_open(). Device calls are made unlocked: AudioDeviceStop
// waits for an IOProc call that may itself be waiting for this lock.
void _ca_open(void) {
	AudioDeviceID old = ca.dev, dev = kAudioObjectUnknown;
	AudioDeviceIOProcID oldproc = ca.procid, proc = NULL;
	bool off = output.state == OUTPUT_OFF;
	// A track whose start is the next frame plays at its own rate (a play from idle; the monitor
	// waits briefly for the decoder to find it): open at that, not the last track's, so the DAC
	// switches once (_rate_ok). Measured 2026-10-10: the second switch cost ~0.7 s.
	bool pending = _track_pending();
	unsigned rate = pending ? output.next_sample_rate : output.current_sample_rate;
	const char *device = output.device;
	struct volctl v;
	char name[256] = "";
	bool err = false, apply = false, watch = false, present, closing = false;
	// a device that keeps failing to open says why on its first three tries, then every 5 minutes
	bool quiet = ca.open_failures >= 3 && ca.open_failures % RETRY_LOG_EVERY;
	OSStatus st;

	ca.dev = kAudioObjectUnknown;
	ca.procid = NULL;
	ca.rate = 0;
	UNLOCK;

	if (old != kAudioObjectUnknown && oldproc) {
		AudioDeviceStop(old, oldproc);
		AudioDeviceDestroyIOProcID(old, oldproc);
	}

	if (off) {
		LOG_INFO("output off");
		err = true; // as _pa_open: no device while off, the monitor waits for output on
	} else if ((dev = find_device(device)) == kAudioObjectUnknown) {
		LOG_INFO("device %s not found", device);
		err = true;
	}

	// exclusive access is held only while playing to that device: give it back when the output
	// goes off (idle timeout or player power), the device is lost, or another device takes over
	if (ca.hogged && (off || dev != ca.hog_dev)) unhog();

	present = !err;
	if (!err) err = !configure(dev, rate, &proc, quiet);

	if (!err) {
		get_string(dev, kAudioObjectPropertyName, name, sizeof(name));
		find_volume(dev, &v);
		if (tap.on) tap_rotate(rate);
	}

	LOCK;
	if (!err && !running) {
		// the engine is closing (output_close_coreaudio waits for the monitor's open): start nothing
		closing = err = true;
	}
	if (!err) {
		ca.dev = dev;
		ca.procid = proc;
		ca.rate = rate; // at a pending track's rate, the IOProc marks the delay's switch done (_mark_switch_done)
		ca.dev_has_volume = v.n > 0;
		if (ca.hw_volume && ca.dev_has_volume) {
			output.gainL = output.gainR = FIXED_ONE;
			apply = ca.volume_known && ca.volume_pending && !output.volume_fixed;
			watch = !ca.linear_volume;
		} else if (ca.volume_known) {
			output.gainL = ca.last_left;
			output.gainR = ca.last_right;
		}
	}
	output.error_opening = err;
	UNLOCK;

	if (closing) {
		AudioDeviceDestroyIOProcID(dev, proc);
		unhog();
	}

	if (!err) {
		if (apply) {
			apply_latest(dev);
		} else if (watch) {
			// a device that was absent at init has not been watched yet (a no-op if it is)
			watch_volume(dev, &v, true);
		}
		if ((st = AudioDeviceStart(dev, proc)) != noErr) {
			if (!quiet) LOG_WARN("cannot start %s: %d", name, (int)st);
			AudioDeviceDestroyIOProcID(dev, proc);
			unhog();
			LOCK;
			ca.dev = kAudioObjectUnknown;
			ca.procid = NULL;
			ca.rate = 0;
			output.error_opening = err = true;
			UNLOCK;
		} else {
			LOG_INFO("opened %s at %u Hz%s, latency %u frames", name, rate, ca.hogged ? ", exclusive" : "",
					 (unsigned)ca.latency_frames);
		}
	}

	LOCK;
	// a device that is there but will not open (another app holds it exclusively, a rate it
	// refuses) is retried less and less often; one that is missing, or off, as before
	ca.open_failures = present && err ? ca.open_failures + 1 : 0;
	if (err && running && !ca.monitor_running) {
		pthread_t t;
		ca.monitor_running = true;
		if (pthread_create(&t, NULL, monitor, NULL) == 0) {
			pthread_detach(t);
		} else {
			ca.monitor_running = false;
		}
	}
}

// the monitor's wait before retrying: 2 s for a missing device; for one that is there but failed
// to open n times in a row, 2, 4, then 5 s
static unsigned retry_wait(unsigned failures) {
	unsigned s;
	if (!failures) return DEVICE_RETRY_S;
	s = DEVICE_RETRY_S << (failures > 3 ? 2 : failures - 1);
	return s < OPEN_RETRY_MAX_S ? s : OPEN_RETRY_MAX_S;
}

// waits, unlocked, for the output to come back on or the device to return, then reopens
static void *monitor(void *arg) {
	bool off;
	unsigned failures, waited = 0;

	LOCK;
	off = output.state == OUTPUT_OFF;
	failures = ca.open_failures;
	while (running) {
		UNLOCK;
		if (off) usleep(OFF_POLL_US); else sleep(retry_wait(failures));
		LOCK;
		if (!running) break;
		if (off) {
			if (output.state != OUTPUT_OFF) {
				LOG_INFO("output on");
				break;
			}
		} else if (output.state == OUTPUT_OFF) {
			off = true;
		} else if (find_device(output.device) != kAudioObjectUnknown) {
			if (failures) {
				if (failures < 3 || failures % RETRY_LOG_EVERY == 0) {
					LOG_INFO("retrying %s (%u failed opens)", output.device, failures);
				}
			} else {
				LOG_INFO("device %s available", output.device);
			}
			break;
		} else {
			failures = 0; // gone: look for it every 2 s
		}
	}
	// A play from idle. The decoder finds the first track's rate within one of its 100 ms sleeps
	// (decode.c); opened before that, the device is at the last track's rate and switches twice.
	// Measured 2026-10-10 on the DragonFly: the decoder was 10-72 ms behind in the plays it lost,
	// and the second switch cost ~0.73 s. A resume (straight to running) does not wait.
	while (running && output.state == OUTPUT_BUFFER && !_track_pending() && waited < TRACK_WAIT_POLLS) {
		UNLOCK;
		usleep(TRACK_WAIT_US);
		LOCK;
		waited++;
	}
	if (waited) {
		LOG_INFO("track rate %s after %u ms", _track_pending() ? "found" : "not found", waited * TRACK_WAIT_US / 1000);
	}
	ca.monitor_running = false;
	if (running) {
		ca.monitor_opening = true;
		_ca_open();
		ca.monitor_opening = false;
		pthread_cond_broadcast(&monitor_done);
	}
	UNLOCK;
	return NULL;
}

// ---------------------------------------------------------------------------------------------
// Device list and probe

static void json_string(const char *s) {
	putchar('"');
	for (; *s; s++) {
		unsigned char c = (unsigned char)*s;
		if (c == '"' || c == '\\') printf("\\%c", c);
		else if (c < 0x20) printf("\\u%04x", c);
		else putchar(c);
	}
	putchar('"');
}

// one JSON object per output device, for the LyrionPlay agent (and readable enough by eye)
void list_devices(void) {
	AudioDeviceID *devs, def = default_output_device();
	UInt32 count, i;

	devs = get_prop_array(kAudioObjectSystemObject, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
						  sizeof(AudioDeviceID), &count);
	for (i = 0; i < count; i++) {
		AudioDeviceID d = devs[i];
		unsigned rates[MAX_SUPPORTED_SAMPLERATES], nrates, ch = output_channels(d), r;
		char uid[256], name[256], maker[256];
		UInt32 transport = 0, nf = 0, k;
		pid_t owner = -1;
		struct volctl v;
		AudioStreamID stream;
		AudioStreamRangedDescription *f = NULL;
		bool bits[33] = { false }, flt = false, first;
		Float64 now_rate = 0;
		AudioStreamBasicDescription now_fmt;

		if (!ch) continue;
		get_string(d, kAudioDevicePropertyDeviceUID, uid, sizeof(uid));
		get_string(d, kAudioObjectPropertyName, name, sizeof(name));
		get_string(d, kAudioObjectPropertyManufacturer, maker, sizeof(maker));
		get_prop(d, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain,
				 &transport, sizeof(transport));
		get_prop(d, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain,
				 &owner, sizeof(owner));
		nrates = device_rates(d, rates);
		find_volume(d, &v);
		get_prop(d, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
				 kAudioObjectPropertyElementMain, &now_rate, sizeof(now_rate));
		memset(&now_fmt, 0, sizeof(now_fmt));
		if ((stream = first_output_stream(d)) != kAudioObjectUnknown) {
			f = get_prop_array(stream, kAudioStreamPropertyAvailablePhysicalFormats, kAudioObjectPropertyScopeGlobal,
							   sizeof(AudioStreamRangedDescription), &nf);
			get_prop(stream, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal,
					 kAudioObjectPropertyElementMain, &now_fmt, sizeof(now_fmt));
		}
		for (k = 0; k < nf; k++) {
			if (f[k].mFormat.mFormatID != kAudioFormatLinearPCM) continue;
			if (f[k].mFormat.mFormatFlags & kAudioFormatFlagIsFloat) flt = true;
			else if (f[k].mFormat.mBitsPerChannel <= 32) bits[f[k].mFormat.mBitsPerChannel] = true;
		}
		free(f);

		printf("{\"uid\":");
		json_string(uid);
		printf(",\"name\":");
		json_string(name);
		printf(",\"manufacturer\":");
		json_string(maker);
		printf(",\"transport\":\"%s\",\"default\":%s,\"channels\":%u,\"rates\":[", transport_name(transport),
			   d == def ? "true" : "false", ch);
		for (r = 0; r < nrates; r++) printf("%s%u", r ? "," : "", rates[r]);
		printf("],\"integer_bits\":[");
		for (k = 0, first = true; k <= 32; k++) {
			if (bits[k]) {
				printf("%s%u", first ? "" : ",", (unsigned)k);
				first = false;
			}
		}
		printf("],\"float\":%s,\"volume\":", flt ? "true" : "false");
		if (v.n) {
			printf("{\"control\":\"%s\",\"db_min\":%.2f,\"db_max\":%.2f,\"mute\":%s}", v.n == 1 &&
				   v.elem[0] == kAudioObjectPropertyElementMain ? "main" : "channels", v.db_min, v.db_max,
				   v.mute ? "true" : "false");
		} else {
			printf("null");
		}
		printf(",\"exclusive_owner\":%d,\"current_rate\":%.0f,\"current_format\":\"%u-bit %s\"}\n", (int)owner,
			   now_rate, (unsigned)now_fmt.mBitsPerChannel,
			   (now_fmt.mFormatFlags & kAudioFormatFlagIsFloat) ? "float" : "integer");
	}
	free(devs);
}

bool test_open(const char *device, unsigned rates[], bool userdef_rates) {
	AudioDeviceID dev = find_device(device);
	if (dev == kAudioObjectUnknown) {
		LOG_INFO("device %s not found", device);
		return false;
	}
	if (!userdef_rates && !device_rates(dev, rates)) {
		LOG_WARN("device reports no standard rates; assuming 44100");
		rates[0] = 44100;
		rates[1] = 0;
	}
	return true;
}

// ---------------------------------------------------------------------------------------------

void output_init_coreaudio(log_level level, const char *device, unsigned output_buf_size, char *params,
						   unsigned rates[], unsigned rate_delay, unsigned idle, bool hw_volume, bool linear_volume) {
	char *b = next_param(params, ':');
	char *e = next_param(NULL, ':');
	CFRunLoopRef none = NULL;
	const char *tap_base = getenv("LYRIONPLAY_TAP");
	struct volctl v;
	AudioDeviceID dev;

	loglevel = level;

	LOG_INFO("init output");

	memset(&output, 0, sizeof(output));
	memset(&ca, 0, sizeof(ca));
	ca.dev = ca.hog_dev = kAudioObjectUnknown;
	ca.buffer_frames = b ? (unsigned)atoi(b) : 0;
	ca.exclusive = e && atoi(e) == 1;
	ca.hw_volume = hw_volume;
	ca.linear_volume = linear_volume;

	// HAL notifications on the HAL's own thread: this process has no run loop
	AudioObjectPropertyAddress rl = { kAudioHardwarePropertyRunLoop, kAudioObjectPropertyScopeGlobal,
									  kAudioObjectPropertyElementMain };
	AudioObjectSetPropertyData(kAudioObjectSystemObject, &rl, 0, NULL, sizeof(none), &none);

	output.format = 0;
	output.start_frames = 0;
	output.write_cb = &_write_frames;
	output.rate_delay = rate_delay;

	LOG_INFO("exclusive: %s, device volume: %s%s, buffer: %u frames", ca.exclusive ? "yes" : "no",
			 ca.hw_volume ? "yes" : "no", ca.hw_volume && ca.linear_volume ? " (linear)" : "", ca.buffer_frames);

	if (tap_base && *tap_base) tap_init(tap_base);

	output_init_common(level, device, output_buf_size, rates, idle);

	if ((dev = find_device(device)) != kAudioObjectUnknown) {
		find_volume(dev, &v);
		ca.dev_has_volume = v.n > 0;
		if (ca.hw_volume && !ca.dev_has_volume) LOG_INFO("device has no volume control: using software volume");
		// LMS sends a volume only when a track starts (Squeezebox::play), so watch from now
		if (ca.hw_volume && ca.dev_has_volume && !ca.linear_volume) watch_volume(dev, &v, true);
	}

	LOCK;
	_ca_open();
	UNLOCK;
}

void output_close_coreaudio(void) {
	AudioDeviceID dev;
	AudioDeviceIOProcID proc;

	LOG_INFO("close output");

	LOCK;
	running = false;
	// A monitor opening the device works unlocked for up to RATE_SWITCH_TIMEOUT_MS. Left to run, it
	// starts an IOProc on the output buffer output_close_common frees. Wait for it; it starts
	// nothing once running is false. A monitor that is only waiting to retry is not waited for.
	if (ca.monitor_opening) {
		struct timespec until;
		clock_gettime(CLOCK_REALTIME, &until);
		until.tv_sec += RATE_SWITCH_TIMEOUT_MS / 1000 + 2;
		while (ca.monitor_opening && pthread_cond_timedwait(&monitor_done, &outputbuf->mutex, &until) == 0);
		if (ca.monitor_opening) LOG_WARN("closing while the device is still being opened");
	}
	dev = ca.dev;
	proc = ca.procid;
	ca.dev = kAudioObjectUnknown;
	ca.procid = NULL;
	UNLOCK;

	if (dev != kAudioObjectUnknown && proc) {
		AudioDeviceStop(dev, proc);
		AudioDeviceDestroyIOProcID(dev, proc);
	}
	unhog();
	unwatch_volume();
	tap_close();

	output_close_common();
}

#endif // COREAUDIO
