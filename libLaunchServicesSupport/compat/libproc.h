/* SPDX-License-Identifier: BSD-2-Clause */
/* The one libproc call libLaunchServicesSupport makes (libSystem's proc_name), for the FreeBSD build. */
#ifndef LSS_LIBPROC_H
#define LSS_LIBPROC_H
#include <stdint.h>
#ifdef __cplusplus
extern "C"
#endif
int proc_name(int pid, void *buffer, uint32_t buffersize);
#endif
