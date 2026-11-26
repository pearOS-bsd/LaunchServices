/* The Launch Services database of macOS 26.7.2 in a CSStore2 container: the schema (DB Header, the 33 tables), strings (interned; 1..5 character strings of the
 * packed alphabet are immediate ids), arrays, string bindings and the persisted string cache that clients look strings up in.
 * Format and evidence: research/docs/LAUNCHSERVICES-WIRE.md 5.2-5.9 (github.com/pearOS-bsd/research).  Our own code (BSD-2-Clause). */
#ifndef LS_LSDB_H
#define LS_LSDB_H
#include <stdint.h>
#include <stddef.h>
#include "csstore.h"

#define LS_SCHEMA_VERSION 0x01400019u     /* 20971545: in the name of the file */
/* table ids */
enum { LS_T_DBHEADER = 4, LS_T_BUNDLE = 8, LS_T_CLAIM = 12, LS_T_SERVICE = 16, LS_T_TYPE = 20, LS_T_HANDLERPREF = 24, LS_T_CONTAINER = 28, LS_T_ALIAS = 32,
	LS_T_PLUGIN = 36, LS_T_EXTENSIONPOINT = 40, LS_T_BINDINGLIST = 44, LS_T_PROPERTYLIST = 48, LS_T_LOCALIZEDSTRING = 52, LS_T_CANONICALSTRING = 56,
	LS_T_BINDABLEKEYMAP = 60, LS_T_UTIBINDING = 64, LS_T_EXTENSIONBINDING = 68, LS_T_OSTYPEBINDING = 72, LS_T_MIMEBINDING = 76, LS_T_URLSCHEMEBINDING = 92,
	LS_T_BUNDLEIDBINDING = 96, LS_T_BUNDLENAMEBINDING = 100, LS_T_ACTIVITYTYPEBINDING = 104, LS_T_STRING = 124, LS_T_ARRAY = 128, LS_T_DICTIONARY = 132 };

typedef struct ls_db_info {
	uint64_t sequence;              /* CacheSequenceNum: bumped by every change of the database */
	uint8_t  uuid[16];              /* CacheGUID: fixed when the database is created */
	uint32_t created;               /* POSIX seconds */
	uint64_t system_version[4];     /* e.g. 26, 7, 2, 0 */
	const char *build;              /* "25G332" */
	const char *model;              /* "/iMac19,1" */
	const char *xcode;              /* "2416" */
} ls_db_info;

typedef struct ls_db ls_db;

ls_db *ls_db_new(const ls_db_info *info);     /* every table, the 8 binding class names (ids 4 .. 0x20, like a real store) */
void ls_db_free(ls_db *db);
uint32_t ls_string(ls_db *db, const char *utf8);                       /* interned string id (0 for NULL / empty) */
uint32_t ls_array(ls_db *db, const uint32_t *ids, size_t n);            /* an <array> unit: u16 elements when all < 0x10000 */
uint32_t ls_unit(ls_db *db, uint32_t table, const void *payload, size_t len);
int ls_bind(ls_db *db, uint32_t table, uint32_t key_string, uint32_t unit);   /* key -> list of units, written as an array at build */
void ls_set_sequence(ls_db *db, uint64_t seq);
uint64_t ls_sequence(ls_db *db);
uint8_t *ls_db_build(ls_db *db, size_t *len);                          /* the file (bindings and string cache made here) */
/* the hash of the string cache (CSStore2::_StringFunctions::getHashCode) */
uint32_t ls_string_hash(const uint8_t *b, size_t n);
#endif
