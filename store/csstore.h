/* Writer of the CSStore2 container (CoreServicesStore: the Launch Services database of macOS 26.7.2, `com.apple.LaunchServices-20971545-v2.csstore`).
 * Format and evidence: research/docs/LAUNCHSERVICES-WIRE.md section 5 (github.com/pearOS-bsd/research); checked there against Apple's own reader.
 * A store is a list of tables; each table holds units (id -> payload).  csstore_build lays them out (4-byte aligned units, id maps, the catalog,
 * the header with its CRC) the way CSStore2::Store reads them.  Our own code (BSD-2-Clause). */
#ifndef LS_CSSTORE_H
#define LS_CSSTORE_H
#include <stddef.h>
#include <stdint.h>

typedef struct cs_table cs_table;
typedef struct cs_store cs_store;

cs_store *cs_store_new(void);
void cs_store_free(cs_store *s);
/* a table: name (at most 47 bytes), id (4, 8, 12 ...: the catalog order), the table-specific extra bytes, the first free index (unit ids are 4 * index) */
cs_table *cs_table_add(cs_store *s, const char *name, uint32_t id, const void *extra, size_t extra_len, uint32_t next_index);
/* the number of id-map buckets (0 = the number of units, at least 16).  <string> and <array> need a power of two (the Mac's files use 8192) */
cs_table *cs_table_find(cs_store *s, uint32_t id);
void cs_table_set_buckets(cs_table *t, uint32_t nbuckets);
uint8_t *cs_table_extra(cs_table *t, size_t *len);        /* the extra bytes, to patch after the table was added */
/* adds a unit; uid 0 = the next id of the table.  Returns the unit id (0 on failure). */
uint32_t cs_unit_add(cs_table *t, const void *payload, size_t len, uint32_t uid);
/* the payload of a unit added before (to patch it), NULL if none */
uint8_t *cs_unit_payload(cs_table *t, uint32_t uid, size_t *len);
/* the whole file (page-rounded), malloc'ed; *len = its length */
uint8_t *cs_store_build(cs_store *s, uint32_t generation, size_t *len);
/* the checksum of the header: crc32 with seed 0x6e797267 over bytes [100, used) */
uint32_t cs_crc32(uint32_t crc, const uint8_t *p, size_t n);
#endif
