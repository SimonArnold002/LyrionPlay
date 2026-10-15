/*
 * (c) 2026 CrystalGipsy, for LyrionPlay. GNU General Public License v3 or later, as the
 * engine it tests (../LICENSE.txt).
 *
 * Regression suite for the player name in slimproto.c (LMS OWNS THE PLAYER NAME): what the engine
 * answers to LMS's name query, what it stores when LMS sends a name, and the server that name came
 * from (the -N file's ".server": its address and LMS server_uuid, asked at each connect by
 * ask_server_uuid, here against a stand-in LMS on 127.0.0.1).
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
 * Each test runs in its own child process (fresh statics) with a timeout. Prints one line per test
 * and a summary line; exits 0 only if every test passed.
 *
 * Build and run: make -f Makefile.coreaudio tests/test_slimproto_name && ./tests/test_slimproto_name
 * Against an older copy (anti-run), into another file:
 *   cc ... -DNAME_SOURCE='"/path/old_slimproto.c"' -o /tmp/t tests/test_slimproto_name.c utils.c
 */

#ifndef NAME_SOURCE
#define NAME_SOURCE "../slimproto.c"
#endif
#include NAME_SOURCE

#include <sys/wait.h>
#include <sys/stat.h>
#include <signal.h>
#include <pthread.h>

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


static void setup(void) {
	int fds[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) { perror("socketpair"); exit(2); }
	sock = fds[0];
	peer = fds[1];
	loglevel = lERROR;
	snprintf(dir, sizeof(dir), "%s/lyrionplay-name-XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
	if (!mkdtemp(dir)) { perror("mkdtemp"); exit(2); }
	snprintf(name_path, sizeof(name_path), "%s/name", dir);
	snprintf(stamp_path, sizeof(stamp_path), "%s/name.server", dir);
}

static void teardown(void) {
	unlink(name_path);
	unlink(stamp_path);
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
	static char name[PLAYER_NAME_LEN + 2];
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
	u8_t pkt[5 + PLAYER_NAME_LEN + 1];
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
	CHECK(!strcmp(read_file(stamp_path), SERVER_B), "the new server's name stamps it, got \"%s\"", read_file(stamp_path));
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
	CHECK(!strcmp(read_file(stamp_path), SERVER_B), "the new server stamps it, got \"%s\"", read_file(stamp_path));
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
	write_file(stamp_path, SERVER_A "\n" UUID_PLEX "\n");
	engine_start_uuid("x", TAILSCALE, UUID_PLEX);
	const char *answer = query();
	CHECK(answer && !answer[0], "the same LMS at another address gets the empty answer, got %s", answer ? answer : "nothing");
}

static void test_new_lms_old_address(void) {
	write_file(name_path, "simonsMac");
	write_file(stamp_path, SERVER_A "\n" UUID_PLEX "\n");
	engine_start_uuid("x", SERVER_A, UUID_OTHER);
	const char *answer = query();
	CHECK(answer && !strcmp(answer, "simonsMac"), "another LMS at the old address is offered the name, got %s", answer ? answer : "nothing");
}

static void test_no_uuid_answer(void) {
	write_file(name_path, "simonsMac");
	write_file(stamp_path, SERVER_A "\n" UUID_PLEX "\n");
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
	CHECK(!strcmp(read_line(stamp_path, 1), SERVER_A), "the stamp's first line is the address, got \"%s\"", read_line(stamp_path, 1));
	CHECK(!strcmp(read_line(stamp_path, 2), UUID_PLEX), "its second the UUID, got \"%s\"", read_line(stamp_path, 2));
	// read back at the next start, at another address
	name_server_ip = 0; name_server_uuid[0] = '\0';
	engine_start_uuid("Kitchen DAC", TAILSCALE, UUID_PLEX);
	const char *answer = query();
	CHECK(answer && !answer[0], "read back, the same UUID at another address: empty, got %s", answer ? answer : "nothing");
}

static void test_held_rename_two_addresses(void) {
	// named over the LAN, renamed in LMS while playing, reconnected over Tailscale before it stopped
	write_file(name_path, "simonsMac");
	write_file(stamp_path, SERVER_A "\n" UUID_PLEX "\n");
	engine_start_uuid("x", TAILSCALE, UUID_PLEX);
	struct lms lms = { "Study", true, 0 };
	int messages = lms_connect(&lms);
	CHECK(messages >= 0, "no loop (stopped after %d messages)", LOOP_LIMIT);
	CHECK(!strcmp(read_file(name_path), "Study"), "the player takes LMS's rename, got \"%s\"", read_file(name_path));
}

static void test_held_rename_two_addresses_no_uuid(void) {
	// control: the same without a UUID answer is the loop the UUID prevents
	write_file(name_path, "simonsMac");
	write_file(stamp_path, SERVER_A "\n" UUID_PLEX "\n");
	engine_start("x", TAILSCALE);
	struct lms lms = { "Study", true, 0 };
	CHECK(lms_connect(&lms) == -1, "without the UUID, the address change crosses the held rename");
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
		pid_t pid = fork();
		if (pid == 0) {
			alarm(10);
			setup();
			tests[i].run();
			teardown();
			fflush(stdout);
			_exit(failures ? 1 : 0);
		}
		int status = 0;
		waitpid(pid, &status, 0);
		bool ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
		if (ok) passed++;
		printf("%s %s%s\n", ok ? "✔" : "✘", tests[i].name,
			   WIFSIGNALED(status) ? " (crashed or timed out)" : "");
	}
	printf("%d tests, %d passed\n", run, passed);
	printf("result: %s\n", passed == run && run > 0 ? "PASS" : "FAIL");
	return passed == run && run > 0 ? 0 : 1;
}
