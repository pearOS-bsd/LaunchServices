/* lsvd_check: checks a launchservicesd against the replies of the Mac's daemon (research/docs/LAUNCHSERVICES-WIRE.md 6.5, 6.6).
 *   macOS: clang test/lsvd_check.c -o lsvd_check && __LSXPCSERVICENAME=com.pearos.t.lsd ./lsvd_check
 * One client: check-in, the info page, the record, 505/510/520, a notification listener (410) and what it receives, front list,
 * meta information, quit (590) and the Death notification, the commands that must answer false.  Exit status = number of failures.
 * Our own code (BSD-2-Clause). */
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
extern size_t xpc_shmem_map(xpc_object_t, void **region);

static xpc_connection_t c, lis;
static int fails, checks;
static int64_t codes[64]; static int ncodes;
static bool gotNop;

#define CHECK(cond, ...) do { checks++; if (!(cond)) { fails++; printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); } else { printf("ok: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

static xpc_object_t req(int64_t cmd)
{
	xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_int64(m, "command", cmd);
	xpc_dictionary_set_int64(m, "session", -2);
	return m;
}

static xpc_object_t send(xpc_object_t m) { return xpc_connection_send_message_with_reply_sync(c, m); }
static bool ok(xpc_object_t r) { return xpc_get_type(r) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_bool(r, "success"); }
static bool has_code(int64_t code) { for (int i = 0; i < ncodes; i++) if (codes[i] == code) return true; return false; }

static void wait_ms(int ms) { usleep(ms * 1000); }

int main(void)
{
	const char *svc = getenv("__LSXPCSERVICENAME");
	dispatch_queue_t q = dispatch_queue_create("lsvd_check", NULL);
	xpc_object_t m, r;

	setvbuf(stdout, NULL, _IOLBF, 0);
	c = xpc_connection_create_mach_service(svc ? svc : "com.apple.coreservices.launchservicesd", NULL, svc ? 0 : 2);
	xpc_connection_set_event_handler(c, ^(xpc_object_t e) { (void)e; });
	xpc_connection_resume(c);

	m = req(100); xpc_dictionary_set_uint64(m, "clientversion", 0x10900000);
	r = send(m);
	CHECK(ok(r) && xpc_dictionary_get_uint64(r, "serverversion") == 0x10900000, "100: serverversion 0x10900000");
	int64_t session = xpc_dictionary_get_int64(r, "session");
	CHECK(session > 0, "100: session %lld", (long long)session);

	r = send(req(110));
	xpc_object_t sh = xpc_dictionary_get_value(r, "lsinfopage");
	uint32_t *page = NULL;
	size_t n = sh ? xpc_shmem_map(sh, (void **)&page) : 0;
	CHECK(ok(r) && n >= 0xe460 && page && page[0] == 0x104 && page[1] >= 0xe460 && page[0x8c / 4] == 0x32a, "110: page %zu bytes, version 0x104, capacity 0x32a", n);

	/* a listener for every code of 6.5 before the check-in */
	lis = xpc_connection_create(NULL, q);
	xpc_connection_set_event_handler(lis, ^(xpc_object_t peer) {
		if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
		xpc_connection_set_target_queue(peer, q);
		xpc_connection_set_event_handler(peer, ^(xpc_object_t e) {
			if (xpc_get_type(e) != XPC_TYPE_DICTIONARY) return;
			if (xpc_dictionary_get_bool(e, "nop")) { gotNop = true; return; }
			if (ncodes < 64) codes[ncodes++] = xpc_dictionary_get_int64(e, "code");
		});
		xpc_connection_resume(peer);
	});
	xpc_connection_resume(lis);
	m = req(410);
	xpc_dictionary_set_value(m, "listener", xpc_endpoint_create(lis));
	xpc_dictionary_set_bool(m, "needsassertions", false);
	xpc_dictionary_set_uint64(m, "clientid", 4242);
	xpc_object_t set = xpc_array_create(NULL, 0);
	int64_t want[] = { 0x101, 0x102, 0x109, 0x10d, 0x110, 0x113, 0x1a0, 0x221, 0x222, 0x231 };
	for (size_t i = 0; i < sizeof want / sizeof want[0]; i++) xpc_array_append_value(set, xpc_uint64_create((uint64_t)want[i]));
	xpc_dictionary_set_value(m, "set", set);
	r = send(m);
	uint64_t nid = xpc_dictionary_get_uint64(r, "id");
	CHECK(ok(r) && nid != 0 && xpc_dictionary_get_int64(r, "session") == session && !xpc_dictionary_get_value(r, "affectedasns"), "410: id %llu, session, no affectedasns", (unsigned long long)nid);
	wait_ms(300);
	CHECK(gotNop && has_code(0x7ffffffd), "410: listener got nop and ResetSequenceNumber");

	m = req(500);
	xpc_object_t info = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(info, "LSDisplayName", "lsvdcheck");
	xpc_dictionary_set_string(info, "CFBundleExecutablePath", "/bin/sh");
	xpc_dictionary_set_string(info, "ApplicationType", "Foreground");
	xpc_dictionary_set_string(info, "CFBundleIdentifier", "com.pearos.LSVDCheck");
	xpc_dictionary_set_value(m, "info", info);
	mach_port_t dp; mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &dp);
	mach_port_insert_right(mach_task_self(), dp, dp, MACH_MSG_TYPE_MAKE_SEND);
	xpc_dictionary_set_mach_send(m, "deathport", dp);
	r = send(m);
	xpc_object_t rec = xpc_dictionary_get_value(r, "result");
	xpc_object_t asnd = rec ? xpc_dictionary_get_value(rec, "LSASN") : NULL;
	uint64_t asn = asnd ? xpc_dictionary_get_uint64(asnd, "com.apple.coreservices.asn.lo") : 0;
	static const unsigned char marker[16] = { 0xc9, 0x61, 0x72, 0xa0, 0xce, 0x74, 0x4d, 0x62, 0xaf, 0xef, 0xec, 0xfe, 0x4d, 0x04, 0xd8, 0x27 };
	const uint8_t *u = asnd ? xpc_dictionary_get_uuid(asnd, "com.apple.coreservices.asn") : NULL;
	CHECK(ok(r) && asn && u && !memcmp(u, marker, 16) && xpc_dictionary_get_uint64(asnd, "com.apple.coreservices.asn.hi") == 0, "500: LSASN {lo 0x%llx, hi 0, marker uuid}", (unsigned long long)asn);
	CHECK(rec && xpc_dictionary_get_int64(rec, "pid") == getpid() && xpc_dictionary_get_bool(rec, "LSApplicationHasRegistered") && xpc_dictionary_get_bool(rec, "Hidden") == false
		&& xpc_dictionary_get_value(rec, "Hidden") && xpc_dictionary_get_value(rec, "LSAuditToken") && xpc_dictionary_get_int64(rec, "ChangeCount") >= 514
		&& rec && xpc_dictionary_get_string(rec, "BundleIdentifierLowerCase") && !strcmp(xpc_dictionary_get_string(rec, "BundleIdentifierLowerCase"), "com.pearos.lsvdcheck")
		&& xpc_dictionary_get_string(rec, "LSExecutableFilenameLowerCaseKey") && xpc_dictionary_get_value(rec, "CFBundleExecutablePathINode"), "500: record keys (pid, LSApplicationHasRegistered, Hidden, LSAuditToken, ChangeCount, lower-case keys, inode)");
	int64_t cc = rec ? xpc_dictionary_get_int64(rec, "ChangeCount") : 0;
	unsigned cnt = page[0x88 / 4], i;
	uint32_t *pr = NULL;
	for (i = 0; i < cnt; i++) if (page[(0x90 + i * 0x48) / 4] == (uint32_t)asn) pr = page + (0x90 + i * 0x48) / 4;
	CHECK(pr && pr[4] == (uint32_t)getpid() && pr[2] == 0x80 && pr[1] == (uint32_t)cc, "page: record of the check-in (pid, flags 0x80, ChangeCount) read live from the mapped page");

	r = send(req(505));
	CHECK(ok(r) && xpc_dictionary_get_value(r, "result"), "505: the caller's record");

	m = req(360); xpc_dictionary_set_uint64(m, "asn", asn);
	xpc_object_t keys = xpc_array_create(NULL, 0); xpc_array_append_value(keys, xpc_string_create("pid")); xpc_array_append_value(keys, xpc_string_create("Nope"));
	xpc_dictionary_set_value(m, "restrictto", keys);
	r = send(m);
	CHECK(ok(r) && !xpc_dictionary_get_bool(r, "cacheable") && xpc_dictionary_get_count(xpc_dictionary_get_value(r, "result")) == 1, "360 restrictto: only the keys that exist, cacheable false");
	m = req(360); xpc_dictionary_set_uint64(m, "asn", (1ULL << 32) | (uint64_t)getpid());
	r = send(m);
	CHECK(ok(r) && xpc_dictionary_get_bool(r, "cacheable"), "360 with a pid ASN (hi 1): whole record, cacheable true");

	m = req(510); xpc_dictionary_set_uint64(m, "asn", asn);
	info = xpc_dictionary_create(NULL, NULL, 0); xpc_dictionary_set_bool(info, "LSNotifyApplicationFrontable", true);
	xpc_dictionary_set_value(m, "info", info);
	r = send(m);
	xpc_object_t ri = xpc_dictionary_get_value(r, "info");
	CHECK(ok(r) && ri && xpc_dictionary_get_bool(ri, "LSApplicationReadyToBeFrontableKey") && !xpc_dictionary_get_value(ri, "LSNotifyApplicationFrontable") && xpc_dictionary_get_int64(ri, "ChangeCount") == cc + 2,
		"510 frontable: LSApplicationReadyToBeFrontableKey, ChangeCount +2");
	CHECK(pr && (pr[2] & 0x4000) && (pr[3] & 0xffff) >= 1, "page: flags 0x4000 and a place in the visible order");
	m = req(520); xpc_dictionary_set_uint64(m, "asn", asn);
	r = send(m);
	CHECK(ok(r) && pr && (pr[2] & 0x40), "520: ready (page flags 0x40)");
	m = req(510); xpc_dictionary_set_uint64(m, "asn", asn);
	info = xpc_dictionary_create(NULL, NULL, 0); xpc_dictionary_set_string(info, "ApplicationType", "UIElement");
	xpc_dictionary_set_value(m, "info", info);
	r = send(m); ri = xpc_dictionary_get_value(r, "info");
	CHECK(ok(r) && ri && xpc_dictionary_get_bool(ri, "CanBecomeFrontmost") && pr && (pr[2] & 0x20) && (pr[3] & 0xffff) == 0, "510 ApplicationType UIElement: CanBecomeFrontmost, page flags 0x20, out of the visible order");

	r = send(req(310));
	CHECK(ok(r) && xpc_dictionary_get_value(r, "seed") && xpc_array_get_count(xpc_dictionary_get_value(r, "result")) >= 1, "310: applications + seed");
	m = req(200); keys = xpc_array_create(NULL, 0); xpc_array_append_value(keys, xpc_string_create("LSSessionID")); xpc_array_append_value(keys, xpc_string_create("LSFooMeta"));
	xpc_dictionary_set_value(m, "wanted", keys);
	r = send(m);
	xpc_object_t meta = xpc_dictionary_get_value(r, "metainfo");
	CHECK(ok(r) && meta && xpc_dictionary_get_count(meta) == 1 && xpc_dictionary_get_int64(meta, "LSSessionID") == session, "200: only the wanted keys it knows");
	m = req(130); xpc_dictionary_set_uint64(m, "asn1", asn); xpc_dictionary_set_uint64(m, "asn2", asn);
	r = send(m);
	CHECK(ok(r) && xpc_dictionary_get_int64(r, "result") == 0, "130: same ASN -> result 0");
	m = req(910); xpc_dictionary_set_uint64(m, "asn", asn);
	r = send(m);
	CHECK(getuid() == 0 || (!ok(r) && xpc_dictionary_get_int64(r, "errno") == -54), "910 from a plain user: errno -54");
	r = send(req(600));
	CHECK(ok(r) && xpc_dictionary_get_int64(r, "error") == -600, "600 without pid: error -600, success true");
	r = send(req(597));
	CHECK(!ok(r) && xpc_dictionary_get_bool(r, "resendfullinfo"), "597: resendfullinfo");
	int64_t falses[] = { 595, 1010, 12345 };
	for (size_t k = 0; k < 3; k++) { r = send(req(falses[k])); CHECK(xpc_get_type(r) == XPC_TYPE_DICTIONARY && !ok(r), "%lld: success false", (long long)falses[k]); }
	r = send(req(98));
	CHECK(ok(r), "98: success true");

	m = req(590); xpc_dictionary_set_uint64(m, "asn", asn); xpc_dictionary_set_int64(m, "exitstatus", 0);
	r = send(m);
	CHECK(ok(r), "590: quitting");
	m = req(360); xpc_dictionary_set_uint64(m, "asn", asn);
	r = send(m);
	CHECK(!ok(r), "360 after 590: gone");
	wait_ms(300);
	CHECK(has_code(0x109) && has_code(0x101) && has_code(0x1a0) && has_code(0x113) && has_code(0x110) && has_code(0x231) && has_code(0x102) && has_code(0x10d),
		"listener: Creation, Birth, StartedFromStoppedState, RegisteredForCGEvents, Ready, TypeChanged, Death, Exited");
	m = req(420); xpc_dictionary_set_uint64(m, "id", nid);
	r = send(m);
	CHECK(ok(r), "420: listener removed");
	printf("%d checks, %d failures\n", checks, fails);
	return fails;
}
