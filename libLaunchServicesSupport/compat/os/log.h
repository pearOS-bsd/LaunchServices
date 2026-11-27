/* SPDX-License-Identifier: BSD-2-Clause */
/* os_log for the FreeBSD build of libLaunchServicesSupport (the header tree there has none).  Unlike the SDK
 * repository's stderr shim this emits real unified-logging calls, the way Apple's compiler does for its macros:
 * the format goes to __TEXT,__oslogstring, the arguments are packed by __builtin_os_log_format, and the call is
 * _os_log_impl(&__dso_handle, log, type, format, buffer, size) guarded by os_log_type_enabled().  Written from
 * the calls in Apple's binary (research/docs/LAUNCHSERVICESSUPPORT.md), no Apple header used. */
#ifndef LSS_OS_LOG_H
#define LSS_OS_LOG_H
#include <stdint.h>
#include <stdbool.h>
#include <os/object.h>

#ifdef __OBJC__
OS_OBJECT_DECL(os_log);
#else
typedef struct os_log_s *os_log_t;
#endif
typedef uint8_t os_log_type_t;
#define OS_LOG_TYPE_DEFAULT ((os_log_type_t)0x00)
#define OS_LOG_TYPE_INFO ((os_log_type_t)0x01)
#define OS_LOG_TYPE_DEBUG ((os_log_type_t)0x02)
#define OS_LOG_TYPE_ERROR ((os_log_type_t)0x10)
#define OS_LOG_TYPE_FAULT ((os_log_type_t)0x11)

#ifdef __cplusplus
extern "C" {
#endif
extern struct mach_header __dso_handle;
os_log_t os_log_create(const char *subsystem, const char *category) OS_OBJECT_RETURNS_RETAINED;
bool os_log_type_enabled(os_log_t log, os_log_type_t type);
void _os_log_impl(void *dso, os_log_t log, os_log_type_t type, const char *format, uint8_t *buf, uint32_t size);
#ifdef __cplusplus
}
#endif

#define os_log_with_type(log, type, format, ...) __extension__({ \
	os_log_t _lss_log = (log); os_log_type_t _lss_type = (type); \
	if (os_log_type_enabled(_lss_log, _lss_type)) { \
		__attribute__((section("__TEXT,__oslogstring,cstring_literals"))) static const char _lss_fmt[] = format; \
		uint8_t _lss_buf[__builtin_os_log_format_buffer_size(format, ##__VA_ARGS__)] __attribute__((uninitialized, aligned(16))); \
		_os_log_impl((void *)&__dso_handle, _lss_log, _lss_type, _lss_fmt, \
			(uint8_t *)__builtin_os_log_format(_lss_buf, format, ##__VA_ARGS__), (uint32_t)sizeof(_lss_buf)); \
	} })
#define os_log(log, format, ...) os_log_with_type(log, OS_LOG_TYPE_DEFAULT, format, ##__VA_ARGS__)
#define os_log_info(log, format, ...) os_log_with_type(log, OS_LOG_TYPE_INFO, format, ##__VA_ARGS__)
#define os_log_debug(log, format, ...) os_log_with_type(log, OS_LOG_TYPE_DEBUG, format, ##__VA_ARGS__)
#define os_log_error(log, format, ...) os_log_with_type(log, OS_LOG_TYPE_ERROR, format, ##__VA_ARGS__)
#define os_log_fault(log, format, ...) os_log_with_type(log, OS_LOG_TYPE_FAULT, format, ##__VA_ARGS__)
#endif
