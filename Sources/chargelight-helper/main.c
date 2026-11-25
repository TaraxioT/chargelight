/*
 * chargelight-helper - the only part of chargelight that runs as root.
 *
 * `sudo chargelight setup` copies this binary to
 * /Library/PrivilegedHelperTools/chargelight-helper (root:wheel, 0755) and adds
 * a sudoers rule that lets it run without a password. The CLI and the library
 * then change the LED with `sudo -n chargelight-helper ...`.
 *
 * It is deliberately tiny. It writes one whitelisted byte to one SMC key
 * (ACLC, the MagSafe LED) and does nothing else: it opens no files, reads no
 * environment variables, and the only input it accepts is one of six fixed
 * state names (plus "quit" in hold mode).
 *
 * Usage:
 *   chargelight-helper set <state>   write the LED once
 *   chargelight-helper hold          keep the LED in the state named on stdin
 *   chargelight-helper --version
 *
 *   <state>: system | off | green | amber | blink-slow | blink-fast
 *
 * hold mode
 *   macOS can take the LED back within seconds of a write, and always does
 *   when the charger is replugged, so a state has to be held, not just set.
 *   `hold` reads state names from standard input, one per line, writes each as
 *   it arrives, and then checks the LED about thirty times a second, writing
 *   the state again whenever the LED has drifted. "quit" exits and leaves the LED as it
 *   is. End of input (the controlling process went away) or SIGTERM/SIGINT
 *   hands the LED back to macOS before exiting, so it can never be left stuck.
 *
 * Exit codes: 0 ok, 2 usage, 3 no MagSafe LED on this Mac, 5 not root,
 *             6 SMC error.
 */
#include "chargelight_smc.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

enum { EXIT_OK = 0, EXIT_USAGE = 2, EXIT_UNSUPPORTED = 3, EXIT_NOT_ROOT = 5, EXIT_SMC = 6 };

/* How often hold mode checks that the LED still shows the held state. */
#define HOLD_INTERVAL_MS 30

static volatile sig_atomic_t g_stop;

static void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

static int usage(void) {
    fputs("usage: chargelight-helper set <system|off|green|amber|blink-slow|blink-fast>\n"
          "       chargelight-helper hold    (state names on stdin, one per line; \"quit\" to stop)\n"
          "       chargelight-helper --version\n",
          stderr);
    return EXIT_USAGE;
}

static int exit_code_for(cl_status st) {
    switch (st) {
    case CL_OK: return EXIT_OK;
    case CL_ERR_NO_SERVICE:
    case CL_ERR_KEY_NOT_FOUND: return EXIT_UNSUPPORTED;
    case CL_ERR_NOT_PRIVILEGED: return EXIT_NOT_ROOT;
    default: return EXIT_SMC;
    }
}

static int fail(cl_status st) {
    cl_error_detail detail = cl_last_error_detail();
    fprintf(stderr, "chargelight-helper: %s (%s 0x%x)\n", cl_status_string(st),
            detail.from_smc ? "SMC result" : "IOKit", detail.code);
    return exit_code_for(st);
}

static int set_once(const char *name) {
    int raw = cl_led_from_name(name);
    if (raw < 0) {
        fputs("chargelight-helper: unknown LED state\n", stderr);
        return usage();
    }
    cl_status st = cl_led_write((uint8_t)raw);
    return st == CL_OK ? EXIT_OK : fail(st);
}

static int hold(void) {
    cl_session *session = NULL;
    cl_status st = cl_session_open(&session);
    if (st != CL_OK) return fail(st);

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = on_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGHUP, &action, NULL);

    int held = -1;        /* raw state being held; -1 until the first command */
    int restore = 1;      /* hand the LED back to macOS on exit */
    char line[32];
    size_t length = 0;
    int overflow = 0;     /* discarding an over-long line */

    while (!g_stop) {
        struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN};
        int ready = poll(&input, 1, HOLD_INTERVAL_MS);
        if (ready < 0 && errno != EINTR) break;

        if (ready > 0) {
            char buffer[256];
            ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
            if (count == 0) break; /* end of input: the controller is gone */
            if (count < 0) {
                if (errno == EINTR || errno == EAGAIN) continue;
                break;
            }
            for (ssize_t i = 0; i < count; i++) {
                char ch = buffer[i];
                if (ch != '\n') {
                    if (length < sizeof(line) - 1)
                        line[length++] = ch;
                    else
                        overflow = 1;
                    continue;
                }
                line[length] = '\0';
                if (!overflow) {
                    if (strcmp(line, "quit") == 0) {
                        restore = 0;
                        g_stop = 1;
                        break;
                    }
                    int raw = cl_led_from_name(line);
                    if (raw >= 0) {
                        held = raw;
                        cl_session_led_write(session, (uint8_t)held);
                    }
                }
                length = 0;
                overflow = 0;
            }
            continue;
        }

        /* Timer tick: put the state back if the LED no longer shows it.
         * System control has nothing to hold. */
        if (held > CL_LED_SYSTEM) {
            uint8_t raw = 0;
            if (cl_session_led_read(session, &raw) == CL_OK && !cl_led_matches(raw, (uint8_t)held))
                cl_session_led_write(session, (uint8_t)held);
        }
    }

    if (restore && held > CL_LED_SYSTEM) cl_session_led_write(session, CL_LED_SYSTEM);
    cl_session_close(session);
    return EXIT_OK;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        puts(CL_VERSION);
        return EXIT_OK;
    }

    int is_set = argc == 3 && strcmp(argv[1], "set") == 0;
    int is_hold = argc == 2 && strcmp(argv[1], "hold") == 0;
    if (!is_set && !is_hold) return usage();
    if (is_set && cl_led_from_name(argv[2]) < 0) {
        fputs("chargelight-helper: unknown LED state\n", stderr);
        return usage();
    }
    if (geteuid() != 0) {
        fputs("chargelight-helper: must run as root\n", stderr);
        return EXIT_NOT_ROOT;
    }
    return is_set ? set_once(argv[2]) : hold();
}
