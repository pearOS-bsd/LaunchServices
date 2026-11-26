/* writes an empty Launch Services store: test/empty_store OUT SEQ UUIDHEX32 TIME  (compared byte for byte with research/tools/launchservices/make_empty_store.py) */
#include "../store/lsdb.h"
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv)
{
	if (argc < 5) return 2;
	ls_db_info in = { .sequence = strtoull(argv[2], 0, 10), .created = (uint32_t)strtoul(argv[4], 0, 10), .system_version = { 26, 7, 2, 0 }, .build = "25G332", .model = "/iMac19,1", .xcode = "2416" };
	for (int i = 0; i < 16; i++) { unsigned v; sscanf(argv[3] + 2 * i, "%2x", &v); in.uuid[i] = (uint8_t)v; }
	cs_store *s = ls_db_new(&in);
	size_t n; uint8_t *b = s ? cs_store_build(s, 1, &n) : NULL;
	if (!b) return 1;
	FILE *f = fopen(argv[1], "wb"); fwrite(b, 1, n, f); fclose(f);
	printf("%zu bytes\n", n);
	return 0;
}
