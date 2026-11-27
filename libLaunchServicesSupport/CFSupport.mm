/* SPDX-License-Identifier: BSD-2-Clause */
/* libLaunchServicesSupport: the C++ CoreFoundation helpers (C++ linkage, Itanium-mangled names as in Apple's
 * /usr/lib/libLaunchServicesSupport.dylib of macOS 26.7.2).  Every function does what Apple's does, including
 * its odd corners (they are marked "as Apple"); the evidence is in research/docs/LAUNCHSERVICESSUPPORT.md. */
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include "LSSupportSPI.h"
#include <Security/Security.h>
#include <libproc.h>
#include <ctype.h>
#include <wctype.h>
#include <stdlib.h>
#include <algorithm>
#include <sstream>
#include <iomanip>
#include <string>
#include <vector>

#define LSS_EXPORT __attribute__((visibility("default")))

typedef bool (^LSApplyBlock)(const void *);
typedef bool (^LSApplyKVBlock)(const void *, const void *);
typedef CFComparisonResult (^LSCompareBlock)(const void *, const void *);
typedef const void *(^LSMapBlock)(const void *, bool *);

/* ---------------------------------------------------------------- arrays */

LSS_EXPORT void CFArrayAppendArray(CFMutableArrayRef array, CFArrayRef other)
{
	if (other) CFArrayAppendArray(array, other, CFRangeMake(0, CFArrayGetCount(other)));
}

/* Apply the block to a copy of the array; stop when it returns false.  Returns the last result
 * (false for an empty or NULL array). */
LSS_EXPORT bool CFArrayApplyBlock(CFArrayRef array, LSApplyBlock block)
{
	if (!array) return false;
	CFArrayRef copy = CFArrayCreateCopy(kCFAllocatorDefault, array);
	CFIndex n = CFArrayGetCount(copy);
	bool r = false;
	for (CFIndex i = 0; i < n; i++) {
		r = block(CFArrayGetValueAtIndex(copy, i));
		if (!r) break;
	}
	if (copy) CFRelease(copy);
	return r;
}

/* Only the non-NULL items of the type (0 = any).  Returns true when the block ran at least once and never
 * returned false. */
LSS_EXPORT bool CFArrayApplyBlock(CFArrayRef array, unsigned long typeID, LSApplyBlock block)
{
	if (!array) return false;
	CFArrayRef copy = CFArrayCreateCopy(kCFAllocatorDefault, array);
	CFIndex n = CFArrayGetCount(copy);
	bool r = false;
	for (CFIndex i = 0; i < n; i++) {
		const void *v = CFArrayGetValueAtIndex(copy, i);
		if (!v || (typeID != 0 && typeID != CFGetTypeID(v))) continue;
		if (!block(CFArrayGetValueAtIndex(copy, i))) { r = false; break; }
		r = true;
	}
	if (copy) CFRelease(copy);
	return r;
}

/* The block returns a +1 object (or NULL to skip it) and may set *stop. */
LSS_EXPORT CFArrayRef CFArrayCreateByApplyingBlock(CFArrayRef array, unsigned long typeID, LSMapBlock block)
{
	if (!array) return NULL;
	CFArrayRef copy = CFArrayCreateCopy(kCFAllocatorDefault, array);
	bool stop = false;
	CFIndex n = CFArrayGetCount(copy);
	std::vector<const void *> out;
	out.reserve(n);
	for (CFIndex i = 0; i < n; i++) {
		const void *v = CFArrayGetValueAtIndex(copy, i);
		if (!v || (typeID != 0 && typeID != CFGetTypeID(v))) continue;
		const void *m = block(CFArrayGetValueAtIndex(copy, i), &stop);
		if (stop) { if (m) CFRelease(m); break; }
		if (m) out.push_back(m);
	}
	CFArrayRef r = NULL;
	if (!out.empty()) {
		r = CFArrayCreate(kCFAllocatorDefault, out.data(), out.size(), &kCFTypeArrayCallBacks);
		for (const void *m : out) CFRelease(m);
	}
	if (copy) CFRelease(copy);
	return r;
}

/* Sorted copy.  As Apple: the items are checked against typeID (0 matches nothing) and a mismatch gives an
 * unsorted copy; the sort orders with "compare(a, b) <= 0". */
LSS_EXPORT CFArrayRef CFArraySort(CFArrayRef array, unsigned long typeID, LSCompareBlock compare)
{
	if (!array) return NULL;
	CFIndex n = CFArrayGetCount(array);
	std::vector<const void *> v(n);
	CFArrayGetValues(array, CFRangeMake(0, n), v.data());
	if (n > 0) {
		CFTypeID t;
		CFIndex i = 1;
		do { t = CFGetTypeID(v[i - 1]); if (n <= i) break; i++; } while (t == typeID);
		if (t != typeID) return CFArrayCreateCopy(kCFAllocatorDefault, array);
	}
	bool (^less)(const void *const &, const void *const &) = ^bool(const void *const &a, const void *const &b) { return compare(a, b) < 1; };
	std::sort(v.begin(), v.end(), less);
	return CFArrayCreate(kCFAllocatorDefault, v.data(), v.size(), &kCFTypeArrayCallBacks);
}

LSS_EXPORT CFArrayRef CFArrayCopyMergedArrays(CFArrayRef a, CFArrayRef b)
{
	CFIndex na = 0;
	if (!a) { if (!b) return NULL; }
	else {
		na = CFArrayGetCount(a);
		if (!b) { if (na < 1) return NULL; CFRetain(a); return a; }
	}
	CFIndex nb = CFArrayGetCount(b);
	if (nb > 0 && na > 0) {
		std::vector<const void *> v;
		v.resize(na + nb);
		CFArrayGetValues(a, CFRangeMake(0, na), v.data());
		CFArrayGetValues(b, CFRangeMake(0, nb), v.data() + na);
		return CFArrayCreate(kCFAllocatorDefault, v.data(), v.size(), &kCFTypeArrayCallBacks);
	}
	if (na < 1) { if (nb > 0) { CFRetain(b); return b; } }
	else if (a) { CFRetain(a); return a; }
	return NULL;
}

/* The non-NULL items, in order; NULL when all are NULL. */
LSS_EXPORT CFArrayRef CFArrayCreateWithItems(const void *i1, const void *i2, const void *i3, const void *i4, const void *i5,
	const void *i6, const void *i7, const void *i8, const void *i9, const void *i10)
{
	const void *in[10] = { i1, i2, i3, i4, i5, i6, i7, i8, i9, i10 };
	std::vector<const void *> v;
	v.reserve(10);
	for (int i = 0; i < 10; i++) if (in[i]) v.push_back(in[i]);
	if (v.empty()) return NULL;
	return CFArrayCreate(kCFAllocatorDefault, v.data(), v.size(), &kCFTypeArrayCallBacks);
}

LSS_EXPORT CFArrayRef CFArrayCreateWithSet(CFSetRef set)
{
	if (!set) return NULL;
	std::vector<const void *> v(CFSetGetCount(set) + 1);
	CFSetGetValues(set, v.data());
	return CFArrayCreate(kCFAllocatorDefault, v.data(), CFSetGetCount(set), &kCFTypeArrayCallBacks);
}

/* Removes every occurrence; true when one was removed. */
LSS_EXPORT bool CFArrayRemoveValue(CFMutableArrayRef array, const void *value)
{
	if (CFArrayGetCount(array) < 1) return false;
	bool removed = false;
	CFIndex i = CFArrayGetFirstIndexOfValue(array, CFRangeMake(0, CFArrayGetCount(array)), value);
	while (i != -1) {
		CFArrayRemoveValueAtIndex(array, i);
		removed = true;
		if (CFArrayGetCount(array) <= i) return true;
		CFIndex n = CFArrayGetCount(array);
		i = CFArrayGetFirstIndexOfValue(array, CFRangeMake(i, n - i), value);
	}
	return removed;
}

LSS_EXPORT bool CFArrayRemoveValues(CFMutableArrayRef array, CFArrayRef values)
{
	if (values) CFArrayApplyBlock(values, ^bool(const void *v) { CFArrayRemoveValue(array, v); return true; });
	return true;
}

/* ---------------------------------------------------------------- hex */

LSS_EXPORT CFStringRef CFStringCreateByHexEncodingMemory(const void *bytes, unsigned long length)
{
	static const char hexCharsTable[] = "0123456789abcdef";
	std::vector<char> s(length * 2);
	const unsigned char *p = (const unsigned char *)bytes;
	for (size_t i = 0; i < s.size(); i += 2, p++) {
		s[i] = hexCharsTable[*p >> 4];
		s[i + 1] = hexCharsTable[*p & 15];
	}
	return CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)s.data(), s.size(), kCFStringEncodingASCII, false);
}

LSS_EXPORT CFStringRef CFStringCreateByHexEncodingData(CFDataRef data)
{
	if (!data) return CFStringCreateByHexEncodingMemory(NULL, 0);
	return CFStringCreateByHexEncodingMemory(CFDataGetBytePtr(data), CFDataGetLength(data));
}

static inline unsigned char hexValue(UniChar c)
{
	if ((UniChar)(c - '0') < 10) return c - '0';
	if ((UniChar)(c - 'A') < 6) return c - 'A' + 10;
	if ((UniChar)(c - 'a') < 6) return c - 'a' + 10;
	return 0;
}

/* Pairs of hex digits; an odd-length string that starts with '$' (asString's form) is read without it.
 * NULL when a pair is not hex or the length does not give whole bytes. */
LSS_EXPORT CFDataRef CFDataCreateFromHexEncodedString(CFStringRef string)
{
	CFIndex len = CFStringGetLength(string);
	if (len == 0) return CFDataCreate(kCFAllocatorDefault, NULL, 0);
	if ((len & 1) && CFStringGetCharacterAtIndex(string, 0) == '$') {
		CFStringRef sub = CFStringCreateWithSubstring(kCFAllocatorDefault, string, CFRangeMake(1, len - 1));
		CFDataRef d = CFDataCreateFromHexEncodedString(sub);
		if (sub) CFRelease(sub);
		return d;
	}
	std::vector<unsigned char> out;
	if (len > 1) {
		CFIndex i = 0;
		do {
			UniChar a = CFStringGetCharacterAtIndex(string, i), b = CFStringGetCharacterAtIndex(string, i + 1);
			if (!iswxdigit(a) || !iswxdigit(b)) break;
			out.push_back((unsigned char)(hexValue(a) * 16 + hexValue(b)));
			i += 2;
		} while (i < len - 1);
	}
	if ((long)out.size() != (long)(unsigned int)(len / 2)) return NULL;
	return CFDataCreate(kCFAllocatorDefault, out.data(), out.size());
}

/* ---------------------------------------------------------------- dictionaries */

/* As Apple: with a type, the block runs only when typeID == (CFGetTypeID(value) == typeID), that is for
 * typeID 1 only; typeID 0 runs it for every pair. */
LSS_EXPORT bool CFDictionaryApplyBlock(CFDictionaryRef dict, unsigned long typeID, LSApplyKVBlock block)
{
	CFIndex n;
	if (!block || !dict || (n = CFDictionaryGetCount(dict)) < 1) return false;
	CFDictionaryRef copy = CFDictionaryCreateCopy(kCFAllocatorDefault, dict);
	std::vector<const void *> keys(n), values(n);
	CFDictionaryGetKeysAndValues(copy, keys.data(), values.data());
	bool r = false;
	for (CFIndex i = 0; i < n; i++) {
		if (typeID != 0 && typeID != (unsigned long)(CFGetTypeID(values[i]) == typeID)) continue;
		if (!block(keys[i], values[i])) { r = false; break; }
		r = true;
	}
	if (copy) CFRelease(copy);
	return r;
}

LSS_EXPORT bool CFDictionaryApplyBlock(CFDictionaryRef dict, LSApplyKVBlock block)
{
	return CFDictionaryApplyBlock(dict, 0, block);
}

/* Pairs with a NULL key or value are left out; NULL when no pair is left. */
static CFDictionaryRef createWithPairs(const void *const *kv, int pairs)
{
	const void *keys[6], *values[6];
	int n = 0;
	for (int i = 0; i < pairs; i++)
		if (kv[2 * i] && kv[2 * i + 1]) { keys[n] = kv[2 * i]; values[n] = kv[2 * i + 1]; n++; }
	if (n == 0) return NULL;
	return CFDictionaryCreate(kCFAllocatorDefault, keys, values, n, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

LSS_EXPORT CFDictionaryRef CFDictionaryCreateWithItems(const void *k1, const void *v1, const void *k2, const void *v2)
{
	const void *kv[] = { k1, v1, k2, v2 };
	return createWithPairs(kv, 2);
}
LSS_EXPORT CFDictionaryRef CFDictionaryCreateWithItems(const void *k1, const void *v1, const void *k2, const void *v2, const void *k3, const void *v3)
{
	const void *kv[] = { k1, v1, k2, v2, k3, v3 };
	return createWithPairs(kv, 3);
}
LSS_EXPORT CFDictionaryRef CFDictionaryCreateWithItems(const void *k1, const void *v1, const void *k2, const void *v2, const void *k3, const void *v3,
	const void *k4, const void *v4)
{
	const void *kv[] = { k1, v1, k2, v2, k3, v3, k4, v4 };
	return createWithPairs(kv, 4);
}
LSS_EXPORT CFDictionaryRef CFDictionaryCreateWithItems(const void *k1, const void *v1, const void *k2, const void *v2, const void *k3, const void *v3,
	const void *k4, const void *v4, const void *k5, const void *v5)
{
	const void *kv[] = { k1, v1, k2, v2, k3, v3, k4, v4, k5, v5 };
	return createWithPairs(kv, 5);
}
LSS_EXPORT CFDictionaryRef CFDictionaryCreateWithItems(const void *k1, const void *v1, const void *k2, const void *v2, const void *k3, const void *v3,
	const void *k4, const void *v4, const void *k5, const void *v5, const void *k6, const void *v6)
{
	const void *kv[] = { k1, v1, k2, v2, k3, v3, k4, v4, k5, v5, k6, v6 };
	return createWithPairs(kv, 6);
}

static CFMutableDictionaryRef mutableCopyOrNew(CFDictionaryRef dict)
{
	if (!dict) return CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	return CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, dict);
}

LSS_EXPORT CFDictionaryRef CFDictionaryCreateCopyWithItem(CFDictionaryRef dict, const void *key, const void *value)
{
	CFMutableDictionaryRef m = mutableCopyOrNew(dict);
	if (value && key && m) CFDictionarySetValue(m, key, value);
	CFDictionaryRef r = CFDictionaryCreateCopy(kCFAllocatorDefault, m);
	if (m) CFRelease(m);
	return r;
}

/* As Apple: the fifth pair is stored the wrong way round (key v5, value k5). */
LSS_EXPORT CFDictionaryRef CFDictionaryCreateCopyWithItems(CFDictionaryRef dict, const void *k1, const void *v1, const void *k2, const void *v2,
	const void *k3, const void *v3, const void *k4, const void *v4, const void *k5, const void *v5)
{
	CFMutableDictionaryRef m = mutableCopyOrNew(dict);
	if (k1 && v1 && m) CFDictionarySetValue(m, k1, v1);
	if (k2 && v2 && m) CFDictionarySetValue(m, k2, v2);
	if (k3 && v3 && m) CFDictionarySetValue(m, k3, v3);
	if (k4 && v4 && m) CFDictionarySetValue(m, k4, v4);
	if (k5 && v5 && m) CFDictionarySetValue(m, v5, k5);
	CFDictionaryRef r = CFDictionaryCreateCopy(kCFAllocatorDefault, m);
	if (m) CFRelease(m);
	return r;
}

/* The value when it is of the type (and the conversion works), else the default. */
LSS_EXPORT bool CFDictionaryGetBooleanValue(CFDictionaryRef dict, CFStringRef key, bool def)
{
	if (!key || !dict) return def;
	CFTypeRef v = CFDictionaryGetValue(dict, key);
	CFTypeID t = CFBooleanGetTypeID();
	if (!v) return def;
	if (t != 0 && CFGetTypeID(v) != t) return def;
	return CFEqual(v, kCFBooleanTrue);
}

template <typename T>
static T numberValue(CFDictionaryRef dict, const void *key, T def, CFNumberType type)
{
	if (!dict || !key) { (void)CFNumberGetTypeID(); return def; }
	CFTypeRef v = CFDictionaryGetValue(dict, key);
	CFTypeID t = CFNumberGetTypeID();
	if (!v) return def;
	if (t != 0 && CFGetTypeID(v) != t) return def;
	T r = def;
	if (CFNumberGetValue((CFNumberRef)v, type, &r)) return r;
	return def;
}

LSS_EXPORT long CFDictionaryGetValueAsLong(CFDictionaryRef dict, const void *key, long def) { return numberValue<long>(dict, key, def, kCFNumberLongType); }
LSS_EXPORT double CFDictionaryGetValueAsDouble(CFDictionaryRef dict, CFStringRef key, double def) { return numberValue<double>(dict, key, def, kCFNumberDoubleType); }
LSS_EXPORT int CFDictionaryGetValueAsInt(CFDictionaryRef dict, CFStringRef key, int def) { return numberValue<int>(dict, key, def, kCFNumberIntType); }
LSS_EXPORT unsigned long long CFDictionaryGetValueAsUInt64(CFDictionaryRef dict, CFStringRef key, unsigned long long def) { return numberValue<unsigned long long>(dict, key, def, kCFNumberSInt64Type); }

static void mergeDictionaryItemsFunc(const void *key, const void *value, void *context)
{
	CFDictionarySetValue((CFMutableDictionaryRef)context, key, value);
}

/* b's pairs over a's; a copy of whichever is non-empty; NULL when b is NULL and a is empty. */
LSS_EXPORT CFDictionaryRef CFDictionaryCopyMerge(CFDictionaryRef a, CFDictionaryRef b)
{
	if (!a || CFDictionaryGetCount(a) == 0) {
		if (!b) return NULL;
		return CFDictionaryCreateCopy(kCFAllocatorDefault, b);
	}
	if (b && CFDictionaryGetCount(b) != 0) {
		CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, a);
		CFDictionaryApplyFunction(b, mergeDictionaryItemsFunc, m);
		CFDictionaryRef r = CFDictionaryCreateCopy(kCFAllocatorDefault, m);
		if (m) CFRelease(m);
		return r;
	}
	return CFDictionaryCreateCopy(kCFAllocatorDefault, a);
}

LSS_EXPORT CFDictionaryRef CFDictionaryCopyWithItem(CFDictionaryRef dict, const void *key, const void *value)
{
	if (!value || !key || !dict) {
		if (dict) return CFDictionaryCreateCopy(CFGetAllocator(dict), dict);
		if (!value || !key) return NULL;
		return CFDictionaryCreate(kCFAllocatorDefault, &key, &value, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	}
	CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, dict);
	CFDictionarySetValue(m, key, value);
	CFDictionaryRef r = CFDictionaryCreateCopy(CFGetAllocator(dict), m);
	if (m) CFRelease(m);
	return r;
}

LSS_EXPORT CFArrayRef CFDictionaryCopyAllKeys(CFDictionaryRef dict)
{
	CFIndex n;
	if (!dict || (n = CFDictionaryGetCount(dict)) < 1) return NULL;
	std::vector<const void *> v(n);
	CFDictionaryGetKeysAndValues(dict, v.data(), NULL);
	return CFArrayCreate(kCFAllocatorDefault, v.data(), v.size(), &kCFTypeArrayCallBacks);
}

LSS_EXPORT CFArrayRef CFDictionaryCopyAllValues(CFDictionaryRef dict)
{
	CFIndex n;
	if (!dict || (n = CFDictionaryGetCount(dict)) < 1) return NULL;
	std::vector<const void *> v(n);
	CFDictionaryGetKeysAndValues(dict, NULL, v.data());
	return CFArrayCreate(kCFAllocatorDefault, v.data(), v.size(), &kCFTypeArrayCallBacks);
}

/* ---------------------------------------------------------------- sets */

/* Optionally sorted (qsort_b with the sign of compare).  Returns true when every item was visited. */
LSS_EXPORT bool CFSetApplyBlock(CFSetRef set, LSCompareBlock compare, LSApplyBlock block)
{
	CFIndex n;
	if (!set || (n = CFSetGetCount(set)) < 1) return false;
	std::vector<const void *> v(n);
	CFSetGetValues(set, v.data());
	for (const void *o : v) if (o) CFRetain(o);
	if (compare)
		qsort_b(v.data(), v.size(), sizeof(void *), ^int(const void *a, const void *b) {
			CFComparisonResult c = compare(*(const void *const *)a, *(const void *const *)b);
			return (c > 0) - (c < 0);
		});
	bool done = false;
	for (size_t i = 0;; i++) {
		done = (i == v.size());
		if (done) break;
		if (!block(v[i])) break;
	}
	for (const void *&o : v) { if (o) CFRelease(o); o = NULL; }
	return done;
}

LSS_EXPORT bool CFSetApplyBlock(CFSetRef set, LSApplyBlock block)
{
	return CFSetApplyBlock(set, (LSCompareBlock)NULL, block);
}

LSS_EXPORT CFSetRef CFSetCreateWithArray(CFArrayRef array)
{
	if (!array) return NULL;
	CFIndex n = CFArrayGetCount(array);
	if (n < 1) return CFSetCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeSetCallBacks);
	std::vector<const void *> v(n);
	CFArrayGetValues(array, CFRangeMake(0, n), v.data());
	return CFSetCreate(kCFAllocatorDefault, v.data(), n, &kCFTypeSetCallBacks);
}

/* As Apple: it reads the values of the destination set itself and adds them back, so the set does not change. */
LSS_EXPORT void CFSetAppendSet(CFMutableSetRef set, CFSetRef other)
{
	if (!set || !other || CFSetGetCount(other) < 1) return;
	CFIndex n = CFSetGetCount(set);
	std::vector<const void *> v(n);
	CFSetGetValues(set, n ? v.data() : NULL);
	for (const void *o : v) CFSetAddValue(set, o);
}

LSS_EXPORT CFSetRef CFSetCreateMergedSet(CFSetRef a, CFSetRef b)
{
	if (!a || !b) {
		if (a) { CFRetain(a); return a; }
		if (b) { CFRetain(b); return b; }
		return NULL;
	}
	std::vector<const void *> v(CFSetGetCount(a) + CFSetGetCount(b) + 1);
	CFSetGetValues(a, v.data());
	CFSetGetValues(b, v.data() + CFSetGetCount(a));
	return CFSetCreate(kCFAllocatorDefault, v.data(), CFSetGetCount(a) + CFSetGetCount(b), &kCFTypeSetCallBacks);
}

/* ---------------------------------------------------------------- strings */

LSS_EXPORT std::string CFStringConvertToString(CFStringRef string, CFStringEncoding encoding)
{
	std::string r;
	if (!string) return r;
	const char *p = CFStringGetCStringPtr(string, encoding);
	if (p) { r.assign(p); return r; }
	CFIndex used = 0, len = CFStringGetLength(string);
	if (CFStringGetBytes(string, CFRangeMake(0, len), encoding, 0, false, NULL, 0, &used) != len) return r;
	std::vector<char> buf(used);
	if (CFStringGetBytes(string, CFRangeMake(0, len), encoding, 0, false, (UInt8 *)buf.data(), buf.size(), &used) == len)
		r.assign(buf.data(), used);
	return r;
}

/* As Apple: compares the UTF-8 C string pointers directly (no fallback when CFStringGetCStringPtr fails). */
LSS_EXPORT long CFStringLongestCommonPrefix(CFStringRef a, CFStringRef b)
{
	if (!b || !a) return 0;
	const char *pa = CFStringGetCStringPtr(a, kCFStringEncodingUTF8);
	const char *pb = CFStringGetCStringPtr(b, kCFStringEncodingUTF8);
	long i = 0;
	for (; pa[i] != 0; i++) if (pa[i] != pb[i]) return i;
	return i;
}

LSS_EXPORT NSString *processName(int pid)
{
	char name[4096 + 8];
	bzero(name, 4096);
	if (proc_name(pid, name, 4096) == 0) return nil;
	return [NSString stringWithUTF8String:name];
}

/* ---------------------------------------------------------------- asString */

static const char kHexUpper[] = "0123456789ABCDEF";

static void putPadded(std::ostream &os, int width, char c)
{
	os << std::setfill('0');
	os.width(width);
	os << c;
}

/* A time: relative=false gives the Gregorian date in GMT as "YYYY/MM/DD HH:SS" (as Apple: the minute is not
 * printed and the seconds go through a char); relative=true names the first non-zero unit and the next one
 * (as Apple: month, day, hour and minute are written as raw bytes padded with '0'). */
LSS_EXPORT std::string asString(double t, bool relative)
{
	std::ostringstream os;
	CFGregorianDate g = CFAbsoluteTimeGetGregorianDate(t, NULL);
	if (!relative) {
		os << std::setfill('0'); os.width(4); os << (int)g.year << "/";
		os << std::setfill('0'); os.width(2); os << (int)g.month << "/";
		os << std::setfill('0'); os.width(2); os << (int)g.day;
		os << " ";
		os << std::setfill('0'); os.width(2); os << (int)g.hour << ":";
		os << std::setfill('0'); os.width(2); os << (int)(signed char)(int)g.second;
		return os.str();
	}
	int stage;
	if (g.year > 0) {
		os << std::setfill('0'); os.width(4); os << (int)g.year << "year" << (g.year != 1 ? "s" : "") << ", ";
		stage = 1;
	} else if (g.month > 0) stage = 1;
	else if (g.day > 0) stage = 2;
	else if (g.hour > 0) stage = 3;
	else if (g.minute > 0) stage = 4;
	else if (g.second > 0.0) stage = 5;
	else return os.str();
	bool first = g.year <= 0;          /* print this unit and one more */
	struct { SInt8 v; const char *name; } units[] = { { g.month, "month" }, { g.day, "day" }, { g.hour, "hour" }, { g.minute, "minute" } };
	for (; stage <= 4; stage++) {
		SInt8 v = units[stage - 1].v;
		putPadded(os, 2, (char)v);
		os << units[stage - 1].name << ((v == 0 || v > 1) ? "s" : "") << ", ";
		if (!first) return os.str();
		first = false;
	}
	os << std::setfill('0'); os.width(2); os << g.second << "second" << ((g.second == 0.0 || g.second > 1.0) ? "s" : "") << ", ";
	return os.str();
}

LSS_EXPORT std::string asString(const void *object)
{
	std::ostringstream os;
	if (!object) { os << "[ NULL ] "; return os.str(); }
	CFTypeID t = CFGetTypeID(object);
	if (t == CFStringGetTypeID()) {
		CFStringRef s = (CFStringRef)object;
		os << '"';
		CFIndex len = CFStringGetLength(s), used = 0;
		if (CFStringGetBytes(s, CFRangeMake(0, len), kCFStringEncodingUTF8, 0, false, NULL, 0, &used) == len) {
			std::vector<char> buf(used);
			if (CFStringGetBytes(s, CFRangeMake(0, len), kCFStringEncodingUTF8, 0, false, (UInt8 *)buf.data(), buf.size(), &used) == len) {
				for (char &c : buf) if (c == '\n') c = ' ';
				os.write(buf.data(), buf.size());
			} else os << "?";
		} else os << "?";
		os << '"';
	} else if (t == CFArrayGetTypeID()) {
		CFIndex n = CFArrayGetCount((CFArrayRef)object);
		os << "( ";
		for (CFIndex i = 0; i < n; i++) {
			if (i) os << ", ";
			os << asString(CFArrayGetValueAtIndex((CFArrayRef)object, i));
		}
		os << ")";
	} else if (t == CFDictionaryGetTypeID()) {
		CFDictionaryRef d = (CFDictionaryRef)object;
		CFIndex n = CFDictionaryGetCount(d);
		os << "{ ";
		if (n > 0) {
			std::vector<const void *> keys(n);
			CFDictionaryGetKeysAndValues(d, keys.data(), NULL);
			CFTypeID kt, st;
			CFIndex i = 1;
			bool more;
			do { kt = CFGetTypeID(keys[i - 1]); st = CFStringGetTypeID(); if (kt != st) break; more = i < n; i++; } while (more);
			if (kt == st)
				std::sort(keys.begin(), keys.end(), ^bool(const void *const &a, const void *const &b) {
					return CFStringCompare((CFStringRef)a, (CFStringRef)b, 0) < 0; });
			for (CFIndex j = 0; j < n; j++) {
				os << (j ? ", " : "");
				os << asString(keys[j]) << "=" << asString(CFDictionaryGetValue(d, keys[j]));
			}
		}
		os << " }";
	} else if (t == CFSetGetTypeID()) {
		CFSetRef s = (CFSetRef)object;
		CFIndex n = CFSetGetCount(s);
		os << "((";
		if (n > 0) {
			std::vector<const void *> v(n);
			CFSetGetValues(s, v.data());
			CFTypeID kt, st;
			CFIndex i = 1;
			bool more;
			do { kt = CFGetTypeID(v[i - 1]); st = CFStringGetTypeID(); if (kt != st) break; more = i < n; i++; } while (more);
			if (kt == st)
				std::sort(v.begin(), v.end(), ^bool(const void *const &a, const void *const &b) {
					return CFStringCompare((CFStringRef)a, (CFStringRef)b, 0) < 1; });
			for (CFIndex j = 0; j < n; j++) {
				if (j) os << ", ";
				os << asString(v[j]);
			}
		}
		os << "))";
	} else if (t == CFDataGetTypeID()) {
		CFIndex n = CFDataGetLength((CFDataRef)object);
		const UInt8 *p = CFDataGetBytePtr((CFDataRef)object);
		os << "$";
		for (CFIndex i = 0; i < n; i++) os << kHexUpper[p[i] >> 4] << kHexUpper[p[i] & 15];
	} else if (t == CFDateGetTypeID()) {
		CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
		double diff = CFDateGetAbsoluteTime((CFDateRef)object) - now;
		if (!(diff < -1.0 || diff > 0.0)) os << "now-ish ";
		else if (diff >= 0.0 && diff <= 1.0) os << "soon-ish ";
		else if (diff >= 0.0 && diff <= 300.0) os << (long)__builtin_trunc(diff + __builtin_copysign(0.49999999999999994, diff)) << " seconds from now, ";
		else if (diff >= -300.0 && diff <= 0.0) os << (long)__builtin_trunc(__builtin_fabs(diff) + 0.49999999999999994) << " seconds ago, ";
		CFTimeZoneRef tz = CFTimeZoneCopyDefault();
		CFGregorianDate g = CFAbsoluteTimeGetGregorianDate(CFDateGetAbsoluteTime((CFDateRef)object), tz);
		os.width(4);
		os << std::setfill('0') << (int)g.year << "/";
		os.width(2); os << std::setfill('0') << (int)g.month << "/";
		os.width(2); os << std::setfill('0') << (int)g.day << " ";
		os.width(2); os << std::setfill('0') << (int)g.hour << ":";
		os.width(2); os << std::setfill('0') << (int)g.minute << ":";
		os.width(2); os << std::setfill('0') << (int)g.second;
		if (tz) CFRelease(tz);
	} else if (t == CFNumberGetTypeID()) {
		CFNumberRef num = (CFNumberRef)object;
		CFNumberType nt = CFNumberGetType(num);
		switch (nt) {
		case kCFNumberSInt8Type: case kCFNumberSInt16Type: case kCFNumberSInt32Type: case kCFNumberCharType:
		case kCFNumberShortType: case kCFNumberIntType: case kCFNumberLongType: {
			int v;
			if (CFNumberGetValue(num, kCFNumberSInt32Type, &v)) os << (long)v;
			break;
		}
		case kCFNumberSInt64Type: case kCFNumberLongLongType: {
			long long v;
			if (CFNumberGetValue(num, kCFNumberSInt64Type, &v)) os << v;
			break;
		}
		case kCFNumberFloat32Type: case kCFNumberFloatType: {
			float v;
			if (CFNumberGetValue(num, kCFNumberFloatType, &v)) { os.setf(std::ios_base::showpoint); os << v; }
			else os << "NAN";
			break;
		}
		case kCFNumberFloat64Type: case kCFNumberDoubleType: {
			double v;
			if (CFNumberGetValue(num, kCFNumberDoubleType, &v)) { os.setf(std::ios_base::showpoint); os << v; }
			else os << "NAN";
			break;
		}
		case kCFNumberCFIndexType: {
			long v;
			if (CFNumberGetValue(num, kCFNumberCFIndexType, &v)) os << v;
			break;
		}
		default: {
			CFIndex size = CFNumberGetByteSize(num);
			unsigned char buf[16] = { 0 };
			CFNumberGetValue(num, nt, buf);
			os << "0x";
			bool printed = false;
			for (CFIndex i = size - 1; i >= 0; i--) {
				if (buf[i] == 0 && !printed) continue;
				os << kHexUpper[buf[i] >> 4] << kHexUpper[buf[i] & 15];
				printed = true;
			}
			if (!printed) os << "0";
		}
		}
	} else if (t == CFBooleanGetTypeID()) {
		os << (CFBooleanGetValue((CFBooleanRef)object) ? "true" : "false");
	} else if (t == CFURLGetTypeID()) {
		CFURLRef base = CFURLGetBaseURL((CFURLRef)object);
		os << asString(CFURLGetString((CFURLRef)object));
		if (base) os << " base:" << asString(base);
	} else if (t == CFErrorGetTypeID()) {
		CFErrorRef e = (CFErrorRef)object;
		CFStringRef domain = CFErrorGetDomain(e);
		int code = (int)CFErrorGetCode(e);
		CFDictionaryRef info = CFErrorCopyUserInfo(e);
		os << "ERROR:" << asString(domain) << " #" << code;
		if (info) { os << " " << asString(info); CFRelease(info); }
	} else if (t == CFNullGetTypeID()) {
		os << "kCFNULL";
	} else if (t == _LSASNGetTypeID()) {
		uint32_t high = 0, low = 0;
		if (!_LSASNExtractHighAndLowParts((LSASNRef)object, &high, &low)) os << "ASN:0x0-0x0-InvalidASN";
		else {
			os << "ASN:0x" << std::hex << high << std::dec << "-0x" << std::hex << low << std::dec << ":";
			if (high == 1) os << "(pid=" << low << ")";
		}
	} else if (t == SecIdentityGetTypeID()) {
		os << "[ ";
		SecCertificateRef cert = NULL;
		if (SecIdentityCopyCertificate((SecIdentityRef)object, &cert) == 0) os << asString(cert);
		SecKeyRef key = NULL;
		if (SecIdentityCopyPrivateKey((SecIdentityRef)object, &key) == 0) os << asString(key);
		os << "] ";
		if (key) CFRelease(key);
		if (cert) CFRelease(cert);
	} else if (t == SecCertificateGetTypeID()) {
		CFStringRef summary = SecCertificateCopySubjectSummary((SecCertificateRef)object);
		os << "CERT:";
		if (!summary) os << " ";
		else {
			os << asString(summary) << " ";
			os << " ";
			CFRelease(summary);
		}
	} else {
		CFTypeID kt = SecKeyGetTypeID();
		CFStringRef desc = CFCopyDescription(object);
		if (t == kt) os << "KEY:" << asString(desc);
		else os << asString(desc);
		if (desc) CFRelease(desc);
	}
	return os.str();
}
