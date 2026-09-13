/* Minimal devmem: read/write a 32-bit register via /dev/mem mmap.
   usage: devmem <addr> [value]   (hex ok with 0x)  */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    unsigned long addr = strtoul(argv[1], 0, 0);
    unsigned long page = addr & ~0xfffUL, off = addr & 0xfff;
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open"); return 1; }
    volatile unsigned int *m = mmap(0, 0x1000, PROT_READ|PROT_WRITE, MAP_SHARED, fd, page);
    if (m == MAP_FAILED) { perror("mmap"); return 1; }
    volatile unsigned int *r = (volatile unsigned int *)((char*)m + off);
    if (argc >= 3) { *r = (unsigned int)strtoul(argv[2], 0, 0); }
    printf("0x%08x\n", *r);
    munmap((void*)m, 0x1000);
    close(fd);
    return 0;
}
