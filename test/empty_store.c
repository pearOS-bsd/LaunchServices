/* writes a Launch Services store: test/empty_store OUT SEQ UUIDHEX32 TIME [bind]   (compared byte for byte with research/tools/launchservices/lsbuild.py)
 * with "bind": the strings com.example.app (interned) and "ab" (immediate) and BundleIDBinding com.example.app -> [8, 12] */
#include "../store/lsdb.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv)
{
	if (argc < 5) return 2;
	ls_db_info in = { .sequence = strtoull(argv[2], 0, 10), .created = (uint32_t)strtoul(argv[4], 0, 10), .system_version = { 26, 7, 2, 0 }, .build = "25G332", .model = "/iMac19,1", .xcode = "2416" };
	for (int i = 0; i < 16; i++) { unsigned v; sscanf(argv[3] + 2 * i, "%2x", &v); in.uuid[i] = (uint8_t)v; }
	ls_db *db = ls_db_new(&in);
	if (!db) return 1;
	if (argc > 5 && !strcmp(argv[5], "bind")) {
		uint32_t s = ls_string(db, "com.example.app"), im = ls_string(db, "ab");
		printf("string id %#x, immediate %#x\n", s, im);
		ls_bind(db, LS_T_BUNDLEIDBINDING, s, 8); ls_bind(db, LS_T_BUNDLEIDBINDING, s, 12);
	}
	size_t n; uint8_t *b = ls_db_build(db, &n);
	if (!b) return 1;
	FILE *f = fopen(argv[1], "wb"); fwrite(b, 1, n, f); fclose(f);
	printf("%zu bytes\n", n);
	ls_db_free(db);
	return 0;
}
