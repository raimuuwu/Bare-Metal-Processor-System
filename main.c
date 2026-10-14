#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>

#define MAX_BUF  256

#define A1      "/proc/sykom/a1gara"
#define A2      "/proc/sykom/a2gara"
#define CTRL    "/proc/sykom/ctgara"
#define STATUS  "/proc/sykom/stgara"
#define RESULT  "/proc/sykom/regara"

int ok = 0;
int fail = 0;

/* -------------------------------------------------- */

void zapis(const char *plik, const char *wartosc)
{
    int fd = open(plik, O_WRONLY);
    if (fd < 0) { printf("  BLAD open(%s): %d\n", plik, errno); return; }
    write(fd, wartosc, strlen(wartosc));
    close(fd);
}

void odczyt(const char *plik, char *buf)
{
    int fd = open(plik, O_RDONLY);
    if (fd < 0) { printf("  BLAD open(%s): %d\n", plik, errno); buf[0]='\0'; return; }
    lseek(fd, 0L, SEEK_SET);
    int n = read(fd, buf, MAX_BUF - 1);
    close(fd);
    if (n > 0) {
        buf[n] = '\0';
        if (buf[n-1] == '\n') buf[n-1] = '\0';
    } else {
        buf[0] = '\0';
    }
}

/* czeka az status bedzie DONE lub ERROR, max ~2s */
void czekaj(char *status_out)
{
    for (int i = 0; i < 200; i++) {
        usleep(10000);
        odczyt(STATUS, status_out);
        if (strcmp(status_out, "DONE") == 0 || strcmp(status_out, "ERROR") == 0)
            return;
    }
}

/* -------------------------------------------------- */

void test(const char *opis, double a1, double a2, double oczekiwane)
{
    char buf[MAX_BUF];

    printf("[ %s ]\n", opis);
    printf("  a1=%.6e  a2=%.6e  oczekiwane=%.6e\n", a1, a2, oczekiwane);

    snprintf(buf, MAX_BUF, "%.10e", a1); zapis(A1, buf);
    snprintf(buf, MAX_BUF, "%.10e", a2); zapis(A2, buf);
    zapis(CTRL, "1");

    sleep(1);

    czekaj(buf);

    if (strcmp(buf, "DONE") != 0) {
        printf("  FAIL - status: %s\n\n", buf);
        fail++; return;
    }

    odczyt(RESULT, buf);
    double wynik = strtod(buf, NULL);
    double blad  = fabs(wynik - oczekiwane) / fabs(oczekiwane);

    printf("  wynik=%.10e  blad_wzgl=%.3e  ", wynik, blad);

    if (blad < 1e-4) { printf("OK\n\n");   ok++; }
    else             { printf("FAIL\n\n"); fail++; }
}

void test_blad(const char *opis, double a1, double a2)
{
    char buf[MAX_BUF];

    printf("[ %s ]\n", opis);

    snprintf(buf, MAX_BUF, "%.10e", a1); zapis(A1, buf);
    snprintf(buf, MAX_BUF, "%.10e", a2); zapis(A2, buf);
    zapis(CTRL, "1");

    sleep(1);

    czekaj(buf);

    printf("  status=%s  ", buf);
    if (strcmp(buf, "ERROR") == 0) { printf("OK\n\n");   ok++; }
    else                           { printf("FAIL\n\n"); fail++; }
}

/* -------------------------------------------------- */

int main(void)
{
    char buf[MAX_BUF];
    printf("Skompilowano: %s %s\n", __DATE__, __TIME__);
    printf("=== Test modulu dzielenia 64-bit float ===\n\n");

    odczyt(STATUS, buf);
    if (strlen(buf) == 0) {
        printf("BLAD: brak odpowiedzi z procfs.\n");
        printf("Czy modul jest zaladowany? (modprobe kernel_module)\n");
        return 1;
    }
    printf("Status startowy: %s\n\n", buf);

    /* --- podstawowe --- */
    test("1.0 / 1.0",             1.0,        1.0,       1.0);
    test("6.0 / 2.0",             6.0,        2.0,       3.0);
    test("3.0 / 2.0",             3.0,        2.0,       1.5);
    test("10.0 / 4.0",            10.0,       4.0,       2.5);

    /* --- znaki --- */
    test("-6.0 / 2.0",           -6.0,        2.0,      -3.0);
    test("6.0 / -2.0",            6.0,       -2.0,      -3.0);
    test("-6.0 / -2.0",          -6.0,       -2.0,       3.0);

    /* --- ulamki - widac blad reprezentacji --- */
    test("1.0 / 3.0",             1.0,        3.0,       1.0/3.0);
    test("1.0 / 7.0",             1.0,        7.0,       1.0/7.0);
    test("22.0 / 7.0 (~pi)",     22.0,        7.0,      22.0/7.0);
    test("355.0 / 113.0 (~pi)",  355.0,      113.0,     355.0/113.0);

    /* --- zmiennoprzecinkowe nieokragle --- */
    test("1.23456 / 7.89012",     1.23456,    7.89012,   1.23456/7.89012);
    test("9.87654 / 3.21098",     9.87654,    3.21098,   9.87654/3.21098);
    test("0.1 / 0.3",             0.1,        0.3,       0.1/0.3);
    test("123.456 / 789.012",   123.456,    789.012,   123.456/789.012);

    /* --- duze wartosci --- */
    test("1e10 / 1e5",            1e10,       1e5,       1e5);
    test("1e15 / 1e8",            1e15,       1e8,       1e7);
    test("9.99e20 / 3.33e10",     9.99e20,    3.33e10,   9.99e20/3.33e10);

    /* --- male wartosci --- */
    test("1e-10 / 1e-5",          1e-10,      1e-5,      1e-5);
    test("1e-20 / 1e-10",         1e-20,      1e-10,     1e-10);
    test("1.5e-15 / 2.5e-8",      1.5e-15,    2.5e-8,    1.5e-15/2.5e-8);

    /* --- a/a = 1 --- */
    test("12345.6789 / 12345.6789", 12345.6789, 12345.6789, 1.0);
    test("1e-30 / 1e-30",           1e-30,      1e-30,      1.0);

    /* --- blad: dzielenie przez zero --- */
    test_blad("5.0 / 0.0 => ERROR",  5.0, 0.0);
    test_blad("-3.0 / 0.0 => ERROR", -3.0, 0.0);

    printf("=== Wynik: %d OK, %d FAIL ===\n", ok, fail);
    return (fail == 0) ? 0 : 1;
}
