#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <string.h>

static void msg(const char *s) {
    write(2, s, strlen(s));
}

int main(void) {
    mkdir("/proc", 0555);
    mkdir("/sys", 0555);
    mkdir("/tmp", 0755);
    mkdir("/var", 0755);
    mkdir("/root", 0700);
    mkdir("/etc", 0755);

    mount("proc", "/proc", "proc", 0, NULL);
    mount("sysfs", "/sys", "sysfs", 0, NULL);

    /* Mount etc partition (mtdblock3) as RW jffs2 */
    mount("/dev/mtdblock3", "/etc", "jffs2", MS_SYNCHRONOUS, NULL);

    setenv("PATH", "/sbin:/bin:/usr/sbin:/usr/bin", 1);
    setenv("HOME", "/root", 1);
    setenv("TERM", "linux", 1);
    setenv("SHELL", "/bin/hush", 1);
    setenv("HOSTNAME", "buildroot", 1);

    while (1) {
        pid_t pid = vfork();
        if (pid == 0) {
            int fd = open("/dev/console", O_RDWR);
            if (fd >= 0) {
                dup2(fd, 0);
                dup2(fd, 1);
                dup2(fd, 2);
                if (fd > 2) close(fd);
            }
            execl("/bin/hush", "hush", NULL);
            _exit(1);
        }
        if (pid > 0) {
            int status;
            waitpid(pid, &status, 0);
        }
    }
    return 0;
}
