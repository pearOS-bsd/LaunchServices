/* The declarations of libxpc and the private calls that launchservicesd uses, for the FreeBSD build (build-bsd.sh): the open
 * header tree has no <xpc/xpc.h> .  Prototypes and values are the ones of the macOS SDK (the symbols bind at run
 * time to the Mac's libSystem).  On a Mac the SDK headers are used instead.  Our own file (BSD-2-Clause). */
#ifndef LSVD_XPC_H
#define LSVD_XPC_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <unistd.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <bsm/audit.h>

typedef void *xpc_object_t;
typedef xpc_object_t xpc_connection_t;
typedef xpc_object_t xpc_endpoint_t;
typedef const struct _xpc_type_s *xpc_type_t;
typedef void (^xpc_handler_t)(xpc_object_t object);
typedef bool (^xpc_dictionary_applier_t)(const char *key, xpc_object_t value);
typedef bool (^xpc_array_applier_t)(size_t index, xpc_object_t value);

extern const struct _xpc_type_s _xpc_type_connection, _xpc_type_dictionary, _xpc_type_array, _xpc_type_string, _xpc_type_uint64,
	_xpc_type_int64, _xpc_type_bool, _xpc_type_endpoint, _xpc_type_error, _xpc_type_double;
#define XPC_TYPE_CONNECTION (&_xpc_type_connection)
#define XPC_TYPE_DICTIONARY (&_xpc_type_dictionary)
#define XPC_TYPE_ARRAY (&_xpc_type_array)
#define XPC_TYPE_STRING (&_xpc_type_string)
#define XPC_TYPE_UINT64 (&_xpc_type_uint64)
#define XPC_TYPE_INT64 (&_xpc_type_int64)
#define XPC_TYPE_BOOL (&_xpc_type_bool)
#define XPC_TYPE_ENDPOINT (&_xpc_type_endpoint)
#define XPC_TYPE_ERROR (&_xpc_type_error)
#define XPC_TYPE_DOUBLE (&_xpc_type_double)
extern const struct _xpc_dictionary_s _xpc_error_connection_invalid, _xpc_error_connection_interrupted;
#define XPC_ERROR_CONNECTION_INVALID ((xpc_object_t)&_xpc_error_connection_invalid)
#define XPC_ERROR_CONNECTION_INTERRUPTED ((xpc_object_t)&_xpc_error_connection_interrupted)
#define XPC_CONNECTION_MACH_SERVICE_LISTENER (1 << 0)

xpc_type_t xpc_get_type(xpc_object_t object);
xpc_object_t xpc_retain(xpc_object_t object);
void xpc_release(xpc_object_t object);
xpc_object_t xpc_copy(xpc_object_t object);
bool xpc_equal(xpc_object_t a, xpc_object_t b);
char *xpc_copy_description(xpc_object_t object);

xpc_connection_t xpc_connection_create_mach_service(const char *name, dispatch_queue_t targetq, uint64_t flags);
xpc_connection_t xpc_connection_create_from_endpoint(xpc_endpoint_t endpoint);
void xpc_connection_set_event_handler(xpc_connection_t connection, xpc_handler_t handler);
void xpc_connection_set_target_queue(xpc_connection_t connection, dispatch_queue_t targetq);
void xpc_connection_resume(xpc_connection_t connection);
void xpc_connection_cancel(xpc_connection_t connection);
void xpc_connection_send_message(xpc_connection_t connection, xpc_object_t message);
pid_t xpc_connection_get_pid(xpc_connection_t connection);
uid_t xpc_connection_get_euid(xpc_connection_t connection);
au_asid_t xpc_connection_get_asid(xpc_connection_t connection);
void xpc_connection_get_audit_token(xpc_connection_t connection, audit_token_t *token);	/* private, exported by libxpc */
xpc_connection_t xpc_dictionary_get_remote_connection(xpc_object_t xdict);

xpc_object_t xpc_dictionary_create(const char *const *keys, const xpc_object_t *values, size_t count);
xpc_object_t xpc_dictionary_create_reply(xpc_object_t original);
void xpc_dictionary_set_value(xpc_object_t xdict, const char *key, xpc_object_t value);
xpc_object_t xpc_dictionary_get_value(xpc_object_t xdict, const char *key);
size_t xpc_dictionary_get_count(xpc_object_t xdict);
bool xpc_dictionary_apply(xpc_object_t xdict, xpc_dictionary_applier_t applier);
void xpc_dictionary_set_bool(xpc_object_t xdict, const char *key, bool value);
void xpc_dictionary_set_int64(xpc_object_t xdict, const char *key, int64_t value);
void xpc_dictionary_set_uint64(xpc_object_t xdict, const char *key, uint64_t value);
void xpc_dictionary_set_double(xpc_object_t xdict, const char *key, double value);
void xpc_dictionary_set_string(xpc_object_t xdict, const char *key, const char *string);
void xpc_dictionary_set_data(xpc_object_t xdict, const char *key, const void *bytes, size_t length);
bool xpc_dictionary_get_bool(xpc_object_t xdict, const char *key);
int64_t xpc_dictionary_get_int64(xpc_object_t xdict, const char *key);
uint64_t xpc_dictionary_get_uint64(xpc_object_t xdict, const char *key);
const char *xpc_dictionary_get_string(xpc_object_t xdict, const char *key);
mach_port_t xpc_dictionary_copy_mach_send(xpc_object_t xdict, const char *key);	/* private, exported by libxpc */

xpc_object_t xpc_array_create(const xpc_object_t *objects, size_t count);
void xpc_array_append_value(xpc_object_t xarray, xpc_object_t value);
size_t xpc_array_get_count(xpc_object_t xarray);
xpc_object_t xpc_array_get_value(xpc_object_t xarray, size_t index);
uint64_t xpc_array_get_uint64(xpc_object_t xarray, size_t index);
int64_t xpc_array_get_int64(xpc_object_t xarray, size_t index);
const char *xpc_array_get_string(xpc_object_t xarray, size_t index);

xpc_object_t xpc_bool_create(bool value);
xpc_object_t xpc_int64_create(int64_t value);
int64_t xpc_int64_get_value(xpc_object_t xint);
xpc_object_t xpc_uint64_create(uint64_t value);
uint64_t xpc_uint64_get_value(xpc_object_t xuint);
xpc_object_t xpc_string_create(const char *string);
const char *xpc_string_get_string_ptr(xpc_object_t xstring);
xpc_object_t xpc_data_create(const void *bytes, size_t length);
xpc_object_t xpc_uuid_create(const unsigned char *uuid);
xpc_object_t xpc_date_create_from_current(void);
xpc_object_t xpc_shmem_create(void *region, size_t length);
xpc_object_t xpc_null_create(void);

/* mach (mach_init.h / the MIG mach_port.h are not in the open tree) */
#ifndef mach_task_self
extern mach_port_t mach_task_self_;
#define mach_task_self() mach_task_self_
#endif
kern_return_t mach_port_deallocate(ipc_space_t task, mach_port_name_t name);
#endif
