/* CSStore2 container writer (research/docs/LAUNCHSERVICES-WIRE.md 5.1, 5.2).
 *   header  u32 magic "bdsl" (0x6c736462), u8 version 2, u8 0, u16 checksum, u32 generation, u32 used, u32 live
 *   +0x14   the <catalog> table unit (header word 0x7fffdb5d), whose records are the tables
 *   unit    u32 hdr (id >> 2; bit 30 = table unit), u32 payload length, payload, padding to 4 bytes
 *   table   name[48], u64 0, u64 0, u32 last allocated index, u32 offset of its id map (0xffffffff none), extra
 *   id map  u32 nbuckets, nbuckets x { u32 count, u32 offset of the entries }, entries { u32 id, u32 unit offset }; bucket = (id >> 2) % nbuckets */
#include "csstore.h"
#include <stdlib.h>
#include <string.h>

struct cs_unit { uint32_t id; uint8_t *p; size_t n; };
struct cs_table {
	char name[48]; uint32_t id, next, nbuckets;
	uint8_t *extra; size_t extra_len;
	struct cs_unit *u; size_t nu, cap;
	cs_raw_fn raw; void *raw_ctx;
};
struct cs_store { cs_table **t; size_t nt, cap; };

cs_store *cs_store_new(void) { return calloc(1, sizeof(cs_store)); }

void cs_store_free(cs_store *s)
{
	if (!s) return;
	for (size_t i = 0; i < s->nt; i++) {
		cs_table *t = s->t[i];
		for (size_t k = 0; k < t->nu; k++) free(t->u[k].p);
		free(t->u); free(t->extra); free(t);
	}
	free(s->t); free(s);
}

cs_table *cs_table_add(cs_store *s, const char *name, uint32_t id, const void *extra, size_t extra_len, uint32_t next_index)
{
	cs_table *t = calloc(1, sizeof *t);
	if (!t) return NULL;
	strncpy(t->name, name, sizeof t->name - 1);
	t->id = id; t->next = next_index;
	if (extra_len) { t->extra = malloc(extra_len); if (!t->extra) { free(t); return NULL; } memcpy(t->extra, extra, extra_len); t->extra_len = extra_len; }
	if (s->nt == s->cap) { size_t c = s->cap ? s->cap * 2 : 40; cs_table **n = realloc(s->t, c * sizeof *n); if (!n) { free(t->extra); free(t); return NULL; } s->t = n; s->cap = c; }
	s->t[s->nt++] = t;
	return t;
}

cs_table *cs_table_find(cs_store *s, uint32_t id) { for (size_t i = 0; i < s->nt; i++) if (s->t[i]->id == id) return s->t[i]; return NULL; }
void cs_table_set_buckets(cs_table *t, uint32_t nbuckets) { t->nbuckets = nbuckets; }
uint8_t *cs_table_extra(cs_table *t, size_t *len) { if (len) *len = t->extra_len; return t->extra; }
void cs_table_set_raw(cs_table *t, cs_raw_fn fn, void *ctx) { t->raw = fn; t->raw_ctx = ctx; }

uint32_t cs_unit_add(cs_table *t, const void *payload, size_t len, uint32_t uid)
{
	if (uid == 0) uid = ++t->next * 4;
	else if (uid / 4 > t->next) t->next = uid / 4;
	if (t->nu == t->cap) { size_t c = t->cap ? t->cap * 2 : 64; struct cs_unit *n = realloc(t->u, c * sizeof *n); if (!n) return 0; t->u = n; t->cap = c; }
	uint8_t *p = malloc(len ? len : 1);
	if (!p) return 0;
	if (len) memcpy(p, payload, len);
	t->u[t->nu++] = (struct cs_unit){ uid, p, len };
	return uid;
}

uint8_t *cs_unit_payload(cs_table *t, uint32_t uid, size_t *len)
{
	for (size_t k = 0; k < t->nu; k++) if (t->u[k].id == uid) { if (len) *len = t->u[k].n; return t->u[k].p; }
	return NULL;
}

int cs_unit_set(cs_table *t, uint32_t uid, const void *payload, size_t len)
{
	for (size_t k = 0; k < t->nu; k++) if (t->u[k].id == uid) {
		uint8_t *p = malloc(len ? len : 1);
		if (!p) return -1;
		if (len) memcpy(p, payload, len);
		free(t->u[k].p); t->u[k].p = p; t->u[k].n = len;
		return 0;
	}
	return cs_unit_add(t, payload, len, uid) ? 0 : -1;
}

uint32_t cs_crc32(uint32_t crc, const uint8_t *p, size_t n)
{
	static uint32_t tab[256];
	if (!tab[1]) for (uint32_t i = 0; i < 256; i++) { uint32_t c = i; for (int k = 0; k < 8; k++) c = c & 1 ? 0xedb88320u ^ (c >> 1) : c >> 1; tab[i] = c; }
	crc = ~crc;
	while (n--) crc = tab[(crc ^ *p++) & 0xff] ^ (crc >> 8);
	return ~crc;
}

/* growing output buffer */
typedef struct { uint8_t *b; size_t n, cap; int err; } buf;
static void reserve(buf *o, size_t add)
{
	if (o->err || o->n + add <= o->cap) return;
	size_t c = o->cap ? o->cap : 1 << 16;
	while (c < o->n + add) c *= 2;
	uint8_t *nb = realloc(o->b, c);
	if (!nb) { o->err = 1; return; }
	memset(nb + o->cap, 0, c - o->cap); o->b = nb; o->cap = c;
}
static void align4(buf *o) { reserve(o, 4); if (!o->err) while (o->n % 4) o->b[o->n++] = 0; }
static uint32_t put(buf *o, const void *p, size_t n) { align4(o); reserve(o, n); if (o->err) return 0; uint32_t off = (uint32_t)o->n; if (p) memcpy(o->b + o->n, p, n); o->n += n; return off; }
static void w32(buf *o, size_t at, uint32_t v) { if (!o->err) memcpy(o->b + at, &v, 4); }
static uint32_t put_unit(buf *o, uint32_t hdr, const void *p, size_t n)
{
	uint32_t h[2] = { hdr, (uint32_t)n };
	uint32_t off = put(o, h, 8);
	reserve(o, n); if (o->err) return 0;
	if (p && n) memcpy(o->b + o->n, p, n);
	o->n += n;
	return off;
}

struct ent { uint32_t key, val; };
static uint32_t put_idmap(buf *o, const struct ent *e, size_t ne, uint32_t nb)
{
	if (nb == 0) nb = ne > 16 ? (uint32_t)ne : 16;
	uint32_t *count = calloc(nb, 4);
	if (!count) { o->err = 1; return 0; }
	for (size_t i = 0; i < ne; i++) count[(e[i].key >> 2) % nb]++;
	align4(o);
	uint32_t base = (uint32_t)o->n, ent_off = base + 4 + 8 * nb;
	reserve(o, 4 + 8 * (size_t)nb + 8 * ne);
	if (o->err) { free(count); return 0; }
	w32(o, base, nb);
	uint32_t cur = ent_off;
	uint32_t *start = calloc(nb, 4);
	if (!start) { free(count); o->err = 1; return 0; }
	for (uint32_t b = 0; b < nb; b++) { w32(o, base + 4 + 8 * b, count[b]); w32(o, base + 8 + 8 * b, cur); start[b] = cur; cur += 8 * count[b]; }
	for (size_t i = 0; i < ne; i++) { uint32_t b = (e[i].key >> 2) % nb; w32(o, start[b], e[i].key); w32(o, start[b] + 4, e[i].val); start[b] += 8; }
	o->n = cur;
	free(count); free(start);
	return base;
}

static int by_id(const void *a, const void *b) { uint32_t x = ((const struct cs_unit *)a)->id, y = ((const struct cs_unit *)b)->id; return x < y ? -1 : x > y; }

uint8_t *cs_store_build(cs_store *s, uint32_t generation, size_t *len)
{
	buf o = { 0 };
	uint32_t *toff = calloc(s->nt ? s->nt : 1, 4), *imap = calloc(s->nt ? s->nt : 1, 4);
	if (!toff || !imap) { free(toff); free(imap); return NULL; }
	reserve(&o, 0x14 + 80); o.n = 0x14 + 80;                 /* header + the catalog unit, written last */
	for (size_t i = 0; i < s->nt; i++) {
		cs_table *t = s->t[i];
		toff[i] = put_unit(&o, 0x40000000u | (t->id >> 2), NULL, 72 + t->extra_len);
		qsort(t->u, t->nu, sizeof *t->u, by_id);
		struct ent *e = calloc(t->nu ? t->nu : 1, sizeof *e);
		if (!e) { o.err = 1; break; }
		for (size_t k = 0; k < t->nu; k++) e[k] = (struct ent){ t->u[k].id, put_unit(&o, t->u[k].id >> 2, t->u[k].p, t->u[k].n) };
		imap[i] = put_idmap(&o, e, t->nu, t->nbuckets);
		free(e);
		if (t->raw && t->extra_len >= 4 && !o.err) {
			align4(&o);
			uint32_t at = (uint32_t)o.n; size_t rn = 0;
			uint8_t *rb = t->raw(t->raw_ctx, at, &rn);
			if (!rb) { o.err = 1; break; }
			put(&o, rb, rn); free(rb);
			memcpy(t->extra, &at, 4);
		}
	}
	/* the table units, now that the id maps are placed */
	for (size_t i = 0; i < s->nt && !o.err; i++) {
		cs_table *t = s->t[i];
		uint8_t *body = o.b + toff[i] + 8;
		memset(body, 0, 72);
		memcpy(body, t->name, strlen(t->name));
		memcpy(body + 64, &t->next, 4); memcpy(body + 68, &imap[i], 4);
		if (t->extra_len) memcpy(body + 72, t->extra, t->extra_len);
	}
	/* the catalog: its records are the tables */
	struct ent *ce = calloc(s->nt ? s->nt : 1, sizeof *ce);
	if (!ce) o.err = 1;
	for (size_t i = 0; i < s->nt && ce; i++) ce[i] = (struct ent){ s->t[i]->id, toff[i] };
	uint32_t cim = ce ? put_idmap(&o, ce, s->nt, 0) : 0;
	free(ce);
	if (o.err) { free(o.b); free(toff); free(imap); return NULL; }
	uint8_t *cat = o.b + 0x14;
	uint32_t ch[2] = { 0x7fffdb5d, 72 }, last = 0x21;
	memcpy(cat, ch, 8); memset(cat + 8, 0, 72); memcpy(cat + 8, "<catalog>", 9); memcpy(cat + 8 + 64, &last, 4); memcpy(cat + 8 + 68, &cim, 4);
	align4(&o);
	uint32_t used = (uint32_t)o.n;
	uint32_t magic = 0x6c736462;
	memcpy(o.b, &magic, 4); o.b[4] = 2; o.b[5] = 0;
	memcpy(o.b + 8, &generation, 4); memcpy(o.b + 12, &used, 4); memcpy(o.b + 16, &used, 4);
	uint32_t c = cs_crc32(0x6e797267, o.b + 100, used - 100);
	uint16_t ck = (c & 0xffff) > 2 ? (uint16_t)(c & 0xffff) : (uint16_t)((c & 0xffff) | 0xe000);
	memcpy(o.b + 6, &ck, 2);
	size_t total = (used + 4095) & ~(size_t)4095;            /* the files are whole pages */
	reserve(&o, total - o.n); if (o.err) { free(o.b); free(toff); free(imap); return NULL; }
	memset(o.b + used, 0, total - used);
	free(toff); free(imap);
	*len = total;
	return o.b;
}
