/* Probe SGTL5000 CHIP_ID (reg 0x0000) on i2c bus. usage: i2cprobe <bus> <addr7> */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/i2c-dev.h>
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    char path[32]; snprintf(path, sizeof path, "/dev/i2c-%s", argv[1]);
    int addr = (int)strtol(argv[2], 0, 0);
    int fd = open(path, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    if (ioctl(fd, I2C_SLAVE_FORCE, addr) < 0) { perror("slave"); return 1; }
    /* write 16-bit reg addr 0x0000 (big endian), then read 2 bytes */
    unsigned char reg[2] = {0x00, 0x00};
    if (write(fd, reg, 2) != 2) { perror("write"); printf("WRITE_FAIL\n"); return 3; }
    unsigned char buf[2] = {0,0};
    if (read(fd, buf, 2) != 2) { perror("read"); printf("READ_FAIL\n"); return 4; }
    printf("CHIP_ID=0x%02x%02x\n", buf[0], buf[1]);
    close(fd);
    return 0;
}
