#include <stdio.h>
#include <sys/utsname.h>

int main(void) {
    struct utsname u;
    double x = 3.14159 * 2.0; /* soft-float 演算の確認 */
    if (uname(&u) == 0)
        printf("hello from cross-compiled binary on %s %s (%s)\n",
               u.sysname, u.release, u.machine);
    printf("soft-float check: %.5f\n", x);
    return 0;
}
