/*
 * svctag - read/write the Dell service tag in motherboard NVRAM.
 *
 * The service tag lives in SMM-protected NVRAM on the mainboard and is
 * written through a Dell SMI call. That call is implemented in Dell's
 * libsmbios_c (>= 2.2.x). Newer upstream libsmbios builds dropped the
 * setter, so this tool deliberately dlopen()s whatever libsmbios_c.so.2
 * you point it at (normally the el6 2.2.27 build fetched by build.sh).
 *
 * Loading via dlopen() means: no headers, no Python 2, no chroot, and it
 * runs natively on a modern distro. Only the tag-related symbols are used.
 *
 * Usage:
 *   svctag get   [--lib PATH]   print current service tag
 *   svctag set   <TAG> [--lib PATH]
 *   svctag check [--lib PATH]   report capability + current tag
 *
 * Exit codes:
 *   0 success
 *   1 usage / capability error
 *   2 library load failure
 *   3 tag write rejected by firmware
 *
 * MUST run as root on the physical machine. The SMI write goes through
 * Dell's in-kernel dcdbas driver (/sys/devices/platform/dcdbas); /dev/mem
 * is only used read-only to locate the SMBIOS/token structures.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <dlfcn.h>
#include <unistd.h>
#include <ctype.h>
#include <sys/stat.h>
#include <sys/types.h>

#define DEFAULT_LIB "vendor/usr/lib64/libsmbios_c.so.2"
#define MAX_TAG_LEN 7

typedef char *(*get_tag_fn)(void);
typedef int   (*set_tag_fn)(const char *newtag, const char *pass_ascii,
                            const char *pass_scancode);
typedef void  (*free_str_fn)(char *);

static const char *g_libpath = NULL;
static void       *g_handle  = NULL;
static get_tag_fn  g_get_tag = NULL;
static set_tag_fn  g_set_tag = NULL;
static free_str_fn g_free    = NULL;

static void usage(FILE *out, const char *prog)
{
        fprintf(out,
          "usage: %s get   [--lib PATH]\n"
          "       %s set   <TAG> [--lib PATH]\n"
          "       %s check [--lib PATH]\n"
          "\n"
          "  get    print the service tag currently in NVRAM\n"
          "  set    write TAG to NVRAM (7 alnum chars)\n"
          "  check  report library capability and current tag\n"
          "\n"
          "  --lib PATH   libsmbios_c.so.2 to load (default: $LIBSMBIOS_C_SO\n"
          "               or %s)\n"
          "\n"
          "Environment:\n"
          "  LIBSMBIOS_C_SO   same as --lib\n",
          prog, prog, prog, DEFAULT_LIB);
}

/* Parse flags; returns index of first positional arg, or -1 on error. */
static int parse_flags(int argc, char **argv)
{
        int i, first = -1;
        for (i = 1; i < argc; i++) {
                if (!strcmp(argv[i], "--lib")) {
                        if (i + 1 >= argc) {
                                fprintf(stderr, "error: --lib needs a path\n");
                                return -1;
                        }
                        g_libpath = argv[++i];
                } else if (!strncmp(argv[i], "--lib=", 6)) {
                        g_libpath = argv[i] + 6;
                } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
                        usage(stdout, argv[0]);
                        exit(0);
                } else if (argv[i][0] != '-' && first < 0) {
                        first = i;
                }
        }
        return first;
}

static int load_lib(void)
{
        if (!g_libpath) {
                const char *env = getenv("LIBSMBIOS_C_SO");
                g_libpath = (env && *env) ? env : DEFAULT_LIB;
        }

        /* Absolute/relative-with-slash paths only, so we never silently pick
         * up a distro libsmbios that lacks the setter. */
        if (!strchr(g_libpath, '/')) {
                fprintf(stderr,
                        "error: --lib must contain a path component "
                        "(got \"%s\")\n", g_libpath);
                return 2;
        }

        struct stat st;
        if (stat(g_libpath, &st) != 0) {
                fprintf(stderr, "error: cannot stat %s: %s\n",
                        g_libpath, strerror(errno));
                fprintf(stderr, "hint: run scripts/build.sh first\n");
                return 2;
        }

        dlerror();
        g_handle = dlopen(g_libpath, RTLD_NOW | RTLD_LOCAL);
        if (!g_handle) {
                fprintf(stderr, "error: dlopen(%s) failed: %s\n",
                        g_libpath, dlerror());
                return 2;
        }

        *(void **)(&g_get_tag) = dlsym(g_handle, "sysinfo_get_service_tag");
        *(void **)(&g_set_tag) = dlsym(g_handle, "sysinfo_set_service_tag");
        *(void **)(&g_free)    = dlsym(g_handle, "sysinfo_string_free");

        if (!g_get_tag) {
                fprintf(stderr,
                        "error: %s has no sysinfo_get_service_tag - "
                        "wrong library?\n", g_libpath);
                return 2;
        }
        if (!g_set_tag) {
                fprintf(stderr,
                        "error: %s has no sysinfo_set_service_tag - this is "
                        "the dumbed-down build; use el6 libsmbios 2.2.27\n",
                        g_libpath);
                return 2;
        }
        return 0;
}

static int valid_tag(const char *t)
{
        size_t n = strlen(t), i;
        if (n == 0 || n > MAX_TAG_LEN)
                return 0;
        for (i = 0; i < n; i++)
                if (!isalnum((unsigned char)t[i]))
                        return 0;
        return 1;
}

static char *get_tag(void)
{
        char *tag = g_get_tag();
        if (!tag) {
                if (geteuid() != 0)
                        fprintf(stderr, "error: firmware read needs root "
                                        "(try: sudo svctag ...)\n");
                else
                        fprintf(stderr, "error: failed to read service tag "
                                        "from firmware\n");
                return NULL;
        }
        return tag;
}

static int cmd_get(void)
{
        char *tag = get_tag();
        if (!tag)
                return 1;
        printf("%s\n", tag);
        if (g_free)
                g_free(tag);
        return 0;
}

static int cmd_check(void)
{
        char *tag;
        int rc = 0;
        const char *dcdbas = "/sys/devices/platform/dcdbas";
        struct stat st;

        printf("lib          : %s\n", g_libpath);
        printf("get_service_tag : ok\n");
        printf("set_service_tag : ok\n");

        if (geteuid() != 0) {
                printf("privilege    : NOT ROOT (writes will fail)\n");
                rc = 1;
        } else {
                printf("privilege    : root\n");
        }

        /* The SMI write rides Dell's dcdbas kernel driver via sysfs. */
        if (stat(dcdbas, &st) == 0 && S_ISDIR(st.st_mode)) {
                char smi_req[128], smi_data[128];
                snprintf(smi_req,  sizeof smi_req,  "%s/smi_request", dcdbas);
                snprintf(smi_data, sizeof smi_data, "%s/smi_data",   dcdbas);
                if (access(smi_req, W_OK) == 0 &&
                    access(smi_data, W_OK) == 0)
                        printf("dcdbas       : SMI nodes writable\n");
                else {
                        printf("dcdbas       : present but not writable\n");
                        rc = 1;
                }
        } else {
                printf("dcdbas       : MISSING (modprobe dcdbas)\n");
                rc = 1;
        }

        if (access("/dev/mem", R_OK) != 0) {
                printf("/dev/mem     : not readable (%s)\n", strerror(errno));
                rc = 1;
        } else {
                printf("/dev/mem     : readable (probe side only)\n");
        }

        tag = get_tag();
        if (!tag) {
                printf("current tag  : <unreadable>\n");
                return 1;
        }
        printf("current tag  : %s\n", tag);
        if (g_free)
                g_free(tag);
        return rc;
}

static int cmd_set(const char *newtag)
{
        char *before, *after;
        int rc;

        if (!valid_tag(newtag)) {
                fprintf(stderr,
                        "error: \"%s\" is not a valid tag "
                        "(1-%d alphanumeric chars)\n", newtag, MAX_TAG_LEN);
                return 1;
        }

        before = get_tag();
        if (before) {
                printf("before       : %s\n", before);
                if (g_free)
                        g_free(before);
        }

        rc = g_set_tag(newtag, NULL, NULL);
        if (rc != 0) {
                fprintf(stderr,
                        "error: firmware rejected the write (rc=%d)\n", rc);
                fprintf(stderr,
                        "hint: needs bare metal, root, and /dev/mem access\n");
                return 3;
        }

        after = get_tag();
        if (!after) {
                fprintf(stderr,
                        "warn : write returned 0 but tag is unreadable\n");
                return 0;
        }

        /* Compare before freeing: g_free releases the string we would read. */
        int matches = (strcmp(after, newtag) == 0);
        printf("after        : %s\n", after);
        if (g_free)
                g_free(after);

        if (!matches) {
                fprintf(stderr,
                        "error: verification failed - tag did not stick\n");
                return 3;
        }

        printf("ok           : NVRAM updated (takes effect for OS/DMI at "
               "next boot; iDRAC re-latches at POST)\n");
        return 0;
}

int main(int argc, char **argv)
{
        int first, rc;

        first = parse_flags(argc, argv);
        if (first < 0) {
                usage(stderr, argv[0]);
                return 1;
        }
        if (first < 0 || first >= argc) {
                usage(stderr, argv[0]);
                return 1;
        }

        rc = load_lib();
        if (rc)
                return rc;

        const char *cmd = argv[first];

        if (!strcmp(cmd, "get"))
                return cmd_get();
        if (!strcmp(cmd, "check"))
                return cmd_check();
        if (!strcmp(cmd, "set")) {
                if (first + 1 >= argc) {
                        fprintf(stderr, "error: set needs a TAG argument\n");
                        return 1;
                }
                return cmd_set(argv[first + 1]);
        }

        fprintf(stderr, "error: unknown command \"%s\"\n", cmd);
        usage(stderr, argv[0]);
        return 1;
}
