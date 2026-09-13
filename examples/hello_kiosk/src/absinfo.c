/* Print EV_ABS ranges for an evdev device. usage: absinfo /dev/input/event1 */
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/input.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    char name[128] = {0};
    ioctl(fd, EVIOCGNAME(sizeof name), name);
    printf("name=%s\n", name);
    int codes[] = {ABS_X, ABS_Y, ABS_PRESSURE};
    const char *n[] = {"ABS_X", "ABS_Y", "ABS_PRESSURE"};
    for (int i = 0; i < 3; i++) {
        struct input_absinfo a;
        if (ioctl(fd, EVIOCGABS(codes[i]), &a) == 0)
            printf("%s: min=%d max=%d val=%d\n", n[i], a.minimum, a.maximum, a.value);
    }
    close(fd);
    return 0;
}
