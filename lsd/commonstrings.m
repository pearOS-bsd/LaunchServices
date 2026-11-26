/* The common strings of Launch Services' property list compaction (research/docs/LAUNCHSERVICES-WIRE.md 5.10): the list that _LSPlistGetCommonStrings builds,
 * read at run time from the LaunchServices image loaded in this process (the list is data of Apple's binary: it is never stored in our repositories).
 * How: the function is a straight sequence of `lea rdx, [rip + cfstring]; call addObject:`.  Its first string is "UISupportedInterfaceOrientations": we find that
 * CFString constant in the image's __cfstring section, the lea in __text that loads it, walk back to the start of the function (push rbp) and collect, in order,
 * every CFString constant the function loads until its `pop rbp; ret`.  x86_64 only (pearOS).  Our own code (BSD-2-Clause). */
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/loader.h>
#import <string.h>

static const struct section_64 *Section(const struct mach_header_64 *mh, const char *seg, const char *sect, intptr_t *slide)
{
	const uint8_t *p = (const uint8_t *)(mh + 1);
	const struct section_64 *found = NULL;
	intptr_t sl = 0; int have_slide = 0;
	for (uint32_t i = 0; i < mh->ncmds; i++) {
		const struct load_command *lc = (const struct load_command *)p;
		if (lc->cmd == LC_SEGMENT_64) {
			const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
			if (!have_slide && !strcmp(sc->segname, "__TEXT")) { sl = (intptr_t)mh - (intptr_t)sc->vmaddr; have_slide = 1; }
			const struct section_64 *s = (const struct section_64 *)(sc + 1);
			for (uint32_t k = 0; k < sc->nsects; k++) if (!strncmp(s[k].segname, seg, 16) && !strncmp(s[k].sectname, sect, 16)) found = &s[k];
		}
		p += lc->cmdsize;
	}
	*slide = sl;
	return found;
}

NSArray<NSString *> *LSDCommonStrings(void)
{
	static NSArray *list;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		Dl_info di;
		void *sym = dlsym(RTLD_DEFAULT, "_LSPlistGet");
		if (!sym || !dladdr(sym, &di)) return;
		const struct mach_header_64 *mh = di.dli_fbase;
		intptr_t slide;
		const struct section_64 *text = Section(mh, "__TEXT", "__text", &slide);
		const struct section_64 *cf = Section(mh, "__DATA_CONST", "__cfstring", &slide);
		if (!cf) cf = Section(mh, "__DATA", "__cfstring", &slide);
		if (!text || !cf) return;
		const uint8_t *t = (const uint8_t *)(text->addr + slide), *cfb = (const uint8_t *)(cf->addr + slide);
		uint64_t tn = text->size, cfn = cf->size;
		const uint8_t *first = NULL;
		for (uint64_t off = 0; off + 32 <= cfn; off += 32) {             /* CFString constants: isa, flags, char *, length */
			CFStringRef s = (CFStringRef)(cfb + off);
			if (CFStringGetLength(s) == 32 && CFEqual(s, CFSTR("UISupportedInterfaceOrientations"))) { first = cfb + off; break; }
		}
		if (!first) return;
		uint64_t pos = UINT64_MAX;
		for (uint64_t i = 0; i + 7 <= tn; i++) {
			if (t[i] != 0x48 || t[i + 1] != 0x8d || t[i + 2] != 0x15) continue;
			int32_t d; memcpy(&d, t + i + 3, 4);
			if (t + i + 7 + d == first) { pos = i; break; }
		}
		if (pos == UINT64_MAX) return;
		while (pos > 0 && t[pos - 1] != 0x55) pos--;                     /* the function's prologue */
		NSMutableArray *out = [NSMutableArray array];
		for (uint64_t i = pos; i + 7 <= tn && out.count < 4096; ) {
			if (t[i] == 0x48 && t[i + 1] == 0x8d && t[i + 2] == 0x15) {
				int32_t d; memcpy(&d, t + i + 3, 4);
				const uint8_t *a = t + i + 7 + d;
				if (a >= cfb && a < cfb + cfn) [out addObject: (__bridge NSString *)(CFStringRef)a];
				i += 7; continue;
			}
			if (t[i] == 0x5d && t[i + 1] == 0xc3 && out.count > 100) break; /* pop rbp; ret */
			i++;
		}
		list = out;
	});
	return list;
}
