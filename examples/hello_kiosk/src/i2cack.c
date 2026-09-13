/* I2C address ACK scanner: tests whether slaves ACK their address, independent
 * of any register read. Uses a zero-content quick-write probe (like i2cdetect's
 * SMBus quick), falling back to a 1-byte read for a specific address.
 *
 *   i2cack <bus>            scan 0x03..0x77, print ACKing addresses
 *   i2cack <bus> <addr7>    probe one address, print ACK or NAK (exit 0/1)
 *
 * ACK test = I2C_RDWR with a zero-length write message. If the controller sees
 * an address ACK it returns >=0; a NAK gives -ENXIO. This checks presence only,
 * needing no MCLK-dependent register access on the codec side.
 */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/ioctl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>

static int ack(int fd, int addr) {
    struct i2c_msg msg = { .addr = addr, .flags = 0, .len = 0, .buf = NULL };
    struct i2c_rdwr_ioctl_data io = { .msgs = &msg, .nmsgs = 1 };
    if (ioctl(fd, I2C_RDWR, &io) >= 0)
        return 1;
    /* Some controllers reject zero-length writes; fall back to 1-byte read. */
    if (errno == EOPNOTSUPP || errno == EINVAL) {
        unsigned char b;
        struct i2c_msg m2 = { .addr = addr, .flags = I2C_M_RD, .len = 1, .buf = &b };
        struct i2c_rdwr_ioctl_data io2 = { .msgs = &m2, .nmsgs = 1 };
        return ioctl(fd, I2C_RDWR, &io2) >= 0 ? 1 : 0;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: i2cack <bus> [addr7]\n"); return 2; }
    char path[32];
    snprintf(path, sizeof path, "/dev/i2c-%s", argv[1]);
    int fd = open(path, O_RDWR);
    if (fd < 0) { perror("open"); return 2; }

    if (argc >= 3) {
        int addr = (int)strtol(argv[2], 0, 0);
        int a = ack(fd, addr);
        printf("0x%02x %s\n", addr, a ? "ACK" : "NAK");
        close(fd);
        return a ? 0 : 1;
    }

    printf("scan %s:", path);
    int found = 0;
    for (int addr = 0x03; addr <= 0x77; addr++)
        if (ack(fd, addr)) { printf(" 0x%02x", addr); found++; }
    printf(found ? "\n" : " (none)\n");
    close(fd);
    return 0;
}
