/*
 * (c) 2026 CrystalGipsy, for LyrionPlay. GNU General Public License v3 or later, as the
 * engine it tests (../LICENSE.txt).
 *
 * Regression suite for the player name in slimproto.c (LMS OWNS THE PLAYER NAME): what the engine
 * answers to LMS's name query, what it stores when LMS sends a name, and the servers that have named
 * the player (the -N file's ".server": one line each, its address and LMS server_uuid, asked at each
 * connect by ask_server_uuid, here against a stand-in LMS on 127.0.0.1).
 *
 * slimproto.c is #included (NAME_SOURCE names it, so the suite can be built against an older copy
 * to prove a test fails there) with the rest of the engine stubbed out; its packets go to a socket
 * pair, read back here. process_setd and load_player_name are the real ones.
 *
 * Two kinds of test:
 *   - the engine's answers, one per rule;
 *   - a model of LMS 9.1's side (lms_*), from the source in the ledger's §A3 TWO NAMES IN FLIGHT
 *     LOOP: at a (re)connect LMS sends the name query, and a rename it held while the player played
 *     goes out with it; an empty answer makes LMS send its own name (playerSettingsFrame); a name
 *     that differs from LMS's sets it, and the change sends it back (setChange ->
 *     setPlayerSetting); a name equal to LMS's changes nothing. Messages are exchanged until neither
 *     side sends; more than LOOP_LIMIT is a loop. The model reproduces the loop seen on the rig
 *     (control: "the model sees the loop when the name crosses a held rename").
 *
 * Each test runs in its own child process (fresh statics) with a timeout, in a scratch folder the
 * parent makes and removes. Prints one line per test and a summary line; exits 0 only if every test
 * passed.
 *
 * Build and run: make -f Makefile.coreaudio tests/test_slimproto_name && ./tests/test_slimproto_name
 * Against an older copy (anti-run), into another file:
 *   cc ... -DNAME_SOURCE='"/path/old_slimproto.c"' -o /tmp/t tests/test_slimproto_name.c utils.c
 */

#ifndef NAME_SOURCE
#define NAME_SOURCE "../slimproto.c"
#endif
// slimproto.c's flushes to the disk itself (F_FULLFSYNC), counted: a plain fsync leaves the data in the
// drive's cache, so that a power cut can leave the name file empty
#include <fcntl.h>
static int full_syncs;
static int counted_fcntl(int fd, int cmd) {
	if (cmd == F_FULLFSYNC) full_syncs++;
	return fcntl(fd, cmd);
}
#define fcntl(fd, cmd) counted_fcntl(fd, cmd)
#include NAME_SOURCE
#undef fcntl

#include <sys/wait.h>
#include <sys/stat.h>
#include <signal.h>
#include <pthread.h>
#include <sys/resource.h>

// ---- the rest of the engine, stubbed: nothing here is reached by the name code ----

struct buffer *streambuf, *outputbuf;
struct streamstate stream;
struct outputstate output;
struct decodestate decode;
struct codec *codecs[MAX_CODECS];
unsigned _buf_used(struct buffer *buf) { return 0; }
void buf_flush(struct buffer *buf) {}
void stream_file(const char *header, size_t header_len, unsigned threshold) {}
void stream_sock(u32_t ip, u16_t port, bool use_ssl, bool use_ogg, const char *header, size_t header_len, unsigned threshold, bool cont_wait) {}
bool stream_disconnect(void) { return false; }
void decode_flush(void) {}
void codec_open(u8_t format, u8_t sample_size, u8_t sample_rate, u8_t channels, u8_t endianness) {}
void output_flush(void) {}
bool output_flush_streaming(void) { return false; }
void set_volume(unsigned left, unsigned right) {}
void _ca_open(void) {}
void ca_report_format(void) {}

// ---- harness ----

#define SERVER_A "192.168.1.234"
#define SERVER_B "10.0.0.7"
#define TAILSCALE "100.71.35.108"
#define UUID_PLEX "2c913d97-fd70-4828-aa63-736619393939"  // plex's, measured 2026-10-15
#define UUID_OTHER "9e1f6a3b-0000-4c2d-8e5f-0123456789ab"
#define LOOP_LIMIT 200

static int peer = -1;            // LMS's end of the socket pair
static char dir[256];            // this test's scratch folder
static char name_path[300];      // the -N file
static char stamp_path[310];     // its ".server"
static int failures = 0;

#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("    FAILED: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void write_file(const char *path, const char *text) {
	FILE *fp = fopen(path, "w");
	if (!fp) { perror(path); exit(2); }
	fputs(text, fp);
	fclose(fp);
}

// the file's line n (1 first), "" when there is none
static const char *read_line(const char *path, int n) {
	static char text[128];
	FILE *fp = fopen(path, "r");
	text[0] = '\0';
	if (!fp) return text;
	while (n-- > 0) {
		if (!fgets(text, sizeof(text), fp)) { text[0] = '\0'; break; }
	}
	fclose(fp);
	text[strcspn(text, "\n")] = '\0';
	return text;
}

static const char *read_file(const char *path) { return read_line(path, 1); }


// The scratch folder is made by the parent before each test's fork and removed by it after the
// wait, so a test that crashes or times out leaves nothing in $TMPDIR (/code-review 2026-10-15 (7)
// finding 8: removed in the child, a killed test left its folder).
static void make_dir(void) {
	snprintf(dir, sizeof(dir), "%s/lyrionplay-name-XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
	if (!mkdtemp(dir)) { perror("mkdtemp"); exit(2); }
	snprintf(name_path, sizeof(name_path), "%s/name", dir);
	snprintf(stamp_path, sizeof(stamp_path), "%s/name.server", dir);
}

// in the test's child
static void setup(void) {
	int fds[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) { perror("socketpair"); exit(2); }
	sock = fds[0];
	peer = fds[1];
	loglevel = lERROR;
}

static void remove_dir(void) {
	char tmp[320];
	unlink(name_path);
	unlink(stamp_path);
	snprintf(tmp, sizeof(tmp), "%s.tmp", name_path);
	unlink(tmp);
	snprintf(tmp, sizeof(tmp), "%s.tmp", stamp_path);
	unlink(tmp);
	rmdir(dir);
}

// the engine connects: the address, and the UUID ask_server_uuid got ("" for no answer)
static void engine_connect(const char *server, const char *uuid) {
	slimproto_ip = inet_addr(server);
	strcpy(server_uuid, uuid);
}

// the engine starts: -n and -N as the agent passes them (EngineArguments), then connects to a
// server that does not answer for its UUID (the address decides)
static void engine_start(const char *n, const char *server) {
	load_player_name(n, name_path);
	engine_connect(server, "");
}

static void engine_start_uuid(const char *n, const char *server, const char *uuid) {
	load_player_name(n, name_path);
	engine_connect(server, uuid);
}

// the next SETD name the engine sent, or NULL when it sent none
static const char *engine_sent(void) {
	static char name[256];
	struct SETD_header header;
	size_t i = 0;
	if (recv(peer, &header, sizeof(header), MSG_DONTWAIT) != (ssize_t)sizeof(header)) return NULL;
	if (memcmp(header.opcode, "SETD", 4) != 0 || header.id != 0) { failures++; printf("    FAILED: not a SETD name\n"); return NULL; }
	for (;;) {
		char c;
		if (recv(peer, &c, 1, MSG_DONTWAIT) != 1) break;
		if (c == '\0') break;
		if (i < sizeof(name) - 1) name[i++] = c;
	}
	name[i] = '\0';
	return name;
}

// LMS's setd for the name, as slimproto.c's dispatch hands it over: "setd", id 0, then the name
static void to_engine(const char *name) {
	u8_t pkt[5 + 256];                       // LMS keeps a name of any length
	int len = 5;
	memcpy(pkt, "setd", 4);
	pkt[4] = 0;
	if (name) {
		size_t n = strlen(name) + 1;
		memcpy(pkt + 5, name, n);
		len += n;
	}
	process_setd(pkt, len);
}

// LMS's name query: what the engine answers (NULL: nothing)
static const char *query(void) {
	to_engine(NULL);
	return engine_sent();
}

// ---- the model of LMS ----

struct lms {
	char pref[PLAYER_NAME_LEN + 1];  // the player's playername pref
	bool held;                        // a rename made while the player played, not yet sent
	int to_engine;                    // setd sent to the player
};

// an engine message reaches LMS: playerSettingsFrame, then setChange's setPlayerSetting
static void lms_receive(struct lms *lms, const char *value, char queue[][PLAYER_NAME_LEN + 1], int *n) {
	if (!value[0]) {
		strcpy(queue[(*n)++], lms->pref);
	} else if (strcmp(value, lms->pref) != 0) {
		strcpy(lms->pref, value);
		strcpy(queue[(*n)++], lms->pref);
	}
}

// a (re)connect: the query, and a held rename with it; then both sides answer until neither sends.
// Returns the number of messages, or -1 past LOOP_LIMIT.
static int lms_connect(struct lms *lms) {
	char queue[2][LOOP_LIMIT + 4][PLAYER_NAME_LEN + 1];
	int n = 0, messages = 0, which = 0;
	strcpy(queue[0][n++], "?");
	if (lms->held) {
		strcpy(queue[0][n++], lms->pref);
		lms->held = false;
	}
	while (n) {
		int next = 0;
		for (int i = 0; i < n; i++) {
			const char *answer;
			to_engine(strcmp(queue[which][i], "?") == 0 ? NULL : queue[which][i]);
			lms->to_engine++;
			while ((answer = engine_sent())) {
				if (++messages > LOOP_LIMIT) return -1;
				lms_receive(lms, answer, queue[!which], &next);
				if (next > LOOP_LIMIT) return -1;
			}
		}
		which = !which;
		n = next;
	}
	return messages;
}

// ---- tests ----

static void test_new_player(void) {
	engine_start("Kitchen DAC", SERVER_A);
	const char *answer = query();
	CHECK(answer && !strcmp(answer, "Kitchen DAC"), "a new player offers its -n name, got %s", answer ? answer : "nothing");
	to_engine("Kitchen DAC");
	answer = engine_sent();
	CHECK(answer && !strcmp(answer, "Kitchen DAC"), "LMS's name is confirmed, got %s", answer ? answer : "nothing");
	CHECK(!strcmp(read_file(name_path), "Kitchen DAC"), "the name file holds LMS's name, got \"%s\"", read_file(name_path));
	CHECK(!strcmp(read_file(stamp_path), SERVER_A), "the name's server is stored, got \"%s\"", read_file(stamp_path));
}

static void test_same_server(void) {
	write_file(name_path, "Desk DAC");
	write_file(stamp_path, SERVER_A);
	engine_start("prodmac46 AudioQuest DragonFly", SERVER_A);
	const char *answer = query();
	CHECK(answer && !answer[0], "the server that named it gets the empty answer, got %s", answer ? answer : "nothing");
}

static void test_other_server(void) {
	write_file(name_path, "Desk DAC");
	write_file(stamp_path, SERVER_A);
	engine_start("prodmac46 AudioQuest DragonFly", SERVER_B);
	const char *answer = query();
	CHECK(answer && !strcmp(answer, "Desk DAC"), "another server is offered the name, got %s", answer ? answer : "nothing");
	to_engine("Desk DAC");
	engine_sent();
	CHECK(!strcmp(read_line(stamp_path, 2), SERVER_B), "the new server's name stamps it, last, got \"%s\"", read_line(stamp_path, 2));
	CHECK(!strcmp(read_line(stamp_path, 1), SERVER_A), "the first server stays, got \"%s\"", read_line(stamp_path, 1));
	answer = query();
	CHECK(answer && !answer[0], "then that server gets the empty answer, got %s", answer ? answer : "nothing");
}

static void test_no_stamp(void) {
	// a name file from 0.4.8-0.4.9, or 0.3.x's adopted by Follow: no stamp
	write_file(name_path, "simonsMac");
	engine_start("simonsMac", SERVER_B);
	const char *answer = query();
	CHECK(answer && !answer[0], "a name file without a stamp gets the empty answer, as 0.4.9, got %s", answer ? answer : "nothing");
	to_engine("simonsMac");
	engine_sent();
	CHECK(!strcmp(read_file(stamp_path), SERVER_B), "the next name LMS sends stamps it, got \"%s\"", read_file(stamp_path));
}

static void test_bad_stamp(void) {
	write_file(name_path, "Desk DAC");
	write_file(stamp_path, "not an address\n");
	engine_start("x", SERVER_B);
	const char *answer = query();
	CHECK(answer && !answer[0], "an unreadable stamp counts as none, got %s", answer ? answer : "nothing");
}

static void test_empty_file(void) {
	write_file(name_path, "");
	write_file(stamp_path, SERVER_A);
	engine_start("Kitchen DAC", SERVER_A);
	const char *answer = query();
	CHECK(answer && !strcmp(answer, "Kitchen DAC"), "an empty name file offers the -n name, got %s", answer ? answer : "nothing");
}

static void test_serv_switch(void) {
	write_file(name_path, "Desk DAC");
	write_file(stamp_path, SERVER_A);
	engine_start("x", SERVER_A);
	const char *answer = query();
	CHECK(answer && !answer[0], "the first server, which named it: empty, got %s", answer ? answer : "nothing");
	slimproto_ip = inet_addr(SERVER_B); // LMS's serv command, as slimproto() switches
	answer = query();
	CHECK(answer && !strcmp(answer, "Desk DAC"), "after a serv switch the new server is offered the name, got %s", answer ? answer : "nothing");
}

static void test_name_set_in_run(void) {
	// a new player named by LMS during this run: the in-memory server, not only the file
	engine_start("Kitchen DAC", SERVER_A);
	query();
	to_engine("Den");
	engine_sent();
	const char *answer = query();
	CHECK(answer && !answer[0], "a reconnect to the server that just named it: empty, got %s", answer ? answer : "nothing");
	slimproto_ip = inet_addr(SERVER_B);
	answer = query();
	CHECK(answer && !strcmp(answer, "Den"), "another server in the same run is offered it, got %s", answer ? answer : "nothing");
}

static void test_held_rename_same_server(void) {
	// the rig's case (§A3): renamed in LMS while playing, the engine restarted before it stopped
	write_file(name_path, "AudioQuest DragonFly");
	write_file(stamp_path, SERVER_A);
	engine_start("prodmac46 AudioQuest DragonFly Black v1.5", SERVER_A);
	struct lms lms = { "AudioQuest", true, 0 };
	int messages = lms_connect(&lms);
	CHECK(messages >= 0, "no loop (stopped after %d messages)", LOOP_LIMIT);
	CHECK(!strcmp(lms.pref, "AudioQuest"), "LMS keeps its rename, got \"%s\"", lms.pref);
	CHECK(!strcmp(read_file(name_path), "AudioQuest"), "the player takes it, got \"%s\"", read_file(name_path));
}

static void test_held_rename_no_stamp(void) {
	// the first start after an upgrade from 0.4.9, a rename held at that reconnect
	write_file(name_path, "AudioQuest DragonFly");
	engine_start("x", SERVER_A);
	struct lms lms = { "AudioQuest", true, 0 };
	int messages = lms_connect(&lms);
	CHECK(messages >= 0, "no loop without a stamp (stopped after %d messages)", LOOP_LIMIT);
	CHECK(!strcmp(read_file(name_path), "AudioQuest"), "the player takes LMS's rename, got \"%s\"", read_file(name_path));
}

static void test_new_server_keeps_name(void) {
	// a server that never saw this MAC: its pref is LMS's default (Client.pm _makeDefaultName)
	write_file(name_path, "Desk DAC");
	write_file(stamp_path, SERVER_A);
	engine_start("prodmac46 AudioQuest DragonFly Black v1.5", SERVER_B);
	struct lms lms = { "SqueezeLiteMac", false, 0 };
	int messages = lms_connect(&lms);
	CHECK(messages >= 0, "no loop (stopped after %d messages)", LOOP_LIMIT);
	CHECK(!strcmp(lms.pref, "Desk DAC"), "the new server takes the player's name, got \"%s\"", lms.pref);
	CHECK(!strcmp(read_file(name_path), "Desk DAC"), "the name file keeps it, got \"%s\"", read_file(name_path));
	CHECK(!strcmp(read_line(stamp_path, 2), SERVER_B), "the new server stamps it, got \"%s\"", read_line(stamp_path, 2));
}

static void test_model_sees_the_loop(void) {
	// control: the model must be able to fail. The engine offers its name (another server's stamp)
	// to a server holding a rename: the two names cross, as on the rig with 0.4.7
	write_file(name_path, "AudioQuest DragonFly");
	write_file(stamp_path, SERVER_B);
	engine_start("x", SERVER_A);
	struct lms lms = { "AudioQuest", true, 0 };
	CHECK(lms_connect(&lms) == -1, "the model sees the loop when the name crosses a held rename");
}

static void test_unchanged_name_is_quiet(void) {
	// a reconnect with nothing held: one query, one answer, LMS's name, its confirmation, done
	write_file(name_path, "Desk DAC");
	write_file(stamp_path, SERVER_A);
	engine_start("x", SERVER_A);
	struct lms lms = { "Desk DAC", false, 0 };
	int messages = lms_connect(&lms);
	CHECK(messages == 2, "two engine messages (the empty answer, the confirmation), got %d", messages);
}

// ---- the server's UUID ----

static void test_one_server_two_addresses(void) {
	// Simon's hostname: plex at home on the LAN, away over Tailscale
	write_file(name_path, "simonsMac");
	write_file(stamp_path, SERVER_A " " UUID_PLEX "\n");
	engine_start_uuid("x", TAILSCALE, UUID_PLEX);
	const char *answer = query();
	CHECK(answer && !answer[0], "the same LMS at another address gets the empty answer, got %s", answer ? answer : "nothing");
}

static void test_new_lms_old_address(void) {
	write_file(name_path, "simonsMac");
	write_file(stamp_path, SERVER_A " " UUID_PLEX "\n");
	engine_start_uuid("x", SERVER_A, UUID_OTHER);
	const char *answer = query();
	CHECK(answer && !strcmp(answer, "simonsMac"), "another LMS at the old address is offered the name, got %s", answer ? answer : "nothing");
}

static void test_no_uuid_answer(void) {
	write_file(name_path, "simonsMac");
	write_file(stamp_path, SERVER_A " " UUID_PLEX "\n");
	engine_start("x", SERVER_A);
	const char *answer = query();
	CHECK(answer && !answer[0], "no UUID answer, the stamp's address: empty, got %s", answer ? answer : "nothing");
	engine_connect(SERVER_B, "");
	answer = query();
	CHECK(answer && !strcmp(answer, "simonsMac"), "no UUID answer, another address: offered, got %s", answer ? answer : "nothing");
}

static void test_stamp_holds_uuid(void) {
	engine_start_uuid("Kitchen DAC", SERVER_A, UUID_PLEX);
	query();
	to_engine("Kitchen DAC");
	engine_sent();
	CHECK(!strcmp(read_line(stamp_path, 1), SERVER_A " " UUID_PLEX), "the stamp's line is the address and the UUID, got \"%s\"", read_line(stamp_path, 1));
	CHECK(!read_line(stamp_path, 2)[0], "one line for one server, got \"%s\"", read_line(stamp_path, 2));
	// read back at the next start, at another address
	name_server_count = 0;
	engine_start_uuid("Kitchen DAC", TAILSCALE, UUID_PLEX);
	const char *answer = query();
	CHECK(answer && !answer[0], "read back, the same UUID at another address: empty, got %s", answer ? answer : "nothing");
}

static void test_held_rename_two_addresses(void) {
	// named over the LAN, renamed in LMS while playing, reconnected over Tailscale before it stopped
	write_file(name_path, "simonsMac");
	write_file(stamp_path, SERVER_A " " UUID_PLEX "\n");
	engine_start_uuid("x", TAILSCALE, UUID_PLEX);
	struct lms lms = { "Study", true, 0 };
	int messages = lms_connect(&lms);
	CHECK(messages >= 0, "no loop (stopped after %d messages)", LOOP_LIMIT);
	CHECK(!strcmp(read_file(name_path), "Study"), "the player takes LMS's rename, got \"%s\"", read_file(name_path));
}

static void test_held_rename_two_addresses_no_uuid(void) {
	// control: the same without a UUID answer is the loop the UUID prevents
	write_file(name_path, "simonsMac");
	write_file(stamp_path, SERVER_A " " UUID_PLEX "\n");
	engine_start("x", TAILSCALE);
	struct lms lms = { "Study", true, 0 };
	CHECK(lms_connect(&lms) == -1, "without the UUID, the address change crosses the held rename");
}

static void test_held_rename_after_another_server(void) {
	// /code-review 2026-10-15 (4) finding 1: named by A, renamed in A while playing, moved to B (B
	// names it), back to A within LMS's 300 s while A still holds the rename
	write_file(name_path, "Desk DAC");
	write_file(stamp_path, SERVER_A "\n");
	engine_start("x", SERVER_A);
	struct lms a = { "Desk DAC", false, 0 };
	CHECK(lms_connect(&a) >= 0, "A: no loop");
	strcpy(a.pref, "Study");  // renamed in A while it plays: held
	a.held = true;
	engine_connect(SERVER_B, "");
	struct lms b = { "SqueezeLiteMac", false, 0 };
	CHECK(lms_connect(&b) >= 0, "B: no loop");
	engine_connect(SERVER_A, "");
	int messages = lms_connect(&a);
	CHECK(messages >= 0, "back on A: no loop (stopped after %d messages)", LOOP_LIMIT);
	CHECK(!strcmp(a.pref, "Study"), "A keeps its rename, got \"%s\"", a.pref);
	CHECK(!strcmp(read_file(name_path), "Study"), "the player takes it, got \"%s\"", read_file(name_path));
}

static void test_held_rename_after_another_server_restarted(void) {
	// the same with the engine restarted on B (the Server setting changed): the stamp read back
	write_file(name_path, "Desk DAC");
	write_file(stamp_path, SERVER_A "\n");
	engine_start("x", SERVER_B);
	struct lms b = { "SqueezeLiteMac", false, 0 };
	CHECK(lms_connect(&b) >= 0, "B: no loop");
	name_server_count = 0;
	engine_start("x", SERVER_A);
	struct lms a = { "Study", true, 0 };
	CHECK(lms_connect(&a) >= 0, "back on A after a restart: no loop (stopped after %d messages)", LOOP_LIMIT);
	CHECK(!strcmp(read_file(name_path), "Study"), "the player takes A's rename, got \"%s\"", read_file(name_path));
}

static void test_lost_uuid_answer_keeps_uuid(void) {
	// finding 2: at home the UUID reply is lost and LMS names the player; away, over Tailscale,
	// the UUID still makes it the same server
	write_file(name_path, "simonsMac");
	write_file(stamp_path, SERVER_A " " UUID_PLEX "\n");
	engine_start("x", SERVER_A);
	struct lms home = { "simonsMac", false, 0 };
	CHECK(lms_connect(&home) >= 0, "home: no loop");
	CHECK(!strcmp(read_line(stamp_path, 1), SERVER_A " " UUID_PLEX), "a connect without a UUID keeps the stamp's, got \"%s\"", read_line(stamp_path, 1));
	engine_connect(TAILSCALE, UUID_PLEX);
	struct lms away = { "Study", true, 0 };
	CHECK(lms_connect(&away) >= 0, "away with a held rename: no loop (stopped after %d messages)", LOOP_LIMIT);
	CHECK(!strcmp(read_file(name_path), "Study"), "the player takes the rename, got \"%s\"", read_file(name_path));
}

static void test_uuid_fills_address_line(void) {
	// a server first stamped without a UUID gets it at the next connect that has one, on its line
	write_file(name_path, "simonsMac");
	write_file(stamp_path, SERVER_A "\n");
	engine_start_uuid("x", SERVER_A, UUID_PLEX);
	struct lms lms = { "simonsMac", false, 0 };
	CHECK(lms_connect(&lms) >= 0, "no loop");
	CHECK(!strcmp(read_line(stamp_path, 1), SERVER_A " " UUID_PLEX), "the UUID joins the address's line, got \"%s\"", read_line(stamp_path, 1));
	CHECK(!read_line(stamp_path, 2)[0], "no second line, got \"%s\"", read_line(stamp_path, 2));
}

static void test_new_lms_old_address_keeps_both(void) {
	// another LMS at the old address names the player: both servers stay stamped
	write_file(name_path, "simonsMac");
	write_file(stamp_path, SERVER_A " " UUID_PLEX "\n");
	engine_start_uuid("x", SERVER_A, UUID_OTHER);
	struct lms other = { "SqueezeLiteMac", false, 0 };
	CHECK(lms_connect(&other) >= 0, "no loop");
	CHECK(!strcmp(read_line(stamp_path, 2), SERVER_A " " UUID_OTHER), "the new LMS is added, got \"%s\"", read_line(stamp_path, 2));
	engine_connect(TAILSCALE, UUID_PLEX);
	const char *answer = query();
	CHECK(answer && !answer[0], "plex, at another address, still gets the empty answer, got %s", answer ? answer : "nothing");
}

static void test_offered_server_is_stamped(void) {
	// /code-review 2026-10-15 (5) finding 1: B already has the player's name (set by hand the same on
	// two LMS, a line dropped past NAME_SERVERS, plex at an address whose UUID reply was lost), so the
	// offer changes nothing there and LMS sends nothing back. B can still hold a rename after it
	write_file(name_path, "Desk DAC");
	write_file(stamp_path, SERVER_A "\n");
	engine_start("x", SERVER_B);
	struct lms b = { "Desk DAC", false, 0 };
	int messages = lms_connect(&b);
	CHECK(messages == 1, "one engine message (the offer), LMS answers nothing, got %d", messages);
	CHECK(!strcmp(read_line(stamp_path, 2), SERVER_B), "the server offered the name is stamped, got \"%s\"", read_line(stamp_path, 2));
	CHECK(!strcmp(read_line(stamp_path, 1), SERVER_A), "the first server stays, got \"%s\"", read_line(stamp_path, 1));
	// renamed in B while it plays: held; a reconnect in this run
	strcpy(b.pref, "Study");
	b.held = true;
	messages = lms_connect(&b);
	CHECK(messages >= 0, "a reconnect: no loop (stopped after %d messages)", LOOP_LIMIT);
	CHECK(!strcmp(read_file(name_path), "Study"), "the player takes B's rename, got \"%s\"", read_file(name_path));
}

static void test_offered_server_is_stamped_restart(void) {
	// the same with the engine restarted before the stop (the stamp read back from the file)
	write_file(name_path, "Desk DAC");
	write_file(stamp_path, SERVER_A "\n");
	engine_start("x", SERVER_B);
	struct lms b = { "Desk DAC", false, 0 };
	CHECK(lms_connect(&b) >= 0, "first connect: no loop");
	strcpy(b.pref, "Study");
	b.held = true;
	name_server_count = 0;
	engine_start("x", SERVER_B);
	int messages = lms_connect(&b);
	CHECK(messages >= 0, "after a restart: no loop (stopped after %d messages)", LOOP_LIMIT);
	CHECK(!strcmp(b.pref, "Study"), "B keeps its rename, got \"%s\"", b.pref);
	CHECK(!strcmp(read_file(name_path), "Study"), "the player takes it, got \"%s\"", read_file(name_path));
}

static void test_empty_name_file_keeps_stamp(void) {
	// /code-review 2026-10-15 (5) finding 2: the name file empty, the stamp naming two servers. The
	// -n name is offered (a new player), LMS sends it back, and both servers stay stamped
	write_file(name_path, "");
	write_file(stamp_path, SERVER_A "\n" SERVER_B "\n");
	engine_start("Kitchen DAC", SERVER_A);
	struct lms a = { "Desk DAC", false, 0 };
	CHECK(lms_connect(&a) >= 0, "no loop");
	CHECK(!strcmp(read_line(stamp_path, 1), SERVER_B), "the other server stays stamped, got \"%s\"", read_line(stamp_path, 1));
	CHECK(!strcmp(read_line(stamp_path, 2), SERVER_A), "the naming server moves last, got \"%s\"", read_line(stamp_path, 2));
}

static bool exists(const char *path) {
	struct stat st;
	return stat(path, &st) == 0;
}

// the file size limit (a full disk: a file is created, its data is not written), on or back as it was.
// Lifted before any check: under scripts/test.sh stdout is a file too, so a FAILED line printed under
// the limit was lost, and the suite said only ✘ (/code-review 2026-10-15 (6) finding 6)
static struct rlimit file_size_was;
static void limit_file_size(bool on) {
	struct rlimit limit;
	if (on) {
		signal(SIGXFSZ, SIG_IGN);
		if (getrlimit(RLIMIT_FSIZE, &file_size_was) != 0) { perror("getrlimit"); exit(2); }
		limit = file_size_was;
		limit.rlim_cur = 0;
	} else {
		limit = file_size_was;
	}
	if (setrlimit(RLIMIT_FSIZE, &limit) != 0) { perror("setrlimit"); exit(2); }
}

static void test_failed_write_keeps_name(void) {
	// round (5) findings 3 and 4: a write that fails part way (a full disk; here the file size limit, so
	// the truncate works and the data does not) leaves the name and the stamp as they were
	char tmp[320];
	write_file(name_path, "Desk DAC");
	write_file(stamp_path, SERVER_A "\n");
	engine_start("x", SERVER_A);
	limit_file_size(true);
	to_engine("Study");
	engine_sent();
	limit_file_size(false);
	CHECK(!strcmp(read_file(name_path), "Desk DAC"), "the name file keeps the name it had, got \"%s\"", read_file(name_path));
	CHECK(!strcmp(read_file(stamp_path), SERVER_A), "the stamp keeps what it had, got \"%s\"", read_file(stamp_path));
	// the stamp's own write: the name stored (LMS sends it again), then another server offered it
	to_engine("Study");
	engine_sent();
	CHECK(!strcmp(read_file(name_path), "Study"), "control: the name is stored once the disk takes it, got \"%s\"",
		  read_file(name_path));
	engine_connect(SERVER_B, "");
	limit_file_size(true);
	const char *answer = query();
	limit_file_size(false);
	CHECK(answer && !strcmp(answer, "Study"), "B is offered the name, got %s", answer ? answer : "nothing");
	CHECK(!strcmp(read_file(stamp_path), SERVER_A), "a stamp write that fails keeps the stamp, got \"%s\"", read_file(stamp_path));
	snprintf(tmp, sizeof(tmp), "%s.tmp", name_path);
	CHECK(!exists(tmp), "no part-written name left beside it");
	snprintf(tmp, sizeof(tmp), "%s.tmp", stamp_path);
	CHECK(!exists(tmp), "no part-written stamp left beside it");
}

static void test_write_leaves_no_temporary(void) {
	char tmp[320];
	engine_start("Kitchen DAC", SERVER_A);
	query();
	to_engine("Kitchen DAC");
	engine_sent();
	CHECK(!strcmp(read_file(name_path), "Kitchen DAC"), "the name is stored, got \"%s\"", read_file(name_path));
	CHECK(!strcmp(read_file(stamp_path), SERVER_A), "its server is stored, got \"%s\"", read_file(stamp_path));
	snprintf(tmp, sizeof(tmp), "%s.tmp", name_path);
	CHECK(!exists(tmp), "no name.tmp left");
	snprintf(tmp, sizeof(tmp), "%s.tmp", stamp_path);
	CHECK(!exists(tmp), "no name.server.tmp left");
}

// ---- /code-review 2026-10-15 (6) ----

// LMS's end of the connection gone (the player's next send fails), then a new connection
static void connection_drops(void) {
	signal(SIGPIPE, SIG_IGN);
	close(peer);
}

static void connection_back(void) {
	int fds[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) { perror("socketpair"); exit(2); }
	sock = fds[0];
	peer = fds[1];
}

static void test_unsent_offer_stamps_nothing(void) {
	// finding 3: the offer to a server that has not named the player is not written (the connection
	// already gone), so LMS there may still hold its own name: no stamp, or the next connect's empty
	// answer would take that name (a new LMS's default, SqueezeLiteMac)
	write_file(name_path, "Desk DAC");
	write_file(stamp_path, SERVER_A "\n");
	engine_start("x", SERVER_B);
	connection_drops();
	to_engine(NULL);
	CHECK(!strcmp(read_line(stamp_path, 1), SERVER_A), "the first server stays, got \"%s\"", read_line(stamp_path, 1));
	CHECK(!read_line(stamp_path, 2)[0], "a server the offer never reached is stamped: \"%s\"", read_line(stamp_path, 2));
	connection_back();
	const char *answer = query();
	CHECK(answer && !strcmp(answer, "Desk DAC"), "the next connect offers the name again, got %s", answer ? answer : "nothing");
	CHECK(!strcmp(read_line(stamp_path, 2), SERVER_B), "control: that offer, written, stamps it, got \"%s\"", read_line(stamp_path, 2));
}

static void test_unsent_offer_of_a_new_player(void) {
	// finding 4's guard: a new player's -n offer names it only when written
	engine_start("Kitchen DAC", SERVER_A);
	connection_drops();
	to_engine(NULL);
	CHECK(!exists(name_path), "an offer LMS never got named the player \"%s\"", read_file(name_path));
	CHECK(!exists(stamp_path), "an offer LMS never got stamped \"%s\"", read_file(stamp_path));
	connection_back();
	const char *answer = query();
	CHECK(answer && !strcmp(answer, "Kitchen DAC"), "the next connect offers -n again, got %s", answer ? answer : "nothing");
}

static void test_new_player_lms_already_has(void) {
	// finding 4: LMS already has the new player's -n name (its first name write failed, or the
	// connection dropped before LMS's answer came), so the offer gets no answer; it names the player
	engine_start("Kitchen DAC", SERVER_A);
	struct lms a = { "Kitchen DAC", false, 0 };
	CHECK(lms_connect(&a) == 1, "one engine message (the offer), LMS answers nothing");
	CHECK(!strcmp(read_file(name_path), "Kitchen DAC"), "the offer names the player, got \"%s\"", read_file(name_path));
	CHECK(!strcmp(read_file(stamp_path), SERVER_A), "and stamps the server, got \"%s\"", read_file(stamp_path));
	strcpy(a.pref, "Study");                  // renamed in LMS while it plays: held; a reconnect
	a.held = true;
	int messages = lms_connect(&a);
	CHECK(messages >= 0, "a reconnect: no loop (stopped after %d messages)", LOOP_LIMIT);
	CHECK(!strcmp(read_file(name_path), "Study"), "the player takes the rename, got \"%s\"", read_file(name_path));
}

static void test_new_player_lms_already_has_restart(void) {
	// the same with the engine restarted before the stop (the rig's loop was a restart)
	engine_start("Kitchen DAC", SERVER_A);
	struct lms a = { "Kitchen DAC", false, 0 };
	CHECK(lms_connect(&a) == 1, "first connect: the offer only");
	strcpy(a.pref, "Study");
	a.held = true;
	name_server_count = 0;
	name_from_lms = false;
	engine_start("Kitchen DAC", SERVER_A);
	int messages = lms_connect(&a);
	CHECK(messages >= 0, "after a restart: no loop (stopped after %d messages)", LOOP_LIMIT);
	CHECK(!strcmp(a.pref, "Study"), "LMS keeps its rename, got \"%s\"", a.pref);
	CHECK(!strcmp(read_file(name_path), "Study"), "the player takes it, got \"%s\"", read_file(name_path));
}

static void test_fit_name(void) {
	// finding 1: a name is cut to what fgets reads back (63 bytes), at a whole UTF-8 character
	static const struct { int pad; const char *tail; int want; } rows[] = {
		{ 0, "", 0 },
		{ 63, "", 63 },                         // 63 bytes: as it is
		{ 64, "", 63 },                         // one over: cut
		{ 62, "\xc3\xa9", 62 },                 // é in bytes 62-63: the cut at 63 splits it, so it goes
		{ 61, "\xc3\xa9", 63 },                 // é in bytes 61-62: whole
		{ 61, "\xe2\x82\xac", 61 },             // € in bytes 61-63: split, goes
		{ 60, "\xe2\x82\xac", 63 },             // € in 60-62: whole
		{ 60, "\xf0\x9f\x8e\xb5", 60 },         // a 4-byte character in 60-63: split, goes
		{ 59, "\xf0\x9f\x8e\xb5", 63 },         // in 59-62: whole
		{ 3, "\xc3", 3 },                       // a short name ending inside a character (fgets)
		{ 3, "\xf0\x9f\x8e", 3 },
		{ 3, "K\xc3\xbc" "che", 9 },            // whole characters, short: as it is
	};
	for (unsigned i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
		char name[128];
		memset(name, 'a', rows[i].pad);
		strcpy(name + rows[i].pad, rows[i].tail);
		fit_name(name);
		CHECK((int)strlen(name) == rows[i].want, "row %u: %zu bytes, not %d", i, strlen(name), rows[i].want);
	}
}

static void test_long_name_is_stored_whole(void) {
	// finding 1: a name LMS sends past 64 bytes, with a character across the cut, is stored to its last
	// whole character (the app reads the file as UTF-8, and a cut character read as no name), and read
	// back and offered so
	char name[128], want[64];
	memset(name, 'a', 63);
	strcpy(name + 63, "\xc3\xbc" "ber K\xc3\xbc" "che");   // "über Küche", its ü in bytes 63-64
	memset(want, 'a', 63);
	want[63] = '\0';
	write_file(name_path, "Desk DAC");
	write_file(stamp_path, SERVER_A "\n");
	engine_start("x", SERVER_A);
	to_engine(name);
	const char *answer = engine_sent();
	CHECK(answer && !strcmp(answer, name), "control: LMS's whole name is confirmed back, got %s", answer ? answer : "nothing");
	CHECK(!strcmp(read_file(name_path), want), "stored \"%s\", not cut before the ü", read_file(name_path));
	name_server_count = 0;
	engine_start("x", SERVER_B);
	answer = query();
	CHECK(answer && !strcmp(answer, want), "read back and offered as \"%s\"", answer ? answer : "nothing");
}

static void test_cut_name_file_is_mended(void) {
	// finding 1: a file 0.4.8-0.4.11 wrote inside a character (63 bytes and the first of ü's two) is read
	// to the last whole character, and the next name LMS sends writes it again
	char file[80], name[128], want[64];
	memset(file, 'a', 63);
	strcpy(file + 63, "\xc3");
	memset(name, 'a', 63);
	strcpy(name + 63, "\xc3\xbc" "ber");
	memset(want, 'a', 63);
	want[63] = '\0';
	write_file(name_path, file);
	write_file(stamp_path, SERVER_A "\n");
	engine_start("x", SERVER_A);
	CHECK(!strcmp(player_name, want), "read as \"%s\"", player_name);
	const char *answer = query();
	CHECK(answer && !answer[0], "control: the server that named it gets the empty answer, got %s", answer ? answer : "nothing");
	to_engine(name);                         // LMS's whole name, as it sends it at that answer
	engine_sent();
	CHECK(!strcmp(read_file(name_path), want), "the file is mended to \"%s\"", read_file(name_path));
}

static void test_name_file_read_to_a_whole_character(void) {
	// finding 1: a 64-byte file of whole characters (0.4.8-0.4.11 stored 64 bytes) whose last one fgets
	// splits (it reads 63) is read to the character before, so another server is offered no cut one
	char file[80], want[64];
	memset(file, 'a', 62);
	strcpy(file + 62, "\xc3\xbc");           // ü in bytes 62-63
	memset(want, 'a', 62);
	want[62] = '\0';
	write_file(name_path, file);
	write_file(stamp_path, SERVER_A "\n");
	engine_start("x", SERVER_B);
	const char *answer = query();
	CHECK(answer && !strcmp(answer, want), "offered \"%s\", not cut before the ü", answer ? answer : "nothing");
}

static ino_t inode(const char *path) {
	struct stat st;
	return stat(path, &st) == 0 ? st.st_ino : 0;
}

static void test_unchanged_name_is_not_written(void) {
	// finding 7: LMS sends its name at every connect; a name file and a stamp that already hold it are
	// not written again (each write a flush to the disk on the slimproto thread)
	write_file(name_path, "Desk DAC");
	write_file(stamp_path, SERVER_A "\n");
	ino_t name_was = inode(name_path), stamp_was = inode(stamp_path);
	engine_start("x", SERVER_A);
	struct lms lms = { "Desk DAC", false, 0 };
	CHECK(lms_connect(&lms) == 2, "control: the empty answer and the confirmation");
	CHECK(inode(name_path) == name_was, "the name file was written again for the name it holds");
	CHECK(inode(stamp_path) == stamp_was, "the stamp was written again as it was");
	CHECK(full_syncs == 0, "%d flush(es) to the disk for nothing", full_syncs);
	to_engine("Study");                      // control: a name that changed is written
	engine_sent();
	CHECK(inode(name_path) != name_was && !strcmp(read_file(name_path), "Study"), "control: a new name was not written, got \"%s\"",
		  read_file(name_path));
}

static void test_name_reaches_the_disk(void) {
	// finding 2: each file written is flushed to the disk itself (F_FULLFSYNC), not left in its cache,
	// which a power cut can lose after the rename (an empty name file reads as a new player)
	write_file(name_path, "Desk DAC");
	write_file(stamp_path, SERVER_A "\n");
	engine_start("x", SERVER_A);
	to_engine("Study");                      // the name file; the stamp is as it was
	engine_sent();
	CHECK(full_syncs == 1, "%d F_FULLFSYNC for the name file", full_syncs);
	engine_connect(SERVER_B, "");
	query();                                 // offered: the stamp only
	CHECK(full_syncs == 2, "%d F_FULLFSYNC after the stamp", full_syncs);
	CHECK(!strcmp(read_line(stamp_path, 2), SERVER_B), "control: the stamp was written, got \"%s\"", read_line(stamp_path, 2));
}

static void test_stamp_is_bounded(void) {
	// past NAME_SERVERS the oldest is dropped; a server naming it again moves last
	char server[32];
	write_file(name_path, "Desk DAC");
	write_file(stamp_path, "10.0.1.1\n");
	engine_start("x", "10.0.1.1");
	for (int i = 2; i <= NAME_SERVERS + 1; i++) {
		snprintf(server, sizeof(server), "10.0.1.%d", i);
		engine_connect(server, "");
		query();
		to_engine("Desk DAC");
		engine_sent();
	}
	CHECK(!strcmp(read_line(stamp_path, 1), "10.0.1.2"), "the oldest dropped, got \"%s\"", read_line(stamp_path, 1));
	CHECK(!read_line(stamp_path, NAME_SERVERS + 1)[0], "%d lines at most", NAME_SERVERS);
	engine_connect("10.0.1.2", "");
	to_engine("Desk DAC");
	engine_sent();
	CHECK(!strcmp(read_line(stamp_path, NAME_SERVERS), "10.0.1.2"), "named again, it moves last, got \"%s\"", read_line(stamp_path, NAME_SERVERS));
	CHECK(!strcmp(read_line(stamp_path, 1), "10.0.1.3"), "without a duplicate, got \"%s\"", read_line(stamp_path, 1));
	engine_connect("10.0.1.1", "");
	const char *answer = query();
	CHECK(answer && !strcmp(answer, "Desk DAC"), "the dropped server is offered the name, got %s", answer ? answer : "nothing");
}

// plex's answer to e + NAME, UUID, VERS, JSON, as measured 2026-10-15
static const u8_t plex_reply[] =
	"ENAME\x0cSimons Music" "UUID\x24" UUID_PLEX "VERS\x05" "9.1.2" "JSON\x04" "9000";

static void test_parse_reply(void) {
	char uuid[SERVER_UUID_LEN + 1];
	parse_server_uuid(plex_reply, sizeof(plex_reply) - 1, uuid);
	CHECK(!strcmp(uuid, UUID_PLEX), "plex's measured reply gives its UUID, got \"%s\"", uuid);
	static const u8_t only_uuid[] = "EUUID\x24" UUID_PLEX;
	parse_server_uuid(only_uuid, sizeof(only_uuid) - 1, uuid);
	CHECK(!strcmp(uuid, UUID_PLEX), "the reply to eUUID alone, got \"%s\"", uuid);
	static const u8_t no_uuid[] = "ENAME\x0cSimons Music";
	parse_server_uuid(no_uuid, sizeof(no_uuid) - 1, uuid);
	CHECK(!uuid[0], "no UUID tag: none, got \"%s\"", uuid);
	parse_server_uuid(only_uuid, 20, uuid);
	CHECK(!uuid[0], "a value cut short: none, got \"%s\"", uuid);
	static const u8_t not_e[] = "DSimons Music";
	parse_server_uuid(not_e, sizeof(not_e) - 1, uuid);
	CHECK(!uuid[0], "the old discovery answer ('D'): none, got \"%s\"", uuid);
	static const u8_t bad_char[] = "EUUID\x04" "ab\ncd";
	parse_server_uuid(bad_char, sizeof(bad_char) - 1, uuid);
	CHECK(!uuid[0], "a value with a newline: none (it would break the stamp), got \"%s\"", uuid);
}

// a stand-in LMS on 127.0.0.1: one discovery request, answered with reply (or not, reply NULL)
struct fake_lms { int sock; u16_t port; const u8_t *reply; int reply_len; u8_t got[64]; int got_len; int requests; };

static void *fake_lms_run(void *arg) {
	struct fake_lms *f = arg;
	for (;;) {
		struct sockaddr_in from;
		socklen_t fromlen = sizeof(from);
		u8_t buf[64];
		int n = recvfrom(f->sock, buf, sizeof(buf), 0, (struct sockaddr *)&from, &fromlen);
		if (n <= 0) return NULL;
		f->requests++;
		memcpy(f->got, buf, n);
		f->got_len = n;
		if (f->reply) sendto(f->sock, f->reply, f->reply_len, 0, (struct sockaddr *)&from, fromlen);
	}
}

static void fake_lms_start(struct fake_lms *f, pthread_t *thread) {
	struct sockaddr_in addr;
	socklen_t len = sizeof(addr);
	f->sock = socket(AF_INET, SOCK_DGRAM, 0);
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = inet_addr("127.0.0.1");
	if (bind(f->sock, (struct sockaddr *)&addr, sizeof(addr)) != 0) { perror("bind"); exit(2); }
	getsockname(f->sock, (struct sockaddr *)&addr, &len);
	f->port = ntohs(addr.sin_port);
	pthread_create(thread, NULL, fake_lms_run, f);
}

static void test_ask_uuid(void) {
	struct fake_lms f = { .reply = plex_reply, .reply_len = sizeof(plex_reply) - 1 };
	pthread_t thread;
	fake_lms_start(&f, &thread);
	u32_t start = gettime_ms();
	ask_server_uuid(inet_addr("127.0.0.1"), f.port);
	u32_t took = gettime_ms() - start;
	CHECK(!strcmp(server_uuid, UUID_PLEX), "the server's answer gives its UUID, got \"%s\"", server_uuid);
	CHECK(f.got_len == 6 && !memcmp(f.got, "eUUID\0", 6), "the request is LMS's discovery 'e' + UUID, length 0 (%d bytes)", f.got_len);
	CHECK(f.requests == 1, "one request when answered, got %d", f.requests);
	CHECK(took < 200, "answered at once, took %u ms", took);
}

static void test_ask_uuid_no_answer(void) {
	struct fake_lms f = { .reply = NULL };
	pthread_t thread;
	fake_lms_start(&f, &thread);
	strcpy(server_uuid, "left from the last server");
	u32_t start = gettime_ms();
	ask_server_uuid(inet_addr("127.0.0.1"), f.port);
	u32_t took = gettime_ms() - start;
	CHECK(!server_uuid[0], "no answer: no UUID (the last server's is not kept), got \"%s\"", server_uuid);
	CHECK(f.requests == 2, "two tries, got %d", f.requests);
	CHECK(took >= 450 && took < 1000, "gives up after two 250 ms tries, took %u ms", took);
}

// ---- runner ----

struct test { const char *name; void (*run)(void); };

static const struct test tests[] = {
	{ "a new player offers its -n name and stores LMS's with its server", test_new_player },
	{ "the server that named it gets the empty answer", test_same_server },
	{ "another server is offered the name", test_other_server },
	{ "a name file without a stamp gets the empty answer", test_no_stamp },
	{ "an unreadable stamp counts as none", test_bad_stamp },
	{ "an empty name file offers the -n name", test_empty_file },
	{ "LMS's serv switch offers the name to the new server", test_serv_switch },
	{ "a name LMS sent in this run marks its server", test_name_set_in_run },
	{ "a rename held by the server that named it does not loop", test_held_rename_same_server },
	{ "a rename held at the first start without a stamp does not loop", test_held_rename_no_stamp },
	{ "a new server keeps the player's name", test_new_server_keeps_name },
	{ "the model sees the loop when the name crosses a held rename", test_model_sees_the_loop },
	{ "a reconnect with nothing held is two messages", test_unchanged_name_is_quiet },
	{ "one LMS at two addresses is one server (its UUID)", test_one_server_two_addresses },
	{ "a new LMS at the old address is another server", test_new_lms_old_address },
	{ "a server that gives no UUID is judged by its address", test_no_uuid_answer },
	{ "the stamp holds the address and the UUID", test_stamp_holds_uuid },
	{ "a rename held across an address change does not loop", test_held_rename_two_addresses },
	{ "the model loops across an address change without the UUID", test_held_rename_two_addresses_no_uuid },
	{ "a rename held by a server the player left and came back to does not loop", test_held_rename_after_another_server },
	{ "the same across an engine restart on the other server", test_held_rename_after_another_server_restarted },
	{ "a connect without a UUID answer keeps the stamp's UUID", test_lost_uuid_answer_keeps_uuid },
	{ "a UUID joins its address's line", test_uuid_fills_address_line },
	{ "a new LMS at an old address is added, the old one kept", test_new_lms_old_address_keeps_both },
	{ "a server offered a name it already has is stamped", test_offered_server_is_stamped },
	{ "the same across an engine restart before the stop", test_offered_server_is_stamped_restart },
	{ "an empty name file keeps every server in the stamp", test_empty_name_file_keeps_stamp },
	{ "a write that fails keeps the name and the stamp", test_failed_write_keeps_name },
	{ "a name stored leaves no temporary file", test_write_leaves_no_temporary },
	{ "an offer that was not sent stamps nothing", test_unsent_offer_stamps_nothing },
	{ "a new player's offer that was not sent names nothing", test_unsent_offer_of_a_new_player },
	{ "a new player whose -n name LMS already has is named by its offer", test_new_player_lms_already_has },
	{ "the same across an engine restart", test_new_player_lms_already_has_restart },
	{ "a name is cut at a whole character", test_fit_name },
	{ "a long name LMS sends is stored to its last whole character", test_long_name_is_stored_whole },
	{ "a name file cut inside a character is mended", test_cut_name_file_is_mended },
	{ "a name file is read to its last whole character", test_name_file_read_to_a_whole_character },
	{ "a name and stamp already held are not written again", test_unchanged_name_is_not_written },
	{ "a name written reaches the disk itself", test_name_reaches_the_disk },
	{ "the stamp keeps the last NAME_SERVERS servers", test_stamp_is_bounded },
	{ "LMS's discovery reply gives the UUID", test_parse_reply },
	{ "the UUID is asked of the server's own address", test_ask_uuid },
	{ "a server that does not answer gives no UUID within 500 ms", test_ask_uuid_no_answer },
};

int main(int argc, char **argv) {
	int n = sizeof(tests) / sizeof(tests[0]), passed = 0, run = 0;
	for (int i = 0; i < n; i++) {
		if (argc > 1 && !strstr(tests[i].name, argv[1])) continue;
		run++;
		fflush(stdout);
		make_dir();
		pid_t pid = fork();
		if (pid == 0) {
			alarm(10);
			setup();
			tests[i].run();
			fflush(stdout);
			_exit(failures ? 1 : 0);
		}
		int status = 0;
		waitpid(pid, &status, 0);
		remove_dir();
		bool ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
		if (ok) passed++;
		printf("%s %s%s\n", ok ? "✔" : "✘", tests[i].name,
			   WIFSIGNALED(status) ? " (crashed or timed out)" : "");
	}
	printf("%d tests, %d passed\n", run, passed);
	printf("result: %s\n", passed == run && run > 0 ? "PASS" : "FAIL");
	return passed == run && run > 0 ? 0 : 1;
}
