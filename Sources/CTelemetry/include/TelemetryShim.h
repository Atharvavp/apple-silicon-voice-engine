#ifndef VOICEBENCH_TELEMETRY_SHIM_H
#define VOICEBENCH_TELEMETRY_SHIM_H

#include <stdint.h>

/// Cumulative CPU time of the calling process (getrusage(RUSAGE_SELF)).
/// Returns 0 on success, otherwise the errno value.
int vb_process_cpu_ns(int64_t *user_ns, int64_t *system_ns);

/// Current memory of the calling process via task_info(TASK_VM_INFO).
/// `resident_bytes` is always set on success (return 0). `footprint_bytes` is
/// set and `has_footprint` is 1 only when the kernel returned a structure large
/// enough to contain phys_footprint. Otherwise returns the kern_return_t.
int vb_process_memory(int64_t *resident_bytes, int64_t *footprint_bytes, int *has_footprint);

/// SDK the binary was compiled against (__MAC_OS_X_VERSION_MAX_ALLOWED, e.g. 260500), or 0.
int64_t vb_sdk_version_max_allowed(void);

/// Deployment target the binary was compiled for (__MAC_OS_X_VERSION_MIN_REQUIRED), or 0.
int64_t vb_deployment_target(void);

#endif
