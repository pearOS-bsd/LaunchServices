/* Registration of applications in the Launch Services database (lsd/apps.m). */
#import <Foundation/Foundation.h>
#import "../store/lsdb.h"
uint32_t LSDVolumeContainer(ls_db *db);                                                      /* the Container record the bundles point at (once per database) */
uint32_t LSDRegisterApplication(ls_db *db, NSString *path, uint32_t container);              /* the Bundle unit id, 0 if the bundle cannot be read */
NSUInteger LSDRegisterApplicationsIn(ls_db *db, NSArray<NSString *> *dirs, uint32_t container); /* every .app directly in these directories */
