#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 3) return 1;
    return symlink(argv[1], argv[2]) ? 1 : 0;
}
