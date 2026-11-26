/* The Launch Services database of macOS 26.7.2 in a CSStore2 container: the DB Header table and the 33 tables (research/docs/LAUNCHSERVICES-WIRE.md 5.2, 5.3).
 * Our own code (BSD-2-Clause). */
#ifndef LS_LSDB_H
#define LS_LSDB_H
#include <stdint.h>
#include <stddef.h>
#include "csstore.h"

typedef struct ls_db_info {
	uint64_t sequence;              /* CacheSequenceNum: bumped by every change of the database */
	uint8_t  uuid[16];              /* CacheGUID: fixed when the database is created */
	uint32_t created;               /* POSIX seconds */
	uint64_t system_version[4];     /* e.g. 26, 7, 2, 0 */
	const char *build;              /* "25G332" */
	const char *model;              /* "/iMac19,1" */
	const char *xcode;              /* "2416" */
} ls_db_info;

/* the store with every table of the schema and no record; *strings, *arrays: the <string> / <array> tables, for the records added after */
cs_store *ls_db_new(const ls_db_info *info);
cs_table *ls_db_table(cs_store *s, uint32_t id);
#define LS_SCHEMA_VERSION 0x01400019u     /* 20971545: in the name of the file */
#endif
