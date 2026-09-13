/* Flexible I2C read: identify an unknown device by reading raw bytes, with an
 * optional register pointer written first. Works for devices with no register
 * pointer, an 8-bit pointer, or a 16-bit pointer.
 *
 *   i2cread <bus> <addr7> [nbytes]                 plain read of nbytes (default 2)
 *   i2cread <bus> <addr7> <nbytes> <reg...>        write reg bytes, then read
 *
 * Examples:
 *   i2cread 0 0x1a 4               read 4 bytes from 0x1a (no pointer)
 *   i2cread 0 0x1a 2 0x00          write reg 0x00 (8-bit), read 2 bytes
 *   i2cread 0 0x0a 2 0x00 0x00     write reg 0x0000 (16-bit BE), read 2 (SGTL5000 CHIP_ID)
 *
 * Uses I2C_RDWR so a NAK on the address is reported (does not hang). Prints the
 * bytes in hex; exit 0 on success, 1 on NAK/error.
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

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: i2cread <bus> <addr7> [nbytes] [reg...]\n");
        return 2;
    }
    char path[32];
    snprintf(path, sizeof path, "/dev/i2c-%s", argv[1]);
    int addr = (int)strtol(argv[2], 0, 0);
    int n = (argc >= 4) ? (int)strtol(argv[3], 0, 0) : 2;
    if (n < 1) n = 1;
    if (n > 32) n = 32;

    int nreg = (argc > 4) ? argc - 4 : 0;
    unsigned char reg[8];
    for (int i = 0; i < nreg && i < 8; i++)
        reg[i] = (unsigned char)strtol(argv[4 + i], 0, 0);

    int fd = open(path, O_RDWR);
    if (fd < 0) { perror("open"); return 2; }

    unsigned char buf[32] = {0};
    struct i2c_msg msgs[2];
    struct i2c_rdwr_ioctl_data io;
    int nmsgs = 0;

    if (nreg > 0) {
        msgs[nmsgs].addr = addr;
        msgs[nmsgs].flags = 0;
        msgs[nmsgs].len = nreg;
        msgs[nmsgs].buf = reg;
        nmsgs++;
    }
    msgs[nmsgs].addr = addr;
    msgs[nmsgs].flags = I2C_M_RD;
    msgs[nmsgs].len = n;
    msgs[nmsgs].buf = buf;
    nmsgs++;

    io.msgs = msgs;
    io.nmsgs = nmsgs;

    if (ioctl(fd, I2C_RDWR, &io) < 0) {
        printf("0x%02x NAK/ERR (%s)\n", addr, strerror(errno));
        close(fd);
        return 1;
    }

    printf("0x%02x:", addr);
    for (int i = 0; i < n; i++) printf(" %02x", buf[i]);
    printf("\n");
    close(fd);
    return 0;
}
