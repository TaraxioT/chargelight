/*
 * chargelight_smc.h - C core of chargelight.
 *
 * Talks to the Apple System Management Controller (AppleSMC) through IOKit to
 * read and write the MagSafe 3 LED key `ACLC` on Apple Silicon Macs.
 *
 * Reading works as a normal user. Writing requires root: the kernel rejects
 * unprivileged SMC writes with kIOReturnNotPrivileged.
 *
 * The one-shot functions open and close their own SMC connection, so they hold
 * no global state and are safe to call from any thread. A cl_session keeps one
 * connection open for code that reads or writes repeatedly.
 *
 * A forced LED state is not always permanent: macOS can take the LED back
 * within seconds (seen on a fully charged MacBook Pro, macOS 27), and always
 * does when the charger is replugged. To keep a state, re-check it regularly
 * with a session and write it again when it has changed; `chargelight-helper
 * hold` does exactly that.
 */
#ifndef CHARGELIGHT_SMC_H
#define CHARGELIGHT_SMC_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Single source of truth for the version of the CLI, the library and the helper. */
#define CL_VERSION "0.1.0"

/* SMC key that drives the MagSafe LED (type ui8, one byte). */
#define CL_LED_KEY "ACLC"

typedef enum {
    CL_OK = 0,
    CL_ERR_NO_SERVICE = 1,     /* AppleSMC service not found (not a Mac with an SMC) */
    CL_ERR_OPEN = 2,           /* could not open a connection to AppleSMC */
    CL_ERR_KEY_NOT_FOUND = 3,  /* the SMC has no such key (no MagSafe LED on this Mac) */
    CL_ERR_NOT_PRIVILEGED = 4, /* write refused: caller is not root */
    CL_ERR_SIZE_MISMATCH = 5,  /* data length does not match the key's size */
    CL_ERR_SMC = 6,            /* any other IOKit or SMC failure */
    CL_ERR_INVALID = 7         /* invalid argument (bad key name, unknown LED value) */
} cl_status;

/* Raw values accepted by the LED key. Only these are ever written. */
typedef enum {
    CL_LED_SYSTEM = 0x00,     /* hand control back to macOS (charging state) */
    CL_LED_OFF = 0x01,        /* LED off */
    CL_LED_GREEN = 0x03,      /* solid green */
    CL_LED_AMBER = 0x04,      /* solid amber */
    CL_LED_BLINK_SLOW = 0x06, /* amber, slow blink */
    CL_LED_BLINK_FAST = 0x07  /* amber, fast blink */
} cl_led;

typedef struct {
    uint32_t type;       /* four-character type code, e.g. 'ui8 ' */
    uint32_t size;       /* number of valid bytes */
    uint8_t attributes;  /* SMC key attribute flags */
    uint8_t bytes[32];
} cl_smc_value;

/*
 * Detail about the most recent failure on the calling thread: the
 * kern_return_t for IOKit failures, or the SMC result byte for SMC failures.
 * Zero after a successful call.
 */
typedef struct {
    uint32_t code;
    int from_smc; /* 1: SMC result byte, 0: kern_return_t */
} cl_error_detail;

/* Read any SMC key. `key` must be exactly four characters. */
cl_status cl_smc_read(const char *key, cl_smc_value *out);

/* Write any SMC key (root only). `len` must equal the key's size, max 32. */
cl_status cl_smc_write(const char *key, const uint8_t *bytes, uint32_t len);

/* Read the raw LED byte. Right after a write the SMC may still report the
 * previous value for a moment. Under system control it reports the colour the
 * system is showing (green or amber), not 0x00. */
cl_status cl_led_read(uint8_t *raw);

/* Write the LED (root only). Returns CL_ERR_INVALID unless `raw` is a cl_led value. */
cl_status cl_led_write(uint8_t raw);

/*
 * A session keeps one AppleSMC connection open. Use it from one thread at a time.
 */
typedef struct cl_session cl_session;

/* Open a session. On success *session must be released with cl_session_close. */
cl_status cl_session_open(cl_session **session);
void cl_session_close(cl_session *session);

/* Same as cl_led_read / cl_led_write, on an open session. */
cl_status cl_session_led_read(cl_session *session, uint8_t *raw);
cl_status cl_session_led_write(cl_session *session, uint8_t raw);

/* 1 if a readback of `raw` means the LED is showing `wanted` (0x02 also counts
 * as green), else 0. */
int cl_led_matches(uint8_t raw, uint8_t wanted);

/* "system", "off", "green", "amber", "blink-slow", "blink-fast"; NULL if unknown.
 * A raw 0x02 is reported as "green" (seen on some firmware). */
const char *cl_led_name(uint8_t raw);

/* Inverse of cl_led_name. Returns the raw value, or -1 if the name is unknown. */
int cl_led_from_name(const char *name);

/* 1 if `raw` is one of the cl_led values, else 0. */
int cl_led_is_valid(uint8_t raw);

const char *cl_status_string(cl_status status);
cl_error_detail cl_last_error_detail(void);

/*
 * Start `path` with `argv` as a fully detached background process: new session,
 * stdin/stdout/stderr on /dev/null, no inherited descriptors, not a zombie
 * candidate for the caller. Returns the child's pid, or -1 with errno set.
 */
pid_t cl_spawn_detached(const char *path, char *const argv[], char *const envp[]);

#ifdef __cplusplus
}
#endif

#endif /* CHARGELIGHT_SMC_H */
