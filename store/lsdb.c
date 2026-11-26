/* The schema and the records layer of the Launch Services database (macOS 26.7.2): research/docs/LAUNCHSERVICES-WIRE.md 5.2-5.9. */
#include "lsdb.h"
#include <string.h>
#include <stdlib.h>

static const struct { uint32_t id; const char *name; } plain[] = {
	{ 8, "Bundle" }, { 12, "Claim" }, { 16, "Service" }, { 20, "Type" }, { 24, "HandlerPref" }, { 28, "Container" }, { 32, "Alias" }, { 36, "Plugin" },
	{ 40, "ExtensionPoint" }, { 44, "BindingList" }, { 48, "PropertyList" }, { 52, "LocalizedString" }, { 56, "CanonicalString" } };
/* the string binding tables: one hash unit (id `unit`) of `slots` keys followed by `slots` values; empty slot 0xeeeeeee1, deleted 0xddddddd2 */
static const struct { uint32_t id; const char *name; uint32_t unit, slots; } bindt[] = {
	{ 60, "BindableKeyMap", 0x14, 8161 }, { 64, "UTIBinding", 0x14, 8161 }, { 68, "ExtensionBinding", 0xc, 2041 }, { 72, "OSTypeBinding", 8, 1021 },
	{ 76, "MIMEBinding", 8, 1021 }, { 80, "NSPasteboardBinding", 4, 511 }, { 84, "DeviceModelCodeBinding", 0x10, 4081 }, { 88, "BluetoothVendorProductIDBinding", 4, 511 },
	{ 92, "URLSchemeBinding", 4, 511 }, { 96, "BundleIDBinding", 8, 1021 }, { 100, "BundleNameBinding", 0xc, 2041 }, { 104, "ActivityTypeBinding", 0xc, 2041 },
	{ 108, "PluginBundleIDBinding", 0xc, 2041 }, { 112, "PluginProtocolBinding", 4, 511 }, { 116, "PluginUUIDBinding", 0xc, 2041 }, { 120, "ExtensionPointIDBinding", 4, 511 } };
/* _LSSchemaConfigureBindingMap: a client refuses a store where these binding class names are not strings (kLSBindingInfo order; ids 4, 8 ... 0x20 in a real store) */
static const char *class_names[] = { "com.apple.uniform-type-identifier", "public.filename-extension", "com.apple.ostype", "public.mime-type", "com.apple.nspboard-type",
	"com.apple.device-model-code", "public.bluetooth-vendor-product-id", "public.url-scheme" };
/* kPackedAlphabet of CoreServicesStore: index 0 is NUL */
static const char packed[] = "\0 abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
static const uint32_t primes[] = { 511, 1021, 2041, 4081, 8161, 16321, 32641, 65281, 130561 };
#define EMPTY 0xeeeeeee1u
#define DELETED 0xddddddd2u

struct sent { char *s; uint32_t id; };
struct bent { uint32_t table, key; uint32_t *units; size_t n, cap; };
struct ls_db {
	cs_store *s;
	struct sent *str; size_t nstr, capstr;          /* open addressing, capstr a power of two */
	struct bent *b; size_t nb, capb;
	uint64_t seq;
};

static void p32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static void p64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }
static uint32_t fnv(const char *s) { uint32_t h = 2166136261u; while (*s) h = (h ^ (uint8_t)*s++) * 16777619u; return h; }

uint32_t ls_string_hash(const uint8_t *b, size_t n)
{
	uint32_t h = (uint32_t)n;
	if (n <= 0x80) for (size_t i = 0; i < n; i++) h = b[i] + h * 0x11;
	else { for (size_t i = 0; i < 64; i++) h = b[i] + h * 0x11; for (size_t i = n - 64; i < n; i++) h = b[i] + h * 0x11; }
	return (((h << (n & 7)) + h)) & 0xffff;
}

static uint32_t packed_id(const char *s)
{
	size_t n = strlen(s);
	uint32_t v = 0;
	if (n == 0 || n > 5) return 0;
	for (size_t i = 0; i < n; i++) {
		const char *c = s[i] ? memchr(packed + 1, s[i], sizeof packed - 2) : NULL;
		if (!c) return 0;
		v = (v << 6) | (uint32_t)(c - packed);
	}
	return v * 4 + 1;
}

static int str_grow(ls_db *db)
{
	size_t nc = db->capstr ? db->capstr * 2 : 4096;
	struct sent *n = calloc(nc, sizeof *n);
	if (!n) return -1;
	for (size_t i = 0; i < db->capstr; i++) if (db->str[i].s) {
		size_t k = fnv(db->str[i].s) & (nc - 1);
		while (n[k].s) k = (k + 1) & (nc - 1);
		n[k] = db->str[i];
	}
	free(db->str); db->str = n; db->capstr = nc;
	return 0;
}

uint32_t ls_string(ls_db *db, const char *s)
{
	if (!s || !*s) return 0;
	uint32_t p = packed_id(s);
	if (p) return p;
	if ((db->nstr + 1) * 2 > db->capstr && str_grow(db) < 0) return 0;
	size_t k = fnv(s) & (db->capstr - 1);
	while (db->str[k].s) { if (!strcmp(db->str[k].s, s)) return db->str[k].id; k = (k + 1) & (db->capstr - 1); }
	uint32_t id = cs_unit_add(cs_table_find(db->s, LS_T_STRING), s, strlen(s), 0);
	if (!id) return 0;
	db->str[k].s = strdup(s); db->str[k].id = id; db->nstr++;
	return id;
}

uint32_t ls_unit(ls_db *db, uint32_t table, const void *payload, size_t len)
{
	cs_table *t = cs_table_find(db->s, table);
	return t ? cs_unit_add(t, payload, len, 0) : 0;
}

uint32_t ls_array(ls_db *db, const uint32_t *ids, size_t n)
{
	int narrow = 1;
	for (size_t i = 0; i < n; i++) if (ids[i] > 0xffff) narrow = 0;
	size_t len = 4 + n * (narrow ? 2 : 4);
	uint8_t *b = malloc(len);
	if (!b) return 0;
	p32(b, (uint32_t)n | (narrow ? 0x20000000u : 0));
	for (size_t i = 0; i < n; i++) { if (narrow) { uint16_t v = (uint16_t)ids[i]; memcpy(b + 4 + 2 * i, &v, 2); } else p32(b + 4 + 4 * i, ids[i]); }
	uint32_t id = ls_unit(db, LS_T_ARRAY, b, len);
	free(b);
	return id;
}

int ls_bind(ls_db *db, uint32_t table, uint32_t key, uint32_t unit)
{
	struct bent *e = NULL;
	for (size_t i = 0; i < db->nb; i++) if (db->b[i].table == table && db->b[i].key == key) { e = &db->b[i]; break; }
	if (!e) {
		if (db->nb == db->capb) { size_t c = db->capb ? db->capb * 2 : 256; struct bent *n = realloc(db->b, c * sizeof *n); if (!n) return -1; db->b = n; db->capb = c; }
		e = &db->b[db->nb++]; memset(e, 0, sizeof *e); e->table = table; e->key = key;
	}
	for (size_t i = 0; i < e->n; i++) if (e->units[i] == unit) return 0;
	if (e->n == e->cap) { size_t c = e->cap ? e->cap * 2 : 4; uint32_t *n = realloc(e->units, c * 4); if (!n) return -1; e->units = n; e->cap = c; }
	e->units[e->n++] = unit;
	return 0;
}

void ls_set_sequence(ls_db *db, uint64_t seq)
{
	size_t n; uint8_t *h = cs_table_extra(cs_table_find(db->s, LS_T_DBHEADER), &n);
	db->seq = seq;
	if (h && n >= 0x88) p64(h + 0x80, seq);
}
uint64_t ls_sequence(ls_db *db) { return db->seq; }

ls_db *ls_db_new(const ls_db_info *in)
{
	ls_db *db = calloc(1, sizeof *db);
	if (!db || !(db->s = cs_store_new())) { free(db); return NULL; }
	uint8_t h[0xc0] = { 0 };
	p32(h, LS_SCHEMA_VERSION); p32(h + 4, 0xc0);
	for (int i = 0; i < 4; i++) p64(h + 8 + 8 * i, in->system_version[i]);
	p32(h + 0x28, 0x05000001);
	if (in->build) strncpy((char *)h + 0x30, in->build, 15);
	if (in->model) strncpy((char *)h + 0x40, in->model, 63);
	p64(h + 0x80, in->sequence); memcpy(h + 0x88, in->uuid, 16); p32(h + 0x98, in->created);
	if (in->xcode) strncpy((char *)h + 0xa0, in->xcode, 31);
	db->seq = in->sequence;
	if (!cs_table_add(db->s, "DB Header", 4, h, sizeof h, 0)) goto fail;
	for (size_t i = 0; i < sizeof plain / sizeof plain[0]; i++) if (!cs_table_add(db->s, plain[i].name, plain[i].id, NULL, 0, 0)) goto fail;
	for (size_t i = 0; i < sizeof bindt / sizeof bindt[0]; i++) {
		uint8_t ex[32] = { 0 };
		size_t exn = !strcmp(bindt[i].name, "BindableKeyMap") ? 32 : 28;
		p32(ex + 4, bindt[i].unit); p32(ex + 8, bindt[i].slots); p32(ex + 16, bindt[i].slots / 2); p32(ex + 20, EMPTY); p32(ex + 24, DELETED);
		cs_table *t = cs_table_add(db->s, bindt[i].name, bindt[i].id, ex, exn, bindt[i].unit / 4);
		if (!t) goto fail;
		size_t n = (size_t)bindt[i].slots * 8;
		uint8_t *slots = malloc(n);
		if (!slots) goto fail;
		for (size_t k = 0; k < n; k += 4) p32(slots + k, EMPTY);
		uint32_t ok = cs_unit_add(t, slots, n, bindt[i].unit);
		free(slots);
		if (!ok) goto fail;
	}
	uint8_t none[4] = { 0xff, 0xff, 0xff, 0xff };
	cs_table *st = cs_table_add(db->s, "<string>", 124, none, 4, 0), *ar = cs_table_add(db->s, "<array>", 128, NULL, 0, 0);
	if (!st || !ar || !cs_table_add(db->s, "<dictionary>", 132, NULL, 0, 0)) goto fail;
	cs_table_set_buckets(st, 8192); cs_table_set_buckets(ar, 8192);
	for (size_t i = 0; i < sizeof class_names / sizeof class_names[0]; i++) if (!ls_string(db, class_names[i])) goto fail;
	return db;
fail:
	ls_db_free(db);
	return NULL;
}

void ls_db_free(ls_db *db)
{
	if (!db) return;
	cs_store_free(db->s);
	for (size_t i = 0; i < db->capstr; i++) free(db->str[i].s);
	for (size_t i = 0; i < db->nb; i++) free(db->b[i].units);
	free(db->str); free(db->b); free(db);
}

/* the persisted string cache: u32 nbuckets | nbuckets x { u32 count, u32 absolute offset of the entries (0xffffffff when empty) } | entries { u32 string id, u32 0x101 } */
static uint8_t *string_cache(void *ctx, uint32_t base, size_t *len)
{
	ls_db *db = ctx;
	enum { NB = 8192 };
	uint32_t *count = calloc(NB, 4), *start = calloc(NB, 4), *bucket = calloc(db->nstr ? db->nstr : 1, 4);
	struct sent **order = calloc(db->nstr ? db->nstr : 1, sizeof *order);
	size_t n = 0;
	uint8_t *out = NULL;
	if (!count || !start || !bucket || !order) goto done;
	for (size_t i = 0; i < db->capstr; i++) if (db->str[i].s) order[n++] = &db->str[i];
	/* in the order of the string ids, like the units */
	for (size_t i = 1; i < n; i++) { struct sent *x = order[i]; size_t k = i; while (k > 0 && order[k - 1]->id > x->id) { order[k] = order[k - 1]; k--; } order[k] = x; }
	for (size_t i = 0; i < n; i++) { bucket[i] = ls_string_hash((const uint8_t *)order[i]->s, strlen(order[i]->s)) % NB; count[bucket[i]]++; }
	*len = 4 + 8 * (size_t)NB + 8 * n;
	if (!(out = malloc(*len))) goto done;
	p32(out, NB);
	uint32_t cur = base + 4 + 8 * NB;
	for (uint32_t b = 0; b < NB; b++) { p32(out + 4 + 8 * b, count[b]); p32(out + 8 + 8 * b, count[b] ? cur : 0xffffffffu); start[b] = cur; cur += 8 * count[b]; }
	for (size_t i = 0; i < n; i++) { uint32_t at = start[bucket[i]] - base; p32(out + at, order[i]->id); p32(out + at + 4, 0x101); start[bucket[i]] += 8; }
done:
	free(count); free(start); free(bucket); free(order);
	return out;
}

static int write_bindings(ls_db *db)
{
	for (size_t ti = 0; ti < sizeof bindt / sizeof bindt[0]; ti++) {
		cs_table *t = cs_table_find(db->s, bindt[ti].id);
		size_t nkeys = 0, exn;
		for (size_t i = 0; i < db->nb; i++) if (db->b[i].table == bindt[ti].id) nkeys++;
		if (!nkeys) continue;
		uint32_t n = bindt[ti].slots;
		for (size_t p = 0; p < sizeof primes / sizeof primes[0]; p++) if (nkeys * 2 <= primes[p]) { if (primes[p] > n) n = primes[p]; break; }
		uint32_t *kv = malloc((size_t)n * 8);
		if (!kv) return -1;
		for (uint32_t i = 0; i < 2 * n; i++) kv[i] = EMPTY;
		for (size_t i = 0; i < db->nb; i++) if (db->b[i].table == bindt[ti].id) {
			uint32_t arr = ls_array(db, db->b[i].units, db->b[i].n), k = db->b[i].key % n;
			if (!arr) { free(kv); return -1; }
			while (kv[k] != EMPTY) k = (k + 1) % n;          /* linear probing, wrapping (CSMapFindBucketForKey) */
			kv[k] = db->b[i].key; kv[n + k] = arr;
		}
		int r = cs_unit_set(t, bindt[ti].unit, kv, (size_t)n * 8);
		free(kv);
		if (r) return -1;
		uint8_t *ex = cs_table_extra(t, &exn);
		p32(ex + 4, bindt[ti].unit); p32(ex + 8, n); p32(ex + 12, n - (uint32_t)nkeys); p32(ex + 16, n / 2);
	}
	return 0;
}

uint8_t *ls_db_build(ls_db *db, size_t *len)
{
	if (write_bindings(db)) return NULL;
	cs_table_set_raw(cs_table_find(db->s, LS_T_STRING), string_cache, db);
	return cs_store_build(db->s, 1, len);
}
