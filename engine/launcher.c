// Startprogramm der Moonvisor-Engine.
//
// QEMU, qemu-img und swtpm liegen in der Engine als Bibliotheken (Frameworks), so wie sie der
// UTM-Build erzeugt. Dieses kleine Programm lädt das passende Framework und ruft dessen
// Einstiegspunkt auf. Es wird pro Werkzeug einmal mit -DENGINE_FRAMEWORK="name" übersetzt und
// liegt dann als bin/qemu-system-aarch64, bin/qemu-img und bin/swtpm in der Engine.
//
// Anders als der UTM-Launcher beendet es sich nicht mit dem aufrufenden Prozess: Moonvisor-VMs
// laufen weiter, wenn die App geschlossen wird.

#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef ENGINE_FRAMEWORK
#error "ENGINE_FRAMEWORK muss gesetzt sein"
#endif

extern char **environ;

typedef int (*main_fn)(int, const char *[]);
typedef int (*qemu_init_fn)(int, const char *[], const char *[]);
typedef void (*void_fn)(void);
typedef int (*swtpm_main_fn)(int, const char *[], const char *, const char *);

static int framework_path(char *out, size_t size) {
    char exe[PATH_MAX];
    uint32_t length = sizeof(exe);
    if (_NSGetExecutablePath(exe, &length) != 0) return -1;
    char resolved[PATH_MAX];
    if (realpath(exe, resolved) == NULL) return -1;
    char *bin = dirname(resolved);
    int n = snprintf(out, size, "%s/../Frameworks/%s.framework/%s", bin, ENGINE_FRAMEWORK, ENGINE_FRAMEWORK);
    return (n > 0 && (size_t)n < size) ? 0 : -1;
}

int main(int argc, const char *argv[]) {
    char path[PATH_MAX];
    if (framework_path(path, sizeof(path)) != 0) {
        fprintf(stderr, "moonvisor-engine: Pfad zu %s nicht ermittelbar\n", ENGINE_FRAMEWORK);
        return 70;
    }
    void *handle = dlopen(path, RTLD_LOCAL | RTLD_LAZY | RTLD_FIRST);
    if (handle == NULL) {
        fprintf(stderr, "moonvisor-engine: %s\n", dlerror());
        return 70;
    }

    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

    swtpm_main_fn swtpm_main = (swtpm_main_fn)dlsym(handle, "swtpm_main");
    if (swtpm_main != NULL) {
        // Wie das swtpm-Programm: `swtpm socket <optionen>`.
        if (argc < 2) {
            fprintf(stderr, "Aufruf: swtpm socket <optionen>\n");
            return 64;
        }
        return swtpm_main(argc - 1, &argv[1], "swtpm", argv[1]);
    }

    qemu_init_fn qemu_init = (qemu_init_fn)dlsym(handle, "qemu_init");
    void_fn qemu_main_loop = (void_fn)dlsym(handle, "qemu_main_loop");
    void_fn qemu_cleanup = (void_fn)dlsym(handle, "qemu_cleanup");
    if (qemu_init != NULL && qemu_main_loop != NULL && qemu_cleanup != NULL) {
        int status = qemu_init(argc, argv, (const char **)environ);
        if (status != 0) return status;
        qemu_main_loop();
        qemu_cleanup();
        return 0;
    }

    main_fn tool_main = (main_fn)dlsym(handle, "main");
    if (tool_main != NULL) {
        return tool_main(argc, argv);
    }

    fprintf(stderr, "moonvisor-engine: %s hat keinen bekannten Einstiegspunkt\n", ENGINE_FRAMEWORK);
    return 70;
}
