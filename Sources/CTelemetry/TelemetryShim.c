#include "TelemetryShim.h"

#include <errno.h>
#include <mach/mach.h>
#include <stddef.h>
#include <sys/resource.h>
#include <AvailabilityMacros.h>

int vb_process_cpu_ns(int64_t *user_ns, int64_t *system_ns) {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        return errno;
    }
    *user_ns = (int64_t)usage.ru_utime.tv_sec * 1000000000LL + (int64_t)usage.ru_utime.tv_usec * 1000LL;
    *system_ns = (int64_t)usage.ru_stime.tv_sec * 1000000000LL + (int64_t)usage.ru_stime.tv_usec * 1000LL;
    return 0;
}

int vb_process_memory(int64_t *resident_bytes, int64_t *footprint_bytes, int *has_footprint) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (result != KERN_SUCCESS) {
        return (int)result;
    }
    *resident_bytes = (int64_t)info.resident_size;
    // phys_footprint is present only if the returned count covers it (older kernels return less).
    size_t needed = (offsetof(task_vm_info_data_t, phys_footprint) + sizeof(info.phys_footprint)) / sizeof(natural_t);
    if (count >= needed) {
        *footprint_bytes = (int64_t)info.phys_footprint;
        *has_footprint = 1;
    } else {
        *footprint_bytes = 0;
        *has_footprint = 0;
    }
    return 0;
}

int64_t vb_sdk_version_max_allowed(void) {
#ifdef __MAC_OS_X_VERSION_MAX_ALLOWED
    return (int64_t)__MAC_OS_X_VERSION_MAX_ALLOWED;
#else
    return 0;
#endif
}

int64_t vb_deployment_target(void) {
#ifdef __MAC_OS_X_VERSION_MIN_REQUIRED
    return (int64_t)__MAC_OS_X_VERSION_MIN_REQUIRED;
#else
    return 0;
#endif
}
