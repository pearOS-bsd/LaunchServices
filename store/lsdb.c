/* The schema of the Launch Services database (macOS 26.7.2): table ids, names and extra bytes as in the Mac's file (research/docs/LAUNCHSERVICES-WIRE.md 5.2-5.5). */
#include "lsdb.h"
#include <string.h>
#include <stdlib.h>

static const struct { uint32_t id; const char *name; } plain[] = {
	{ 8, "Bundle" }, { 12, "Claim" }, { 16, "Service" }, { 20, "Type" }, { 24, "HandlerPref" }, { 28, "Container" }, { 32, "Alias" }, { 36, "Plugin" },
	{ 40, "ExtensionPoint" }, { 44, "BindingList" }, { 48, "PropertyList" }, { 52, "LocalizedString" }, { 56, "CanonicalString" } };
/* the string binding tables: an open-addressing hash table of 8-byte slots in one unit (id `unit`), `slots` slots; empty slot 0xeeeeeee1/0xeeeeeee1, tombstone 0xddddddd2 */
static const struct { uint32_t id; const char *name; uint32_t unit, slots; } bind[] = {
	{ 60, "BindableKeyMap", 0x14, 8161 }, { 64, "UTIBinding", 0x14, 8161 }, { 68, "ExtensionBinding", 0xc, 2041 }, { 72, "OSTypeBinding", 8, 1021 },
	{ 76, "MIMEBinding", 8, 1021 }, { 80, "NSPasteboardBinding", 4, 511 }, { 84, "DeviceModelCodeBinding", 0x10, 4081 }, { 88, "BluetoothVendorProductIDBinding", 4, 511 },
	{ 92, "URLSchemeBinding", 4, 511 }, { 96, "BundleIDBinding", 8, 1021 }, { 100, "BundleNameBinding", 0xc, 2041 }, { 104, "ActivityTypeBinding", 0xc, 2041 },
	{ 108, "PluginBundleIDBinding", 0xc, 2041 }, { 112, "PluginProtocolBinding", 4, 511 }, { 116, "PluginUUIDBinding", 0xc, 2041 }, { 120, "ExtensionPointIDBinding", 4, 511 } };

static void p32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static void p64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }

cs_store *ls_db_new(const ls_db_info *in)
{
	cs_store *s = cs_store_new();
	if (!s) return NULL;
	uint8_t h[0xc0] = { 0 };
	p32(h, LS_SCHEMA_VERSION); p32(h + 4, 0xc0);
	for (int i = 0; i < 4; i++) p64(h + 8 + 8 * i, in->system_version[i]);
	p32(h + 0x28, 0x05000001);
	if (in->build) strncpy((char *)h + 0x30, in->build, 15);
	if (in->model) strncpy((char *)h + 0x40, in->model, 63);
	p64(h + 0x80, in->sequence); memcpy(h + 0x88, in->uuid, 16); p32(h + 0x98, in->created);
	if (in->xcode) strncpy((char *)h + 0xa0, in->xcode, 31);
	if (!cs_table_add(s, "DB Header", 4, h, sizeof h, 0)) goto fail;
	for (size_t i = 0; i < sizeof plain / sizeof plain[0]; i++) if (!cs_table_add(s, plain[i].name, plain[i].id, NULL, 0, 0)) goto fail;
	for (size_t i = 0; i < sizeof bind / sizeof bind[0]; i++) {
		uint8_t ex[32] = { 0 };
		size_t exn = !strcmp(bind[i].name, "BindableKeyMap") ? 32 : 28;
		p32(ex + 4, bind[i].unit); p32(ex + 8, bind[i].slots); p32(ex + 16, bind[i].slots / 2); p32(ex + 20, 0xeeeeeee1); p32(ex + 24, 0xddddddd2);
		cs_table *t = cs_table_add(s, bind[i].name, bind[i].id, ex, exn, bind[i].unit / 4);
		if (!t) goto fail;
		size_t n = (size_t)bind[i].slots * 8;
		uint8_t *slots = malloc(n);
		if (!slots) goto fail;
		for (size_t k = 0; k < n; k += 4) p32(slots + k, 0xeeeeeee1);
		uint32_t ok = cs_unit_add(t, slots, n, bind[i].unit);
		free(slots);
		if (!ok) goto fail;
	}
	uint8_t none[4] = { 0xff, 0xff, 0xff, 0xff };
	cs_table *st = cs_table_add(s, "<string>", 124, none, 4, 0), *ar = cs_table_add(s, "<array>", 128, NULL, 0, 0);
	if (!st || !ar || !cs_table_add(s, "<dictionary>", 132, NULL, 0, 0)) goto fail;
	cs_table_set_buckets(st, 8192); cs_table_set_buckets(ar, 8192);
	return s;
fail:
	cs_store_free(s);
	return NULL;
}

cs_table *ls_db_table(cs_store *s, uint32_t id) { return cs_table_find(s, id); }
