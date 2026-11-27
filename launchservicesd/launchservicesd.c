/* launchservicesd: the Launch Services session daemon (Mach service com.apple.coreservices.launchservicesd), wire-compatible with macOS 26.7.2.
 *
 * Plain XPC dictionaries: every request has "command" (int64) and "session" (int64, -2 = the session of the caller); every reply has "success".
 * One daemon for all sessions (it runs as root, like the Mac's).  Per session: the shared info page (lsinfopage, 0xf000 bytes, written in place
 * and read live by every client), the application records (one per checked-in process), the front application, the menu bar owner, the
 * front-to-back order of the visible applications, the meta information, and the notification listeners (command 410).
 *
 * Protocol, page layout, notification codes and the evidence of every value: research/docs/LAUNCHSERVICES-WIRE.md section 6
 * (github.com/pearOS-bsd/research), captured from the Mac's daemon with research/tools/launchservices/probes/lsx.c.
 * Our own code (BSD-2-Clause). */
#if __has_include(<xpc/xpc.h>)
#include <xpc/xpc.h>
extern void xpc_connection_get_audit_token(xpc_connection_t, audit_token_t *);
extern mach_port_t xpc_dictionary_copy_mach_send(xpc_object_t, const char *);
#else
#include "compat/lsvd_xpc.h"
#endif
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <unistd.h>

#define SERVER_VERSION		0x10900000ULL	/* the client checks serverversion == its own 0x10900000 */
#define PAGE_SIZE_LS		0xf000		/* round_page(0xe460) */
#define PAGE_VERSION		0x104
#define PAGE_CAPACITY		0x32a
#define PAGE_RECORDS		0x90
#define PAGE_RECORD_SIZE	0x48
#define FIRST_CHANGE_COUNT	514		/* ChangeCount of a fresh check-in (514..516 seen on the Mac) */
/* audit_token_t: val[0] auid, [1] euid, [2] egid, [3] ruid, [4] rgid, [5] pid, [6] asid, [7] pid version (what libbsm's audit_token_to_* read; libbsm itself is not linked) */
#define TOKEN_AUID(t)		((uid_t)(t).val[0])
#define TOKEN_EUID(t)		((uid_t)(t).val[1])
#define TOKEN_PIDVERSION(t)	((int)(t).val[7])
#define UID_WINDOWSERVER	88		/* _windowserver: with root, the only callers that may set the front application */

/* LSNotificationCode (decompiled: launchservicesd asString(LSNotificationCode)) */
enum {
	kLSNotifyApplicationLaunch = 0x100, kLSNotifyApplicationBirth = 0x101, kLSNotifyApplicationDeath = 0x102,
	kLSNotifyApplicationCreation = 0x109, kLSNotifyApplicationExitedIncludingSubordinateProcesses = 0x10d,
	kLSNotifyApplicationReady = 0x110, kLSNotifyApplicationRegisteredForCGEvents = 0x113,
	kLSNotifyBecameFrontmost = 0x200, kLSNotifyLostFrontmost = 0x201,
	kLSNotifyBringForwardRequest = 0x203, kLSNotifyMenuBarAcquired = 0x204, kLSNotifyMenuBarLost = 0x205,
	kLSNotifyApplicationHidden = 0x210, kLSNotifyApplicationShown = 0x211,
	kLSNotifyApplicationInformationKeyAdded = 0x221, kLSNotifyApplicationInformationKeyChanged = 0x222,
	kLSNotifyApplicationInformationKeyRemoved = 0x223, kLSNotifyApplicationTypeChanged = 0x231,
	kLSNotifyApplicationNameChanged = 0x232, kLSNotifyApplicationStartedFromStoppedState = 0x1a0, kLSNotifySystemProcessRegistered = 0x194, kLSNotifySystemProcessUnregistered = 0x195,
	kLSNotifyNotificationResetSequenceNumber = 0x7ffffffd, kLSNotifyAllNotifications = -1,
};

/* record flags of the page (+0x08), observed on the Mac for each state (LAUNCHSERVICES-WIRE.md 6.3) */
enum { F_HIDDEN = 0x1, F_QUITTING = 0x2, F_BACKGROUNDONLY = 0x10, F_UIELEMENT = 0x20, F_READY = 0x40, F_REGISTERED = 0x80, F_FRONTABLE = 0x4000 };

/* the marker uuid of an LSASN dictionary: LaunchServices reads a dictionary as an ASN only with it */
static const unsigned char kASNUUID[16] = { 0xc9, 0x61, 0x72, 0xa0, 0xce, 0x74, 0x4d, 0x62, 0xaf, 0xef, 0xec, 0xfe, 0x4d, 0x04, 0xd8, 0x27 };

struct session;

struct app {
	struct app *next;
	struct session *s;
	uint32_t asn;			/* the low half; the high half is 0 */
	pid_t pid;
	int pidversion;
	uint32_t flags;
	xpc_object_t info;		/* the record (360/505/510 replies) */
	int64_t changes;		/* ChangeCount */
	xpc_object_t modifiers;		/* launch modifiers (370/380/600) */
	bool modifiersReturned;
	dispatch_source_t procSource, deathSource;
	mach_port_t deathPort;
	bool gone;
};

struct listener {
	struct listener *next;
	struct session *s;
	uint64_t id, clientid, msgid;
	xpc_connection_t conn;
	pid_t pid;
	int64_t *codes; size_t ncodes;
	uint32_t *asns; size_t nasns;
	bool dead;			/* dropped: the connection's last event (invalid) frees it */
};

struct dead {			/* death information (700) */
	pid_t pid;
	xpc_object_t info;
};

struct session {
	struct session *next;
	int id;
	uint32_t *page;
	struct app *apps;		/* check-in order */
	uint32_t visible[PAGE_CAPACITY]; size_t nvisible;	/* front to back */
	uint32_t front, menubar, systemProcess;
	xpc_object_t meta;		/* settable meta information (210) */
	struct listener *listeners;
	struct dead dead[32]; int ndead;
};

static dispatch_queue_t gQ;
static struct session *gSessions;
static uint32_t gNextASN = 1;		/* ASN low halves are k * 0x1001, as the Mac's daemon gives them */
static uint64_t gNextListener = 10000;
static bool gLog;

#define LOG(...) do { if (gLog) { fprintf(stderr, "launchservicesd: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

static double now_abs(void) { return CFAbsoluteTimeGetCurrent(); }

/* ---------------------------------------------------------------- the info page */

static uint32_t *page_word(struct session *s, unsigned off) { return s->page + off / 4; }
static uint32_t *page_rec(struct session *s, unsigned i) { return s->page + (PAGE_RECORDS + i * PAGE_RECORD_SIZE) / 4; }

static void page_init(struct session *s)
{
	void *p = mmap(NULL, PAGE_SIZE_LS, PROT_READ | PROT_WRITE, MAP_ANON | MAP_SHARED, -1, 0);

	if (p == MAP_FAILED) { s->page = calloc(1, PAGE_SIZE_LS); } else { memset(p, 0, PAGE_SIZE_LS); s->page = p; }
	*page_word(s, 0x00) = PAGE_VERSION;
	*page_word(s, 0x04) = PAGE_SIZE_LS;
	*page_word(s, 0x08) = (uint32_t)s->id;
	for (unsigned o = 0x20; o <= 0x34; o += 4) *page_word(s, o) = 100;		/* the seeds start at 100 */
	*page_word(s, 0x68) = getenv("LSVD_CGS_SESSION") ? (uint32_t)atoi(getenv("LSVD_CGS_SESSION")) : 0x101;	/* CGSSessionID: the window server session */
	*page_word(s, 0x8c) = PAGE_CAPACITY;
}

static void seed(struct session *s, unsigned off, uint32_t n) { *page_word(s, off) += n; }
enum { SEED_FRONT = 0x20, SEED_MENUBAR = 0x24, SEED_LIST = 0x28, SEED_VISIBLE = 0x30, SEED_INFO = 0x34 };

static int visible_pos(struct session *s, uint32_t asn)
{
	for (size_t i = 0; i < s->nvisible; i++) if (s->visible[i] == asn) return (int)i + 1;
	return 0;
}

static uint64_t cfhash_str(const char *str)
{
	if (str == NULL) return 0;
	CFStringRef c = CFStringCreateWithCString(NULL, str, kCFStringEncodingUTF8);
	uint64_t h = c ? CFHash(c) : 0;
	if (c) CFRelease(c);
	return h == 0 ? 1 : h;
}

static void stat_path(const char *p, int32_t *dev, uint64_t *ino)
{
	struct stat st;
	*dev = 0; *ino = 0;
	if (p && stat(p, &st) == 0) { *dev = (int32_t)st.st_dev; *ino = (uint64_t)st.st_ino; }
}

/* write the record of one application (LSSharedMemoryPage::SetApplicationInformation: ChangeCount first to 0 and last to its value, inside the lock count) */
static void page_write_app(struct app *a, unsigned i)
{
	struct session *s = a->s;
	uint32_t *r = page_rec(s, i);
	int32_t bdev, edev; uint64_t bino, eino;
	uint64_t h;

	(*page_word(s, 0x0c))++;
	r[1] = 0;
	r[0] = a->asn;
	r[2] = a->flags;
	r[3] = (uint32_t)visible_pos(s, a->asn) & 0xffff;
	r[4] = (uint32_t)a->pid;
	r[5] = (uint32_t)a->pidversion;
	h = xpc_dictionary_get_string(a->info, "CFBundleIdentifier") ? cfhash_str(xpc_dictionary_get_string(a->info, "CFBundleIdentifier")) : 0;
	memcpy(r + 6, &h, 8);
	h = cfhash_str(xpc_dictionary_get_string(a->info, "LSDisplayName"));
	memcpy(r + 8, &h, 8);
	stat_path(xpc_dictionary_get_string(a->info, "LSBundlePath"), &bdev, &bino);
	stat_path(xpc_dictionary_get_string(a->info, "CFBundleExecutablePath"), &edev, &eino);
	r[10] = (uint32_t)bdev; memcpy(r + 12, &bino, 8);
	r[14] = (uint32_t)edev; memcpy(r + 16, &eino, 8);
	r[1] = (uint32_t)a->changes;
	(*page_word(s, 0x0c))--;
}

/* rewrite every record (after an add, a removal - the array is compacted - or an order change) */
static void page_rewrite(struct session *s)
{
	unsigned n = 0;
	for (struct app *a = s->apps; a; a = a->next) if (!a->gone && n < PAGE_CAPACITY) page_write_app(a, n++);
	for (unsigned i = n; i < *page_word(s, 0x88) && i < PAGE_CAPACITY; i++) memset(page_rec(s, i), 0, PAGE_RECORD_SIZE);
	*page_word(s, 0x88) = n;
	*page_word(s, 0x50) = s->front;
	*page_word(s, 0x54) = s->menubar;
	*page_word(s, 0x58) = s->systemProcess;
}

static void page_update_app(struct app *a)
{
	unsigned n = 0;
	for (struct app *b = a->s->apps; b; b = b->next) { if (b->gone) continue; if (b == a) { page_write_app(a, n); return; } n++; }
}

/* ---------------------------------------------------------------- sessions and ASNs */

static struct session *session_get(int id)
{
	struct session *s;
	for (s = gSessions; s; s = s->next) if (s->id == id) return s;
	s = calloc(1, sizeof *s);
	s->id = id;
	s->meta = xpc_dictionary_create(NULL, NULL, 0);
	page_init(s);
	s->next = gSessions; gSessions = s;
	LOG("session %d created", id);
	return s;
}

/* the session of a request: -2 (or absent) = the caller's audit session; another one only for root */
static struct session *session_for(xpc_connection_t peer, xpc_object_t m)
{
	int own = (int)xpc_connection_get_asid(peer);
	int64_t want = xpc_dictionary_get_int64(m, "session");
	if (want > 0 && want != own && xpc_connection_get_euid(peer) == 0) return session_get((int)want);
	return session_get(own);
}

static xpc_object_t asn_dict(uint32_t lo)
{
	xpc_object_t d = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_uint64(d, "com.apple.coreservices.asn.lo", lo);
	xpc_dictionary_set_value(d, "com.apple.coreservices.asn", xpc_uuid_create(kASNUUID));
	xpc_dictionary_set_uint64(d, "com.apple.coreservices.asn.hi", 0);
	return d;
}

static struct app *app_by_asn(struct session *s, uint32_t lo)
{
	for (struct app *a = s->apps; a; a = a->next) if (!a->gone && a->asn == lo) return a;
	return NULL;
}

static struct app *app_by_pid(struct session *s, pid_t pid)
{
	for (struct app *a = s->apps; a; a = a->next) if (!a->gone && a->pid == pid) return a;
	return NULL;
}

/* an "asn" number of a request: hi << 32 | lo; hi 1 = a pid ASN (lo is a pid), hi 0 lo 2 = the current application (the caller) */
static struct app *app_resolve(struct session *s, uint64_t asn, pid_t caller)
{
	uint32_t hi = (uint32_t)(asn >> 32), lo = (uint32_t)asn;
	if (hi == 1) return app_by_pid(s, (pid_t)lo);
	if (hi == 0 && lo == 2) return app_by_pid(s, caller);
	if (hi == 0 && lo != 0) return app_by_asn(s, lo);
	return NULL;
}

static bool is_privileged(xpc_connection_t peer)
{
	audit_token_t t;
	memset(&t, 0, sizeof t);
	xpc_connection_get_audit_token(peer, &t);
	uid_t e = TOKEN_EUID(t), au = TOKEN_AUID(t);
	return e == 0 || au == 0 || e == UID_WINDOWSERVER || au == UID_WINDOWSERVER;
}

static const char *app_type(struct app *a)
{
	const char *t = xpc_dictionary_get_string(a->info, "ApplicationType");
	return t ? t : "Foreground";
}

static bool is_foreground(struct app *a) { return strcmp(app_type(a), "Foreground") == 0; }

static void app_flags(struct app *a)
{
	uint32_t f = a->flags & (F_READY | F_FRONTABLE | F_QUITTING | F_REGISTERED);
	const char *t = app_type(a);
	if (!strcmp(t, "BackgroundOnly")) f |= F_BACKGROUNDONLY;
	else if (!strcmp(t, "UIElement")) f |= F_UIELEMENT;
	if (is_foreground(a) && xpc_dictionary_get_bool(a->info, "Hidden")) f |= F_HIDDEN;
	a->flags = f;
}

/* the visible list: foreground applications that said they can be front (LSNotifyApplicationFrontable), front to back; a new one goes to the back */
static bool visible_sync(struct app *a)
{
	struct session *s = a->s;
	bool want = !a->gone && is_foreground(a) && (a->flags & F_FRONTABLE);
	int pos = visible_pos(s, a->asn);
	if (want && !pos && s->nvisible < PAGE_CAPACITY) { s->visible[s->nvisible++] = a->asn; return true; }
	if (!want && pos) { memmove(s->visible + pos - 1, s->visible + pos, (s->nvisible - pos) * sizeof s->visible[0]); s->nvisible--; return true; }
	return false;
}

/* ---------------------------------------------------------------- notifications (LSNotification::Send) */

static void listener_send(struct listener *l, int64_t code, xpc_object_t info, uint32_t affected, bool hasAffected)
{
	xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_uint64(m, "msgid", l->msgid++);
	if (info) { xpc_object_t c = xpc_copy(info); xpc_dictionary_set_value(m, "info", c); xpc_release(c); }	/* a snapshot: the record changes later */
	xpc_dictionary_set_uint64(m, "id", l->id);
	xpc_dictionary_set_int64(m, "code", code);
	xpc_dictionary_set_uint64(m, "clientid", l->clientid);
	xpc_dictionary_set_int64(m, "session", l->s->id);
	xpc_dictionary_set_double(m, "when", now_abs());
	if (hasAffected) xpc_dictionary_set_uint64(m, "affected", affected);
	xpc_connection_send_message(l->conn, m);
	xpc_release(m);
}

static bool listener_wants(struct listener *l, int64_t code, uint32_t affected, bool hasAffected)
{
	bool c = false;
	for (size_t i = 0; i < l->ncodes; i++) if (l->codes[i] == code || l->codes[i] == kLSNotifyAllNotifications || l->codes[i] == 0xffffffffLL) { c = true; break; }
	if (!c) return false;
	if (l->nasns == 0 || !hasAffected) return true;		/* an ASN filter (addasn) only lets through the notifications about those applications */
	for (size_t i = 0; i < l->nasns; i++) if (l->asns[i] == affected) return true;
	return false;
}

static void notify(struct session *s, int64_t code, xpc_object_t info, uint32_t affected, bool hasAffected)
{
	for (struct listener *l = s->listeners; l; l = l->next)
		if (!l->dead && listener_wants(l, code, affected, hasAffected)) listener_send(l, code, info, affected, hasAffected);
	LOG("notification 0x%llx affected 0x%x", (long long)code, hasAffected ? affected : 0);
}

static void notify_app(struct app *a, int64_t code, xpc_object_t info) { notify(a->s, code, info, a->asn, true); }

/* the small info of a key notification: the key, its value, LSASN, ChangeCount (and LSPreviousValue for a change) */
static void notify_key(struct app *a, const char *key, xpc_object_t value, xpc_object_t previous, int64_t specific)
{
	xpc_object_t info = xpc_dictionary_create(NULL, NULL, 0);
	int64_t generic = previous == NULL ? kLSNotifyApplicationInformationKeyAdded : value == NULL ? kLSNotifyApplicationInformationKeyRemoved : kLSNotifyApplicationInformationKeyChanged;
	xpc_dictionary_set_string(info, previous == NULL ? "LSKeyBeingAdded" : value == NULL ? "LSKeyBeingRemoved" : "LSKeyBeingChanged", key);
	if (value) xpc_dictionary_set_value(info, key, value);
	if (previous) xpc_dictionary_set_value(info, "LSPreviousValue", previous);
	xpc_dictionary_set_value(info, "LSASN", asn_dict(a->asn));
	xpc_dictionary_set_int64(info, "ChangeCount", a->changes);
	if (specific) notify_app(a, specific, info);
	notify_app(a, generic, info);
	xpc_release(info);
}

/* front changes: kLSNotifyBecameFrontmost / LostFrontmost with the seeds and both ASNs, then MenuBarAcquired / Lost */
static void front_info(xpc_object_t info, struct session *s, struct app *a, uint32_t other, bool full)
{
	if (full && xpc_dictionary_get_string(a->info, "CFBundleIdentifier")) xpc_dictionary_set_string(info, "CFBundleIdentifier", xpc_dictionary_get_string(a->info, "CFBundleIdentifier"));
	xpc_dictionary_set_int64(info, "LSMenuBarOwnerApplicationSeed", *page_word(s, SEED_MENUBAR));
	xpc_dictionary_set_value(info, "LSASN", asn_dict(a->asn));
	if (full) {
		xpc_dictionary_set_int64(info, "LSFrontApplicationSeed", *page_word(s, SEED_FRONT));
		if (s->menubar) xpc_dictionary_set_value(info, "LSMenuBarOwnerASN", asn_dict(s->menubar));
	}
	if (other) xpc_dictionary_set_value(info, "LSOtherASN", asn_dict(other));
	if (full) xpc_dictionary_set_string(info, "ApplicationType", app_type(a));
}

static void set_front(struct session *s, struct app *a)
{
	struct app *old = s->front ? app_by_asn(s, s->front) : NULL;
	struct app *oldmb = s->menubar ? app_by_asn(s, s->menubar) : NULL;
	int pos;

	if (old == a) return;
	s->front = a->asn;
	seed(s, SEED_FRONT, 1);
	if (is_foreground(a)) { s->menubar = a->asn; seed(s, SEED_MENUBAR, 1); }
	if ((pos = visible_pos(s, a->asn)) > 1) {	/* to the front of the order */
		memmove(s->visible + 1, s->visible, (pos - 1) * sizeof s->visible[0]);
		s->visible[0] = a->asn;
		seed(s, SEED_VISIBLE, 1);
	}
	if (xpc_dictionary_get_bool(a->info, "LSApplicationInThrottledStateAfterLaunchKey")) xpc_dictionary_set_bool(a->info, "LSApplicationInThrottledStateAfterLaunchKey", false);
	page_rewrite(s);
	xpc_object_t i1 = xpc_dictionary_create(NULL, NULL, 0); front_info(i1, s, a, old ? old->asn : 0, true); notify_app(a, kLSNotifyBecameFrontmost, i1); xpc_release(i1);
	if (old) { xpc_object_t i2 = xpc_dictionary_create(NULL, NULL, 0); front_info(i2, s, old, a->asn, true); notify_app(old, kLSNotifyLostFrontmost, i2); xpc_release(i2); }
	if (s->menubar == a->asn && oldmb != a) {
		xpc_object_t i3 = xpc_dictionary_create(NULL, NULL, 0); front_info(i3, s, a, oldmb ? oldmb->asn : 0, false); notify_app(a, kLSNotifyMenuBarAcquired, i3); xpc_release(i3);
		if (oldmb) { xpc_object_t i4 = xpc_dictionary_create(NULL, NULL, 0); front_info(i4, s, oldmb, a->asn, false); notify_app(oldmb, kLSNotifyMenuBarLost, i4); xpc_release(i4); }
	}
}

/* ---------------------------------------------------------------- application records */

static void lower_copy(char *o, size_t n, const char *s)
{
	size_t i;
	for (i = 0; s[i] && i + 1 < n; i++) o[i] = (s[i] >= 'A' && s[i] <= 'Z') ? s[i] + 32 : s[i];
	o[i] = 0;
}

static void set_lower(xpc_object_t d, const char *from, const char *to)
{
	const char *v = xpc_dictionary_get_string(d, from);
	char buf[1024];
	if (!v) return;
	lower_copy(buf, sizeof buf, v);
	xpc_dictionary_set_string(d, to, buf);
}

static void changed(struct app *a)
{
	a->changes += 2;
	xpc_dictionary_set_int64(a->info, "ChangeCount", a->changes);
	app_flags(a);
	seed(a->s, SEED_INFO, 4);
}

static void app_remove(struct app *a, int64_t exitStatus);

static void app_watch_death(struct app *a)
{
	struct app *aa = a;
	if (a->pid > 0) {
		a->procSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)a->pid, DISPATCH_PROC_EXIT, gQ);
		if (a->procSource) {
			dispatch_source_set_event_handler(a->procSource, ^{ LOG("pid %d exited", aa->pid); app_remove(aa, 0); });
			dispatch_resume(a->procSource);
		}
	}
	if (MACH_PORT_VALID(a->deathPort)) {	/* the client keeps the receive right of "deathport": the send right becomes dead when the process goes */
		a->deathSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_SEND, a->deathPort, DISPATCH_MACH_SEND_DEAD, gQ);
		if (a->deathSource) {
			dispatch_source_set_event_handler(a->deathSource, ^{ LOG("deathport of pid %d dead", aa->pid); app_remove(aa, 0); });
			dispatch_resume(a->deathSource);
		}
	}
}

static void dead_remember(struct session *s, struct app *a, xpc_object_t info)
{
	int i = s->ndead < 32 ? s->ndead++ : 0;
	if (s->ndead == 32 && i == 0) { xpc_release(s->dead[0].info); memmove(s->dead, s->dead + 1, 31 * sizeof s->dead[0]); i = 31; }
	s->dead[i].pid = a->pid;
	s->dead[i].info = xpc_retain(info);
}

static void app_remove(struct app *a, int64_t exitStatus)
{
	struct session *s = a->s;
	xpc_object_t info, sub;

	if (a->gone) return;
	a->gone = true;
	a->flags |= F_QUITTING;
	if (a->procSource) { dispatch_source_cancel(a->procSource); dispatch_release(a->procSource); a->procSource = NULL; }
	if (a->deathSource) { dispatch_source_cancel(a->deathSource); dispatch_release(a->deathSource); a->deathSource = NULL; }
	if (MACH_PORT_VALID(a->deathPort)) { mach_port_deallocate(mach_task_self(), a->deathPort); a->deathPort = MACH_PORT_NULL; }
	visible_sync(a);
	if (s->front == a->asn) { s->front = 0; seed(s, SEED_FRONT, 1); }
	if (s->menubar == a->asn) { s->menubar = 0; seed(s, SEED_MENUBAR, 1); }
	if (s->systemProcess == a->asn) s->systemProcess = 0;
	seed(s, SEED_LIST, 2); seed(s, SEED_VISIBLE, 2); seed(s, SEED_INFO, 3);
	page_rewrite(s);
	/* kLSNotifyApplicationDeath: the whole record and the exit; then kLSNotifyApplicationExitedIncludingSubordinateProcesses: pid, LSASN, bundle id */
	info = xpc_copy(a->info);
	xpc_dictionary_set_int64(info, "LSExitStatus", exitStatus);
	xpc_dictionary_set_bool(info, "LSApplicationExitedButHasRemainingCoalitionPIDsOrNonForegroundChildrenApplicationsKey", false);
	xpc_dictionary_set_int64(info, "LSApplicationCoalitionIDKey", xpc_dictionary_get_int64(a->info, "LSApplicationMemberCoalitionIDKey"));
	notify_app(a, kLSNotifyApplicationDeath, info);
	sub = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_int64(sub, "LSApplicationCoalitionIDKey", xpc_dictionary_get_int64(a->info, "LSApplicationMemberCoalitionIDKey"));
	if (xpc_dictionary_get_string(a->info, "CFBundleIdentifier")) xpc_dictionary_set_string(sub, "CFBundleIdentifier", xpc_dictionary_get_string(a->info, "CFBundleIdentifier"));
	xpc_dictionary_set_int64(sub, "pid", a->pid);
	xpc_dictionary_set_value(sub, "LSASN", asn_dict(a->asn));
	notify_app(a, kLSNotifyApplicationExitedIncludingSubordinateProcesses, sub);
	xpc_release(sub);
	dead_remember(s, a, info);
	xpc_release(info);
	/* unlink; the struct itself is kept (a pending dispatch block may still name it) */
	for (struct app **p = &s->apps; *p; p = &(*p)->next) if (*p == a) { *p = a->next; break; }
	LOG("application 0x%x pid %d removed", a->asn, a->pid);
}

/* 500: check-in.  The record is the client's info plus what the daemon adds (shape of the Mac's 500 reply, LAUNCHSERVICES-WIRE.md 6.1) */
static struct app *check_in(struct session *s, xpc_connection_t peer, xpc_object_t m, pid_t pid)
{
	xpc_object_t in = xpc_dictionary_get_value(m, "info");
	struct app *a = app_by_pid(s, pid);
	bool fresh = a == NULL;
	audit_token_t tok;
	char buf[1024];
	const char *v;

	if (in == NULL || xpc_get_type(in) != XPC_TYPE_DICTIONARY) return NULL;
	if (fresh) {
		a = calloc(1, sizeof *a);
		a->s = s;
		a->asn = (gNextASN++) * 0x1001;
		a->pid = pid;
		a->changes = FIRST_CHANGE_COUNT;
		a->info = xpc_dictionary_create(NULL, NULL, 0);
		a->flags = F_REGISTERED;
		struct app **p = &s->apps; while (*p) p = &(*p)->next; *p = a;	/* check-in order */
	}
	xpc_dictionary_apply(in, ^bool(const char *k, xpc_object_t val) { xpc_dictionary_set_value(a->info, k, val); return true; });
	memset(&tok, 0, sizeof tok);
	xpc_connection_get_audit_token(peer, &tok);
	a->pidversion = TOKEN_PIDVERSION(tok);
	xpc_dictionary_set_data(a->info, "LSAuditToken", &tok, sizeof tok);
	if (!xpc_dictionary_get_string(a->info, "LSExecutableFileName") && (v = xpc_dictionary_get_string(a->info, "CFBundleExecutablePath")) != NULL)
		xpc_dictionary_set_string(a->info, "LSExecutableFileName", strrchr(v, '/') ? strrchr(v, '/') + 1 : v);
	if (!xpc_dictionary_get_string(a->info, "LSDisplayName")) {
		if ((v = xpc_dictionary_get_string(a->info, "CFBundleName")) || (v = xpc_dictionary_get_string(a->info, "LSExecutableFileName"))) xpc_dictionary_set_string(a->info, "LSDisplayName", v);
	}
	set_lower(a->info, "LSExecutableFileName", "LSExecutableFilenameLowerCaseKey");
	set_lower(a->info, "CFBundleIdentifier", "BundleIdentifierLowerCase");
	set_lower(a->info, "CFBundleName", "CFBundleNameLowerCase");
	if (!xpc_dictionary_get_string(a->info, "ApplicationType")) xpc_dictionary_set_string(a->info, "ApplicationType", "Foreground");
	if (is_foreground(a) && !xpc_dictionary_get_value(a->info, "Hidden")) xpc_dictionary_set_bool(a->info, "Hidden", false);
	if (!xpc_dictionary_get_value(a->info, "LSApplicationMemberCoalitionIDKey")) xpc_dictionary_set_int64(a->info, "LSApplicationMemberCoalitionIDKey", pid);	/* no coalitions here: the pid */
	xpc_dictionary_set_int64(a->info, "pid", pid);
	xpc_dictionary_set_value(a->info, "LSASN", asn_dict(a->asn));
	if (!xpc_dictionary_get_value(a->info, "LSCheckInTime*")) xpc_dictionary_set_value(a->info, "LSCheckInTime*", xpc_date_create_from_current());
	xpc_dictionary_set_bool(a->info, "LSApplicationHasRegistered", true);
	if ((v = xpc_dictionary_get_string(a->info, "CFBundleExecutablePath")) != NULL && !xpc_dictionary_get_value(a->info, "CFBundleExecutablePathINode")) {
		int32_t dev; uint64_t ino;
		stat_path(v, &dev, &ino);
		if (ino) { xpc_dictionary_set_int64(a->info, "CFBundleExecutablePathDeviceID", dev); xpc_dictionary_set_int64(a->info, "CFBundleExecutablePathINode", (int64_t)ino); }
	}
	if ((v = xpc_dictionary_get_string(a->info, "LSBundlePath")) != NULL && !xpc_dictionary_get_value(a->info, "LSBundlePathINode")) {
		int32_t dev; uint64_t ino;
		stat_path(v, &dev, &ino);
		if (ino) { xpc_dictionary_set_int64(a->info, "LSBundlePathDeviceID", dev); xpc_dictionary_set_int64(a->info, "LSBundlePathINode", (int64_t)ino); }
		snprintf(buf, sizeof buf, "%s", strrchr(v, '/') ? strrchr(v, '/') + 1 : v);
		lower_copy(buf, sizeof buf, buf);
		xpc_dictionary_set_string(a->info, "LSBundlePathLastComponentLowerCaseKey", buf);
	}
	if (fresh) {
		mach_port_t dp = xpc_dictionary_get_value(m, "deathport") ? xpc_dictionary_copy_mach_send(m, "deathport") : MACH_PORT_NULL;
		a->deathPort = dp;
	} else
		a->changes += 2;
	xpc_dictionary_set_int64(a->info, "ChangeCount", a->changes);
	app_flags(a);
	if (fresh) {
		if ((v = xpc_dictionary_get_string(a->info, "CFBundleIdentifier")) && !strcmp(v, "com.apple.loginwindow")) s->systemProcess = a->asn;
		seed(s, SEED_LIST, 1); seed(s, SEED_VISIBLE, 1); seed(s, SEED_INFO, 4);
		page_rewrite(s);
		app_watch_death(a);
		/* kLSNotifyApplicationCreation (the client's info, LSASN, pid; no "affected"), then kLSNotifyApplicationBirth (the record) */
		xpc_object_t ci = xpc_copy(in);
		xpc_dictionary_set_value(ci, "LSASN", asn_dict(a->asn));
		xpc_dictionary_set_int64(ci, "pid", pid);
		notify(s, kLSNotifyApplicationCreation, ci, 0, false);
		xpc_release(ci);
		xpc_object_t bi = xpc_copy(a->info);	/* the record as it was before LSApplicationHasRegistered (the Mac's Birth info lacks only that key) */
		xpc_dictionary_set_value(bi, "LSApplicationHasRegistered", NULL);
		notify_app(a, kLSNotifyApplicationBirth, bi);
		xpc_release(bi);
		/* then the stopped state (not launched stopped): kLSNotifyApplicationStartedFromStoppedState + key added "LSStoppedState" false; the key is not in the record the clients read */
		xpc_object_t st = xpc_dictionary_create(NULL, NULL, 0);
		xpc_dictionary_set_string(st, "LSKeyBeingAdded", "LSStoppedState");
		xpc_dictionary_set_bool(st, "LSStoppedState", false);
		xpc_dictionary_set_value(st, "LSASN", asn_dict(a->asn));
		xpc_dictionary_set_int64(st, "ChangeCount", a->changes);
		notify_app(a, kLSNotifyApplicationStartedFromStoppedState, st);
		notify_app(a, kLSNotifyApplicationInformationKeyAdded, st);
		xpc_release(st);
		if (s->systemProcess == a->asn) notify_app(a, kLSNotifySystemProcessRegistered, NULL);
		LOG("check-in pid %d asn 0x%x %s", pid, a->asn, xpc_dictionary_get_string(a->info, "LSDisplayName") ?: "");
	} else {
		seed(s, SEED_INFO, 4);
		page_update_app(a);
	}
	return a;
}

/* 510: set keys of a record.  The special keys (Apple: LSApplication::SetProcessInformationItem): LSNotifyApplicationFrontable turns into
 * LSApplicationReadyToBeFrontableKey (kLSNotifyApplicationRegisteredForCGEvents), Hidden only for foreground applications, ApplicationType moves the
 * application in or out of the visible list; every other key is stored with a key added / changed / removed notification */
static void set_info(struct app *a, xpc_object_t in)
{
	__block bool order = false;
	xpc_dictionary_apply(in, ^bool(const char *k, xpc_object_t v) {
		xpc_object_t old = xpc_dictionary_get_value(a->info, k);
		if (!strcmp(k, "LSNotifyApplicationFrontable")) {
			if (xpc_get_type(v) == XPC_TYPE_BOOL && xpc_dictionary_get_bool(in, k) && !(a->flags & F_FRONTABLE)) {
				a->flags |= F_FRONTABLE;
				xpc_dictionary_set_bool(a->info, "LSApplicationReadyToBeFrontableKey", true);
				changed(a);
				order |= visible_sync(a);
				xpc_object_t i = xpc_dictionary_create(NULL, NULL, 0);
				xpc_dictionary_set_bool(i, "LSApplicationReadyToBeFrontableKey", true);
				xpc_dictionary_set_value(i, "LSASN", asn_dict(a->asn));
				xpc_dictionary_set_int64(i, "ChangeCount", a->changes);
				notify_app(a, kLSNotifyApplicationRegisteredForCGEvents, i);
				xpc_release(i);
			}
			return true;
		}
		if (!strcmp(k, "Hidden")) {
			bool h = xpc_get_type(v) == XPC_TYPE_BOOL && xpc_dictionary_get_bool(in, k);
			if (!is_foreground(a)) { changed(a); return true; }	/* "only foreground applications can have the kLSApplicationIsHidden key" */
			if (old && xpc_equal(old, v)) return true;
			xpc_dictionary_set_bool(a->info, "Hidden", h);
			changed(a);
			notify_app(a, h ? kLSNotifyApplicationHidden : kLSNotifyApplicationShown, a->info);
			return true;
		}
		if (old && xpc_equal(old, v)) return true;
		xpc_object_t prev = old ? xpc_retain(old) : NULL;
		if (xpc_get_type(v) == xpc_get_type(xpc_null_create())) xpc_dictionary_set_value(a->info, k, NULL);
		else xpc_dictionary_set_value(a->info, k, v);
		changed(a);
		if (!strcmp(k, "ApplicationType")) {	/* TransformProcessType: the application can come forward from now on (CanBecomeFrontmost, as the Mac's daemon sets it) */
			order |= visible_sync(a);
			if (is_foreground(a) && !xpc_dictionary_get_value(a->info, "Hidden")) xpc_dictionary_set_bool(a->info, "Hidden", false);
			xpc_dictionary_set_bool(a->info, "CanBecomeFrontmost", true);
		}
		notify_key(a, k, xpc_dictionary_get_value(a->info, k), prev, !strcmp(k, "ApplicationType") ? kLSNotifyApplicationTypeChanged : !strcmp(k, "LSDisplayName") ? kLSNotifyApplicationNameChanged : 0);
		if (prev) xpc_release(prev);
		return true;
	});
	if (order) { seed(a->s, SEED_VISIBLE, 1); page_rewrite(a->s); } else page_update_app(a);
}

/* ---------------------------------------------------------------- the meta information (200/210) */

static const char *const kMetaKeys[] = { "LSSessionID", "LSCGSSessionID", "LSActiveCGSSessionIDKey", "LSFrontApplicationSeed", "LSApplicationListSeed",
	"LSVisibleApplicationListSeed", "LSApplicationCount", "LSVisibleApplicationCount", "LSHiddenApplicationCount", "LSUnhiddenApplicationCount",
	"LSPIDsInSession", "LSUIDsInSession", "LSSessionAttributes", "LSSystemProcessASN", "LSMouseButtonDown", "UIPresentationOptions",
	"LSLaunchInProgress", "LSUserActivityCount", "LSDisableAllPostLaunchBringForwardRequests", "LSMetaExpectedFrontAppsASNs",
	"LSMetaRecentApplicationsArray", NULL };

static xpc_object_t meta_value(struct session *s, const char *k, uid_t uid)
{
	size_t napps = 0, hidden = 0;
	for (struct app *a = s->apps; a; a = a->next) { napps++; if (a->flags & F_HIDDEN) hidden++; }
	xpc_object_t set = xpc_dictionary_get_value(s->meta, k);
	if (set) return xpc_retain(set);
	if (!strcmp(k, "LSSessionID")) return xpc_int64_create(s->id);
	if (!strcmp(k, "LSCGSSessionID") || !strcmp(k, "LSActiveCGSSessionIDKey")) return xpc_int64_create(*page_word(s, 0x68));
	if (!strcmp(k, "LSFrontApplicationSeed")) return xpc_int64_create(*page_word(s, SEED_FRONT));
	if (!strcmp(k, "LSApplicationListSeed")) return xpc_int64_create(*page_word(s, SEED_LIST));
	if (!strcmp(k, "LSVisibleApplicationListSeed")) return xpc_int64_create(*page_word(s, SEED_VISIBLE));
	if (!strcmp(k, "LSApplicationCount")) return xpc_int64_create((int64_t)napps);
	if (!strcmp(k, "LSVisibleApplicationCount")) return xpc_int64_create((int64_t)s->nvisible);
	if (!strcmp(k, "LSHiddenApplicationCount")) return xpc_int64_create((int64_t)hidden);
	if (!strcmp(k, "LSUnhiddenApplicationCount")) return xpc_int64_create((int64_t)(s->nvisible - (hidden < s->nvisible ? hidden : s->nvisible)));
	if (!strcmp(k, "LSPIDsInSession")) { xpc_object_t a = xpc_array_create(NULL, 0); for (struct app *p = s->apps; p; p = p->next) xpc_array_append_value(a, xpc_int64_create(p->pid)); return a; }
	if (!strcmp(k, "LSUIDsInSession")) { xpc_object_t a = xpc_array_create(NULL, 0); xpc_array_append_value(a, xpc_int64_create(uid)); xpc_array_append_value(a, xpc_int64_create(-2)); return a; }
	if (!strcmp(k, "LSSessionAttributes")) return xpc_int64_create(48);
	if (!strcmp(k, "LSSystemProcessASN")) return s->systemProcess ? asn_dict(s->systemProcess) : NULL;
	if (!strcmp(k, "UIPresentationOptions") || !strcmp(k, "LSUserActivityCount")) return xpc_int64_create(0);
	if (!strcmp(k, "LSMouseButtonDown") || !strcmp(k, "LSLaunchInProgress") || !strcmp(k, "LSDisableAllPostLaunchBringForwardRequests")) return xpc_bool_create(false);
	if (!strcmp(k, "LSMetaExpectedFrontAppsASNs") || !strcmp(k, "LSMetaRecentApplicationsArray")) {
		xpc_object_t a = xpc_array_create(NULL, 0);
		if (!strcmp(k, "LSMetaExpectedFrontAppsASNs")) for (size_t i = 0; i < s->nvisible; i++) xpc_array_append_value(a, asn_dict(s->visible[i]));
		return a;
	}
	return NULL;
}

static bool meta_known(const char *k) { for (int i = 0; kMetaKeys[i]; i++) if (!strcmp(kMetaKeys[i], k)) return true; return false; }

/* ---------------------------------------------------------------- listeners (400/410/420) */

static void listener_unlink(struct listener *l)
{
	struct session *s = l->s;
	if (l->dead) return;
	l->dead = true;
	for (struct listener **p = &s->listeners; *p; p = &(*p)->next) if (*p == l) { *p = l->next; break; }
}

/* 420 or the listener went away: out of the list now; the struct is freed by the connection's final event */
static void listener_drop(struct listener *l)
{
	listener_unlink(l);
	xpc_connection_cancel(l->conn);
}

static struct listener *listener_by_id(uint64_t id)
{
	for (struct session *s = gSessions; s; s = s->next)
		for (struct listener *l = s->listeners; l; l = l->next) if (l->id == id) return l;
	return NULL;
}

static void asn_set_edit(struct listener *l, struct session *s, xpc_object_t arr, bool add, xpc_object_t affected, pid_t caller)
{
	if (!arr || xpc_get_type(arr) != XPC_TYPE_ARRAY) return;
	for (size_t i = 0; i < xpc_array_get_count(arr); i++) {
		uint64_t v = xpc_array_get_uint64(arr, i);
		struct app *a = app_resolve(s, v, caller);
		uint32_t lo = a ? a->asn : (uint32_t)(v >> 32) == 0 ? (uint32_t)v : 0;
		if (!lo) continue;
		size_t j;
		for (j = 0; j < l->nasns && l->asns[j] != lo; j++) ;
		if (add && j == l->nasns) { l->asns = realloc(l->asns, (l->nasns + 1) * sizeof *l->asns); l->asns[l->nasns++] = lo; }
		if (!add && j < l->nasns) l->asns[j] = l->asns[--l->nasns];
		if (affected) xpc_array_append_value(affected, xpc_uint64_create(lo));
	}
}

static bool cmd_listener(xpc_connection_t peer, xpc_object_t m, xpc_object_t r, struct session *s)
{
	uint64_t id = xpc_dictionary_get_uint64(m, "id");
	struct listener *l = id ? listener_by_id(id) : NULL;
	bool created = false;
	pid_t pid = xpc_connection_get_pid(peer);

	if (id && !l) return false;
	if (!l) {
		xpc_object_t ep = xpc_dictionary_get_value(m, "listener");
		if (!ep || xpc_get_type(ep) != XPC_TYPE_ENDPOINT) return false;
		l = calloc(1, sizeof *l);
		l->s = s;
		l->id = gNextListener++;
		l->clientid = xpc_dictionary_get_uint64(m, "clientid");
		l->pid = pid;
		l->msgid = 100;
		l->conn = xpc_connection_create_from_endpoint(ep);
		struct listener *ll = l;
		xpc_connection_set_target_queue(l->conn, gQ);
		xpc_connection_set_event_handler(l->conn, ^(xpc_object_t e) {
			if (e == XPC_ERROR_CONNECTION_INVALID) {
				LOG("listener %llu gone", (unsigned long long)ll->id);
				listener_unlink(ll);
				xpc_release(ll->conn);
				free(ll->codes); free(ll->asns); free(ll);
			}
		});
		xpc_connection_resume(l->conn);
		l->next = s->listeners; s->listeners = l;
		created = true;
	}
	xpc_object_t set = xpc_dictionary_get_value(m, "set");
	if (set && xpc_get_type(set) == XPC_TYPE_ARRAY) {	/* the codes this listener wants (replaces the earlier set) */
		free(l->codes);
		l->ncodes = xpc_array_get_count(set);
		l->codes = calloc(l->ncodes + 1, sizeof *l->codes);
		for (size_t i = 0; i < l->ncodes; i++) {
			xpc_object_t v = xpc_array_get_value(set, i);
			l->codes[i] = xpc_get_type(v) == XPC_TYPE_INT64 ? xpc_int64_get_value(v) : (int64_t)xpc_array_get_uint64(set, i);
		}
	}
	xpc_object_t aff = xpc_dictionary_get_value(m, "addasn") ? xpc_array_create(NULL, 0) : NULL;
	asn_set_edit(l, s, xpc_dictionary_get_value(m, "removeasn"), false, NULL, pid);
	asn_set_edit(l, s, xpc_dictionary_get_value(m, "addasn"), true, aff, pid);
	if (created) {	/* what the Mac's daemon sends on a new listener after the reply: a "nop", then kLSNotifyNotificationResetSequenceNumber (msgid 100) */
		struct listener *nl = l;
		dispatch_async(gQ, ^{
			if (nl->dead) return;
			xpc_object_t nop = xpc_dictionary_create(NULL, NULL, 0);
			xpc_dictionary_set_bool(nop, "nop", true);
			xpc_connection_send_message(nl->conn, nop);
			xpc_release(nop);
			listener_send(nl, kLSNotifyNotificationResetSequenceNumber, NULL, 0, false);
		});
	}
	xpc_dictionary_set_uint64(r, "id", l->id);
	xpc_dictionary_set_int64(r, "session", s->id);
	if (aff) { xpc_dictionary_set_value(r, "affectedasns", aff); xpc_release(aff); }
	return true;
}

/* ---------------------------------------------------------------- the commands */

static xpc_object_t asn_array(void) { return xpc_array_create(NULL, 0); }

static bool matches(struct app *a, xpc_object_t criteria)
{
	__block bool ok = true;
	xpc_dictionary_apply(criteria, ^bool(const char *k, xpc_object_t v) {
		xpc_object_t have = xpc_dictionary_get_value(a->info, k);
		if (!have || !xpc_equal(have, v)) { ok = false; return false; }
		return true;
	});
	return ok;
}

static void handle(xpc_connection_t peer, xpc_object_t m)
{
	xpc_object_t r = xpc_dictionary_create_reply(m);
	int64_t cmd = xpc_dictionary_get_int64(m, "command");
	pid_t caller = xpc_connection_get_pid(peer);
	struct session *s = session_for(peer, m);
	bool ok = false;
	struct app *a;

	if (gLog) { char *d = xpc_copy_description(m); fprintf(stderr, "launchservicesd: request from pid %d: %s\n", caller, d); free(d); }
	if (r == NULL) return;		/* a message without a reply port: nothing to answer */
	if (xpc_dictionary_get_value(m, "replysig")) { xpc_release(r); return; }	/* NSXPC: not a protocol of this service; an answer without the NSXPC fields crashes the client's libxpc, a dropped reply gives it an error */
	switch (cmd) {
	case 100:	/* LSClientToServerConnection::setupServerConnection */
		xpc_dictionary_set_uint64(r, "serverversion", SERVER_VERSION);
		xpc_dictionary_set_int64(r, "session", s->id);
		ok = true;
		break;
	case 110:	/* the info page */
		{ xpc_object_t sh = xpc_shmem_create(s->page, PAGE_SIZE_LS); if (sh) { xpc_dictionary_set_value(r, "lsinfopage", sh); xpc_release(sh); } }
		ok = true;
		break;
	case 120:	/* _LSAllocatePSN */
		xpc_dictionary_set_uint64(r, "asn", (gNextASN++) * 0x1001);
		ok = true;
		break;
	case 130: {	/* _LSCompareASNsLong: both must be known; result -1 / 0 / 1 */
		struct app *x = app_resolve(s, xpc_dictionary_get_uint64(m, "asn1"), caller), *y = app_resolve(s, xpc_dictionary_get_uint64(m, "asn2"), caller);
		if (x && y) { xpc_dictionary_set_int64(r, "result", x->asn == y->asn ? 0 : x->asn < y->asn ? -1 : 1); ok = true; }
		break;
	}
	case 140:	/* kLSXPCDisconnect: the Mac's daemon answers "sucess" (sic) and cancels the connection */
		xpc_dictionary_set_bool(r, "sucess", true);
		xpc_connection_send_message(peer, r);
		xpc_release(r);
		xpc_connection_cancel(peer);
		return;
	case 200: {	/* _LSCopyMetaApplicationInformation: only the "wanted" keys (none: all); unknown keys are left out */
		xpc_object_t meta = xpc_dictionary_create(NULL, NULL, 0), wanted = xpc_dictionary_get_value(m, "wanted");
		uid_t uid = xpc_connection_get_euid(peer);
		if (wanted && xpc_get_type(wanted) == XPC_TYPE_ARRAY) {
			for (size_t i = 0; i < xpc_array_get_count(wanted); i++) {
				const char *k = xpc_array_get_string(wanted, i);
				xpc_object_t v = k && meta_known(k) ? meta_value(s, k, uid) : NULL;
				if (v) { xpc_dictionary_set_value(meta, k, v); xpc_release(v); }
			}
		} else
			for (int i = 0; kMetaKeys[i]; i++) { xpc_object_t v = meta_value(s, kMetaKeys[i], uid); if (v) { xpc_dictionary_set_value(meta, kMetaKeys[i], v); xpc_release(v); } }
		xpc_dictionary_set_value(r, "metainfo", meta);
		xpc_release(meta);
		ok = true;
		break;
	}
	case 210: {	/* _LSSetMetaApplicationInformation: known keys are kept, others ignored */
		xpc_object_t in = xpc_dictionary_get_value(m, "info");
		if (in && xpc_get_type(in) == XPC_TYPE_DICTIONARY)
			xpc_dictionary_apply(in, ^bool(const char *k, xpc_object_t v) { if (meta_known(k) && strcmp(k, "LSSessionID")) xpc_dictionary_set_value(s->meta, k, v); return true; });
		ok = true;
		break;
	}
	case 300:	/* _LSCopyFrontApplication */
		if (s->front) { xpc_dictionary_set_uint64(r, "asn", s->front); ok = true; }
		break;
	case 310: {	/* the applications of the session, in check-in order */
		xpc_object_t arr = asn_array();
		for (a = s->apps; a; a = a->next) xpc_array_append_value(arr, xpc_uint64_create(a->asn));
		xpc_dictionary_set_uint64(r, "seed", *page_word(s, SEED_LIST));
		xpc_dictionary_set_value(r, "result", arr); xpc_release(arr);
		ok = true;
		break;
	}
	case 320: {	/* _LSCopyApplicationArrayInFrontToBackOrder: the visible applications; hidden ones only with "includehidden" */
		xpc_object_t arr = asn_array();
		bool hid = xpc_dictionary_get_bool(m, "includehidden");
		for (size_t i = 0; i < s->nvisible; i++) { a = app_by_asn(s, s->visible[i]); if (a && (hid || !(a->flags & F_HIDDEN))) xpc_array_append_value(arr, xpc_uint64_create(a->asn)); }
		xpc_dictionary_set_uint64(r, "seed", *page_word(s, SEED_VISIBLE));
		xpc_dictionary_set_value(r, "result", arr); xpc_release(arr);
		ok = true;
		break;
	}
	case 330: {	/* _LSCopyMatchingApplications: every key of "criteria" equal in the record */
		xpc_object_t crit = xpc_dictionary_get_value(m, "criteria"), arr = asn_array();
		for (a = s->apps; a; a = a->next) if (crit && xpc_get_type(crit) == XPC_TYPE_DICTIONARY && matches(a, crit)) xpc_array_append_value(arr, xpc_uint64_create(a->asn));
		xpc_dictionary_set_uint64(r, "seed", *page_word(s, SEED_LIST));
		xpc_dictionary_set_value(r, "result", arr); xpc_release(arr);
		ok = true;
		break;
	}
	case 331: {	/* _LSCopyApplicationsWithPath: the bundle or the executable at "path"; LSASN dictionaries */
		const char *p = xpc_dictionary_get_string(m, "path");
		xpc_object_t arr = asn_array();
		for (a = s->apps; a && p; a = a->next) {
			const char *b = xpc_dictionary_get_string(a->info, "LSBundlePath"), *e = xpc_dictionary_get_string(a->info, "CFBundleExecutablePath");
			if ((b && !strcmp(b, p)) || (e && !strcmp(e, p))) xpc_array_append_value(arr, asn_dict(a->asn));
		}
		xpc_dictionary_set_value(r, "asns", arr); xpc_release(arr);
		ok = true;
		break;
	}
	case 360: {	/* _LSCopyApplicationInformation: the keys of "restrictto" (cacheable false) or the whole record (cacheable true) */
		xpc_object_t keys = xpc_dictionary_get_value(m, "restrictto");
		if ((a = app_resolve(s, xpc_dictionary_get_uint64(m, "asn"), caller)) == NULL) break;
		if (keys && xpc_get_type(keys) == XPC_TYPE_ARRAY) {
			xpc_object_t res = xpc_dictionary_create(NULL, NULL, 0);
			for (size_t i = 0; i < xpc_array_get_count(keys); i++) {
				const char *k = xpc_array_get_string(keys, i);
				xpc_object_t v = k ? xpc_dictionary_get_value(a->info, k) : NULL;
				if (v) xpc_dictionary_set_value(res, k, v);
			}
			xpc_dictionary_set_value(r, "result", res); xpc_release(res);
			xpc_dictionary_set_bool(r, "cacheable", false);
		} else {
			xpc_object_t res = xpc_copy(a->info);
			xpc_dictionary_set_value(r, "result", res); xpc_release(res);
			xpc_dictionary_set_bool(r, "cacheable", true);
		}
		ok = true;
		break;
	}
	case 370:	/* _LSCopyLaunchModifiers: "modifiers" only when there are some; after that no new ones are accepted */
		if ((a = app_resolve(s, xpc_dictionary_get_uint64(m, "asn"), caller)) == NULL) break;
		if (a->modifiers) { xpc_dictionary_set_value(r, "modifiers", a->modifiers); if (xpc_dictionary_get_bool(m, "consume")) { xpc_release(a->modifiers); a->modifiers = NULL; } }
		a->modifiersReturned = true;
		ok = true;
		break;
	case 380: {	/* _LSPostLaunchModifiers */
		xpc_object_t mod = xpc_dictionary_get_value(m, "modifiers");
		if ((a = app_resolve(s, xpc_dictionary_get_uint64(m, "asn"), caller)) == NULL) break;
		if (a->modifiersReturned) { xpc_dictionary_set_int64(r, "error", -13053); break; }	/* "Launch data has already been returned to the app" */
		if (mod && xpc_get_type(mod) == XPC_TYPE_DICTIONARY) {
			if (!a->modifiers) a->modifiers = xpc_dictionary_create(NULL, NULL, 0);
			xpc_dictionary_apply(mod, ^bool(const char *k, xpc_object_t v) { xpc_dictionary_set_value(a->modifiers, k, v); return true; });
		}
		ok = true;
		break;
	}
	case 400:
	case 410:	/* LSNotificationReceiver::modify: register / change a listener */
		ok = cmd_listener(peer, m, r, s);
		break;
	case 420: {	/* _LSUnscheduleNotificationFunction */
		struct listener *l = listener_by_id(xpc_dictionary_get_uint64(m, "id"));
		if (l) { listener_drop(l); ok = true; }
		break;
	}
	case 450: {	/* _LSSendNotification {code, asn, data, when, requestedsession}: refused for plain clients on the Mac; root / _windowserver broadcast it */
		if (!is_privileged(peer)) break;
		a = app_resolve(s, xpc_dictionary_get_uint64(m, "asn"), caller);
		xpc_object_t data = xpc_dictionary_get_value(m, "data");
		notify(s, xpc_dictionary_get_int64(m, "code"), data, a ? a->asn : 0, a != NULL);
		ok = true;
		break;
	}
	case 500:	/* _LSApplicationCheckIn */
	case 501:	/* _LSApplicationCheckInProxy: needs com.apple.private.launchservices.allowedtolaunchasproxy; here root */
		if (cmd == 501 && xpc_connection_get_euid(peer) != 0) { xpc_dictionary_set_int64(r, "error", -54); break; }
		if ((a = check_in(s, peer, m, cmd == 501 && xpc_dictionary_get_int64(m, "pid") > 0 ? (pid_t)xpc_dictionary_get_int64(m, "pid") : caller)) == NULL) break;
		xpc_dictionary_set_value(r, "result", a->info);
		ok = true;
		break;
	case 505:	/* "is the caller checked in?": its record (the Mac answers for the caller whatever "pid" says) */
		if ((a = app_by_pid(s, caller)) == NULL) break;
		xpc_dictionary_set_value(r, "result", a->info);
		ok = true;
		break;
	case 510: {	/* _LSSetApplicationInformation: the application itself, or root / _windowserver; the reply is the whole record */
		xpc_object_t in = xpc_dictionary_get_value(m, "info");
		if ((a = app_resolve(s, xpc_dictionary_get_uint64(m, "asn"), caller)) == NULL) break;
		if (a->pid != caller && !is_privileged(peer)) { xpc_dictionary_set_int64(r, "error", -54); break; }
		if (in && xpc_get_type(in) == XPC_TYPE_DICTIONARY) set_info(a, in);
		xpc_dictionary_set_value(r, "info", a->info);
		ok = true;
		break;
	}
	case 520:	/* _LSSignalApplicationReady */
		if ((a = app_resolve(s, xpc_dictionary_get_uint64(m, "asn"), caller)) == NULL) break;
		if (!(a->flags & F_READY)) {
			a->flags |= F_READY;
			if (!xpc_dictionary_get_value(a->info, "LSLaunchedHidden")) xpc_dictionary_set_bool(a->info, "LSLaunchedHidden", false);
			xpc_dictionary_set_bool(a->info, "LSApplicationHasSignalledItIsReady", true);
			changed(a);
			page_update_app(a);
			notify_app(a, kLSNotifyApplicationReady, a->info);
			/* nobody in front and a foreground application is ready: it is asked to come forward (the Mac: "Picked new front app ...") */
			if (!s->front && is_foreground(a)) notify_app(a, kLSNotifyBringForwardRequest, NULL);
		}
		ok = true;
		break;
	case 590:	/* _LSApplicationQuitting {asn, exitstatus}: the record goes at once */
		if ((a = app_resolve(s, xpc_dictionary_get_uint64(m, "asn"), caller)) == NULL) break;
		app_remove(a, xpc_dictionary_get_int64(m, "exitstatus"));
		ok = true;
		break;
	case 597:	/* _LSReCheckinApplication: the Mac's daemon asks for the full information (the client then sends 500) */
		xpc_dictionary_set_bool(r, "resendfullinfo", true);
		break;
	case 600: {	/* _CASNotifyServerSideAboutLaunchedApplication {pid, asn, info, modifiers}: without a pid the Mac answers error -600 and success */
		pid_t pid = (pid_t)xpc_dictionary_get_int64(m, "pid");
		xpc_object_t mod = xpc_dictionary_get_value(m, "modifiers");
		if (pid <= 0 || (a = app_by_pid(s, pid)) == NULL) { xpc_dictionary_set_int64(r, "error", -600); ok = true; break; }
		if (mod && xpc_get_type(mod) == XPC_TYPE_DICTIONARY && !a->modifiersReturned) {
			if (!a->modifiers) a->modifiers = xpc_dictionary_create(NULL, NULL, 0);
			xpc_dictionary_apply(mod, ^bool(const char *k, xpc_object_t v) { xpc_dictionary_set_value(a->modifiers, k, v); return true; });
		}
		ok = true;
		break;
	}
	case 610:	/* _LSWaitForApplicationCheckIn: only for a launch in progress; none here (the Mac: -13052 for an application already checked in) */
		xpc_dictionary_set_int64(r, "error", -13052);
		break;
	case 700: {	/* _LSCopyApplicationDeathInformationForPid {pid, consume}: "result" when the daemon saw that pid die; success for any pid above 1 (the Mac) */
		pid_t pid = (pid_t)xpc_dictionary_get_int64(m, "pid");
		if (pid <= 1) break;
		for (int i = s->ndead - 1; i >= 0; i--) if (s->dead[i].pid == pid) {
			xpc_dictionary_set_value(r, "result", s->dead[i].info);
			if (xpc_dictionary_get_bool(m, "consume")) { xpc_release(s->dead[i].info); memmove(s->dead + i, s->dead + i + 1, (s->ndead - i - 1) * sizeof s->dead[0]); s->ndead--; }
			break;
		}
		ok = true;
		break;
	}
	case 900:	/* _LSPassDownCurrentEventState {datatype, value1..4}: root / _windowserver */
		ok = is_privileged(peer);
		break;
	case 910:	/* _LSSetFrontApplication: root / _windowserver only (the Mac answers errno -54 to others) */
		if (!is_privileged(peer)) { xpc_dictionary_set_int64(r, "errno", -54); break; }
		if ((a = app_resolve(s, xpc_dictionary_get_uint64(m, "asn"), caller)) == NULL) { xpc_dictionary_set_int64(r, "errno", -600); break; }
		set_front(s, a);
		ok = true;
		break;
	case 920: {	/* _LSOrderApplications {order, after}: root / _windowserver */
		xpc_object_t order = xpc_dictionary_get_value(m, "order");
		if (!is_privileged(peer)) { xpc_dictionary_set_int64(r, "errno", -54); break; }
		if (!order || xpc_get_type(order) != XPC_TYPE_ARRAY) { ok = true; break; }	/* nothing to move (the Mac: success) */
		uint32_t list[PAGE_CAPACITY]; size_t n = 0;
		struct app *after = app_resolve(s, xpc_dictionary_get_uint64(m, "after"), caller);
		size_t at = 0;
		for (size_t i = 0; i < s->nvisible; i++) {
			bool moved = false;
			for (size_t j = 0; j < xpc_array_get_count(order); j++) { struct app *o = app_resolve(s, xpc_array_get_uint64(order, j), caller); if (o && o->asn == s->visible[i]) moved = true; }
			if (!moved) list[n++] = s->visible[i];
			if (after && s->visible[i] == after->asn) at = n;
		}
		for (size_t j = 0; j < xpc_array_get_count(order) && n < PAGE_CAPACITY; j++) {
			struct app *o = app_resolve(s, xpc_array_get_uint64(order, j), caller);
			if (!o || !visible_pos(s, o->asn)) continue;
			memmove(list + at + 1, list + at, (n - at) * sizeof list[0]); list[at++] = o->asn; n++;
		}
		memcpy(s->visible, list, n * sizeof list[0]); s->nvisible = n;
		seed(s, SEED_VISIBLE, 1);
		page_rewrite(s);	/* no kLSNotifyOrderChanged: the Mac's daemon sent none for a 920 */
		ok = true;
		break;
	}
	case 98:	/* the client's answer to a session-information message */
	case 99:	/* _LSSetMetaApplicationInformationItem */
	case 1000:	/* _LSGetCurrentActivationToken: no token (the Mac answers success without one when there is none) */
		ok = true;
		break;
	default:	/* every other command (595, 596, 598, 599, 1010-1030, unknown): the Mac's answer, success false */
		break;
	}
	xpc_dictionary_set_bool(r, "success", ok);
	if (gLog) { char *d = xpc_copy_description(r); fprintf(stderr, "launchservicesd: reply %lld: %s\n", (long long)cmd, d); free(d); }
	xpc_connection_send_message(peer, r);
	xpc_release(r);
}

int main(int argc, char **argv)
{
	const char *name = getenv("LSVD_SERVICE_NAME") ? getenv("LSVD_SERVICE_NAME") : "com.apple.coreservices.launchservicesd";
	(void)argc; (void)argv;
	gLog = getenv("LSVD_LOG") != NULL;
	signal(SIGPIPE, SIG_IGN);
	gQ = dispatch_queue_create("com.apple.coreservices.launchservicesd", NULL);
	xpc_connection_t svc = xpc_connection_create_mach_service(name, gQ, XPC_CONNECTION_MACH_SERVICE_LISTENER);
	xpc_connection_set_event_handler(svc, ^(xpc_object_t peer) {
		if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
		xpc_retain(peer);
		xpc_connection_set_event_handler(peer, ^(xpc_object_t m) {
			if (xpc_get_type(m) == XPC_TYPE_DICTIONARY) handle(peer, m);
			else if (m == XPC_ERROR_CONNECTION_INVALID) xpc_release(peer);
		});
		xpc_connection_resume(peer);
	});
	xpc_connection_resume(svc);
	LOG("serving %s", name);
	dispatch_main();
	return 0;
}
