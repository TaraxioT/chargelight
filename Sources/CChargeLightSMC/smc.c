/*
 * smc.c - AppleSMC access for chargelight. See include/chargelight_smc.h.
 */
#include "chargelight_smc.h"

#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define KERNEL_INDEX_SMC 2 /* kSMCHandleYPCEvent */
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

#define SMC_RESULT_OK 0x00
#define SMC_RESULT_KEY_NOT_FOUND 0x84
#define SMC_RESULT_NOT_WRITABLE 0x86
#define SMC_RESULT_SIZE_MISMATCH 0x87

typedef struct {
    char major, minor, build, reserved[1];
    uint16_t release;
} SMCKeyData_vers_t;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
    uint32_t key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    unsigned char bytes[32];
} SMCKeyData_t;

_Static_assert(sizeof(SMCKeyData_t) == 80, "SMCKeyData_t must be 80 bytes");

static _Thread_local cl_error_detail g_detail;

static void set_detail(uint32_t code, int from_smc) {
    g_detail.code = code;
    g_detail.from_smc = from_smc;
}

cl_error_detail cl_last_error_detail(void) { return g_detail; }

static int key_is_valid(const char *key) { return key && strlen(key) == 4; }

static uint32_t key_code(const char *key) {
    uint32_t k = 0;
    for (int i = 0; i < 4; i++) k = (k << 8) | (unsigned char)key[i];
    return k;
}

static cl_status smc_open(io_connect_t *conn) {
    io_service_t service =
        IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) {
        set_detail(0, 0);
        return CL_ERR_NO_SERVICE;
    }
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, conn);
    IOObjectRelease(service);
    if (kr != kIOReturnSuccess) {
        set_detail((uint32_t)kr, 0);
        return kr == kIOReturnNotPrivileged ? CL_ERR_NOT_PRIVILEGED : CL_ERR_OPEN;
    }
    return CL_OK;
}

static cl_status smc_call(io_connect_t conn, SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t out_size = sizeof(*out);
    memset(out, 0, sizeof(*out));
    kern_return_t kr =
        IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(*in), out, &out_size);
    if (kr != kIOReturnSuccess) {
        set_detail((uint32_t)kr, 0);
        if (kr == kIOReturnNotPrivileged || kr == kIOReturnNotPermitted)
            return CL_ERR_NOT_PRIVILEGED;
        return CL_ERR_SMC;
    }
    unsigned result = (unsigned char)out->result;
    if (result != SMC_RESULT_OK) {
        set_detail(result, 1);
        switch (result) {
        case SMC_RESULT_KEY_NOT_FOUND: return CL_ERR_KEY_NOT_FOUND;
        case SMC_RESULT_NOT_WRITABLE: return CL_ERR_NOT_PRIVILEGED;
        case SMC_RESULT_SIZE_MISMATCH: return CL_ERR_SIZE_MISMATCH;
        default: return CL_ERR_SMC;
        }
    }
    return CL_OK;
}

static cl_status smc_key_info(io_connect_t conn, const char *key, SMCKeyData_keyInfo_t *info) {
    SMCKeyData_t in = {0}, out;
    in.key = key_code(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    cl_status st = smc_call(conn, &in, &out);
    if (st == CL_OK) *info = out.keyInfo;
    return st;
}

static cl_status smc_read_on(io_connect_t conn, const char *key, cl_smc_value *value) {
    SMCKeyData_keyInfo_t info;
    cl_status st = smc_key_info(conn, key, &info);
    if (st != CL_OK) return st;

    SMCKeyData_t in = {0}, out;
    in.key = key_code(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    st = smc_call(conn, &in, &out);
    if (st != CL_OK) return st;

    value->type = info.dataType;
    value->size = info.dataSize > 32 ? 32 : info.dataSize;
    value->attributes = (uint8_t)info.dataAttributes;
    memcpy(value->bytes, out.bytes, sizeof(value->bytes));
    return CL_OK;
}

static cl_status smc_write_on(io_connect_t conn, const char *key, const uint8_t *bytes,
                              uint32_t len) {
    SMCKeyData_keyInfo_t info;
    cl_status st = smc_key_info(conn, key, &info);
    if (st != CL_OK) return st;
    if (info.dataSize != len) return CL_ERR_SIZE_MISMATCH;

    SMCKeyData_t in = {0}, out;
    in.key = key_code(key);
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = len;
    memcpy(in.bytes, bytes, len);
    return smc_call(conn, &in, &out);
}

cl_status cl_smc_read(const char *key, cl_smc_value *value) {
    set_detail(0, 0);
    if (!key_is_valid(key) || !value) return CL_ERR_INVALID;
    memset(value, 0, sizeof(*value));

    io_connect_t conn;
    cl_status st = smc_open(&conn);
    if (st != CL_OK) return st;
    st = smc_read_on(conn, key, value);
    IOServiceClose(conn);
    return st;
}

cl_status cl_smc_write(const char *key, const uint8_t *bytes, uint32_t len) {
    set_detail(0, 0);
    if (!key_is_valid(key) || !bytes || len == 0 || len > 32) return CL_ERR_INVALID;

    io_connect_t conn;
    cl_status st = smc_open(&conn);
    if (st != CL_OK) return st;
    st = smc_write_on(conn, key, bytes, len);
    IOServiceClose(conn);
    return st;
}

struct cl_session {
    io_connect_t conn;
};

cl_status cl_session_open(cl_session **session) {
    set_detail(0, 0);
    if (!session) return CL_ERR_INVALID;
    *session = NULL;

    io_connect_t conn;
    cl_status st = smc_open(&conn);
    if (st != CL_OK) return st;

    cl_session *s = malloc(sizeof(*s));
    if (!s) {
        IOServiceClose(conn);
        return CL_ERR_SMC;
    }
    s->conn = conn;
    *session = s;
    return CL_OK;
}

void cl_session_close(cl_session *session) {
    if (!session) return;
    IOServiceClose(session->conn);
    free(session);
}

cl_status cl_session_led_read(cl_session *session, uint8_t *raw) {
    set_detail(0, 0);
    if (!session || !raw) return CL_ERR_INVALID;
    cl_smc_value value = {0};
    cl_status st = smc_read_on(session->conn, CL_LED_KEY, &value);
    if (st != CL_OK) return st;
    if (value.size < 1) return CL_ERR_SMC;
    *raw = value.bytes[0];
    return CL_OK;
}

cl_status cl_session_led_write(cl_session *session, uint8_t raw) {
    set_detail(0, 0);
    if (!session || !cl_led_is_valid(raw)) return CL_ERR_INVALID;
    return smc_write_on(session->conn, CL_LED_KEY, &raw, 1);
}

static const struct {
    const char *name;
    uint8_t raw;
} LED_STATES[] = {
    {"system", CL_LED_SYSTEM},         {"off", CL_LED_OFF},
    {"green", CL_LED_GREEN},           {"amber", CL_LED_AMBER},
    {"blink-slow", CL_LED_BLINK_SLOW}, {"blink-fast", CL_LED_BLINK_FAST},
};
#define LED_STATE_COUNT (sizeof(LED_STATES) / sizeof(LED_STATES[0]))

int cl_led_is_valid(uint8_t raw) {
    for (size_t i = 0; i < LED_STATE_COUNT; i++)
        if (LED_STATES[i].raw == raw) return 1;
    return 0;
}

int cl_led_matches(uint8_t raw, uint8_t wanted) {
    return raw == wanted || (wanted == CL_LED_GREEN && raw == 0x02);
}

const char *cl_led_name(uint8_t raw) {
    for (size_t i = 0; i < LED_STATE_COUNT; i++)
        if (LED_STATES[i].raw == raw) return LED_STATES[i].name;
    if (raw == 0x02) return "green";
    return NULL;
}

int cl_led_from_name(const char *name) {
    if (!name) return -1;
    for (size_t i = 0; i < LED_STATE_COUNT; i++)
        if (strcmp(LED_STATES[i].name, name) == 0) return LED_STATES[i].raw;
    return -1;
}

cl_status cl_led_read(uint8_t *raw) {
    if (!raw) return CL_ERR_INVALID;
    cl_smc_value value;
    cl_status st = cl_smc_read(CL_LED_KEY, &value);
    if (st != CL_OK) return st;
    if (value.size < 1) {
        set_detail(0, 0);
        return CL_ERR_SMC;
    }
    *raw = value.bytes[0];
    return CL_OK;
}

cl_status cl_led_write(uint8_t raw) {
    if (!cl_led_is_valid(raw)) {
        set_detail(0, 0);
        return CL_ERR_INVALID;
    }
    return cl_smc_write(CL_LED_KEY, &raw, 1);
}

const char *cl_status_string(cl_status status) {
    switch (status) {
    case CL_OK: return "ok";
    case CL_ERR_NO_SERVICE: return "AppleSMC service not found";
    case CL_ERR_OPEN: return "could not open AppleSMC";
    case CL_ERR_KEY_NOT_FOUND: return "SMC key not found";
    case CL_ERR_NOT_PRIVILEGED: return "not privileged (writing the SMC requires root)";
    case CL_ERR_SIZE_MISMATCH: return "SMC key size mismatch";
    case CL_ERR_SMC: return "SMC error";
    case CL_ERR_INVALID: return "invalid argument";
    }
    return "unknown error";
}

pid_t cl_spawn_detached(const char *path, char *const argv[], char *const envp[]) {
    if (!path || !argv) {
        errno = EINVAL;
        return -1;
    }

    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    int rc = posix_spawnattr_init(&attr);
    if (rc != 0) {
        errno = rc;
        return -1;
    }
    rc = posix_spawn_file_actions_init(&actions);
    if (rc != 0) {
        posix_spawnattr_destroy(&attr);
        errno = rc;
        return -1;
    }

    /* New session so the child outlives the caller's process group; reset
     * signal handling; close every descriptor except the three we reopen. */
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    posix_spawnattr_setsigmask(&attr, &none);
    posix_spawnattr_setsigdefault(&attr, &all);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK |
                                        POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    pid_t pid = -1;
    extern char **environ;
    rc = posix_spawn(&pid, path, &actions, &attr, argv, envp ? envp : environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) {
        errno = rc;
        return -1;
    }
    return pid;
}
