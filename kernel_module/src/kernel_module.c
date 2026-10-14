#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/string.h>
#include <linux/math64.h>

MODULE_INFO(intree, "Y");
MODULE_LICENSE("GPL");
MODULE_AUTHOR("SYKOM SYKOMOWSKI");
MODULE_DESCRIPTION("Simple kernel module for SYKOM lecture");
MODULE_VERSION("0.02");

#define SYKT_GPIO_BASE_ADDR  0x00100000
#define SYKT_GPIO_SIZE       0x8000
#define SYKT_EXIT            0x3333
#define SYKT_EXIT_CODE       0x7F

#define OFF_ARG1_L   0x0D0
#define OFF_ARG1_H   0x0D8
#define OFF_ARG2_L   0x0E0
#define OFF_ARG2_H   0x0E8
#define OFF_STATUS   0x0F0
#define OFF_RES_L    0x0F8
#define OFF_RES_H    0x100
#define OFF_CTRL     0x108

void __iomem *baseptr;

static struct proc_dir_entry *proc_dir;
static struct proc_dir_entry *ent_a1;
static struct proc_dir_entry *ent_a2;
static struct proc_dir_entry *ent_ct;
static struct proc_dir_entry *ent_st;
static struct proc_dir_entry *ent_re;

/* ================================================================
 * parse_float: Konwertuje tekst np. "1.5e1" na binarne 64-bity
 * ================================================================ */
static u64 parse_float(const char *str)
{
    // czytanie znaku liczby
    while (*str == ' ' || *str == '\n') str++;
    
    int sign = 0;
    if (*str == '-') { sign = 1; str++; }
    else if (*str == '+') { str++; }

    // czytanie czesci calkowitej
    u64 num = 0;
    while (*str >= '0' && *str <= '9') {
        num = num * 10 + (*str - '0');
        str++;
    }

    // czytanie czesci po .
    int num_frac = 0;
    if (*str == '.') {
        str++;
        // jesli jest cyfra to git lecimy czytac dalej
        while (*str >= '0' && *str <= '9') {
            num = num * 10 + (*str - '0');
            num_frac++;
            str++;
        }
    }

    // czytanie wykladnika po e i zamiana go na potege
    int dec_exp = 0;
    if (*str == 'e' || *str == 'E') {
        str++;
        int exp_sign = 1;
        if (*str == '-') { exp_sign = -1; str++; }
        else if (*str == '+') { str++; }
        
        // analogicznie czytamy znaki
        while (*str >= '0' && *str <= '9') {
            dec_exp = dec_exp * 10 + (*str - '0');
            str++;
        }
        dec_exp *= exp_sign;
    }

    // weryfikacja czy to 0
    if (num == 0) return 0ULL;

    // poprawienie wykladnika po konwersji
    dec_exp -= num_frac;

    // zmiana wykladnika z dec na bin
    int bin_exp = 0;
    while (dec_exp > 0) {
        // sprawdzam czy liczba zmiesci sie na 64bit
        if (num > 1844674407370955161ULL) {     // tu jest 0xFFFFFFFFFFFFFFFFULL / 10 jak coś
            // jesli sie nie zmiesci to przesuwam bitowo w prawo i podnosze expa
            num >>= 1; 
            bin_exp++; 
            continue;
        }
        num = num * 10ULL;
        dec_exp--;
        
    }
    // analogiczna wersja dla ujemnej potegi e
    while (dec_exp < 0) {
        // sprawdzamy czy liczba ma 0 na danej pozycji zeby zabezpieczyc sie przed overflow
        while ((num & (1ULL << 60)) == 0) {
            // przesuwajac w lewo obnizamy potege 
            num <<= 1;
            bin_exp--;
        }
        do_div(num, 10);
        dec_exp++;
    }

    // wyznaczamy najstarszy bit
    int msb = 0;
    u64 temp = num;
    while (temp > 0) { temp >>= 1; msb++; }

    // przesuwamy odpowiednio liczbe do naszej oczekiwanej postaci na 53 bitach
    if (msb < 54) {
        num <<= (54 - msb);
        bin_exp -= (54 - msb);
    } else if (msb > 54) {
        num >>= (msb - 54);
        bin_exp += (msb - 54);
    }

    // skladanie calosci na wyjscie
    u64 mantissa = num & ((1ULL << 53) - 1); 
    int stored_exp = (53 + bin_exp) + 511;

    // overflow i underflow protection
    if (stored_exp < 0) return 0ULL;
    if (stored_exp > 1023) stored_exp = 1023;

    return ((u64)sign << 63) | (mantissa << 10) | (stored_exp & 0x3FF);
}

/* ================================================================
 * format_float: Konwertuje 64-bity z Veriloga na string "X.YYYe0"
 * ================================================================ */
static int format_float(u64 val, char *buf, size_t bufsz)
{
    if (val == 0) return snprintf(buf, bufsz, "0.000e0\n");

    // rozbicie z dziwnego formatu
    int sign     = (val >> 63) & 1;
    int exp      = (val & 0x3FF) - 511;
    u64 mantissa = (val >> 10) & ((1ULL << 53) - 1);

    // przywrocenie bitu ukrytego + obliczenie przesuniecia odpowiedniego
    u64 full_mant = (1ULL << 53) | mantissa;
    int shift = exp - 53;

    u64 int_part = 0;
    u64 frac_part = 0;
    
    // tu jest przywracanie jakby liczby na wypadek jakby wyszlo ze przecinek jest w srodku mantysy
    if (shift >= 0) {
        if (shift < 10) int_part = full_mant << shift;
        else int_part = 0xFFFFFFFFFFFFFFFFULL; // zabezpieczenie przed overflow ig
    } else {
        // maska na odpowiednie bity
        int_part = full_mant >> (-shift);
        
        // zmieniamy reszte na ulamek dziesietny (3 miejsca po przecinku)
        u64 remainder = full_mant & ((1ULL << (-shift)) - 1);
        if (-shift < 64) {
            frac_part = (remainder * 1000ULL) >> (-shift);
        }
    }

    return snprintf(buf, bufsz, "%s%llu.%03llue0\n", 
                    sign ? "-" : "", 
                    (unsigned long long)int_part, 
                    (unsigned long long)frac_part);
}

static void write_arg(u64 val, unsigned long off_lo, unsigned long off_hi)
{
    // dzielenie wartosci na 2 czesci przy pomocy maskowania
    u32 lo = (u32)(val & 0xFFFFFFFF);
    u32 hi = (u32)(val >> 32);
    // zapis w odpowiednie miejsce :3
    writel(lo, baseptr + off_lo);
    writel(hi, baseptr + off_hi);
}

static u64 read_result(void)
{
    // odczytanie wartosci z marginesem przesuniecia i usuniecie go
    u32 lo = readl(baseptr + OFF_RES_L);
    u32 hi = readl(baseptr + OFF_RES_H);
    return ((u64)hi << 32) | (u64)lo;
}

/* ================================================================
 * a1gara - zapis argumentu 1
 * ================================================================ */
static ssize_t a1_write(struct file *file, const char __user *ubuf,
                        size_t count, loff_t *offset)
{
    // deklaracja pamieci i zmiennej do wrzucenia
    char buf[64];
    u64 val;

    // sprawdzenie czy ktos nie chce wpisac 0 bajtow albo nie chce zepsuc wszystkiego
    if (count == 0 || count >= sizeof(buf))
        return -EINVAL;

    // tu przesylane sa dane z pamieci urzytkownika do pamieci kernela
    if (copy_from_user(buf, ubuf, count))
        return -EFAULT;

    buf[count] = '\0';

    // tu faktycznie odbywa sie zapis
    val = parse_float(buf);
    write_arg(val, OFF_ARG1_L, OFF_ARG1_H);

    return count;
}

/* ================================================================
 * a2gara - zapis argumentu 2
 * ================================================================ */
static ssize_t a2_write(struct file *file, const char __user *ubuf,
                        size_t count, loff_t *offset)
{
    // analogicznie jest deklaracja pamieci buforu do zapisu
    char buf[64];
    u64 val;

    // sprawdzenie czy na pewno ktos wysyla bity itp
    if (count == 0 || count >= sizeof(buf))
        return -EINVAL;

    // bezpieczne przesylanie do pamieci kernela danych
    if (copy_from_user(buf, ubuf, count))
        return -EFAULT;

    buf[count] = '\0';

    // zapisane do pliku faktycznie wartosci 
    val = parse_float(buf);
    write_arg(val, OFF_ARG2_L, OFF_ARG2_H);

    return count;
}

/* ================================================================
 * ctgara - sterowanie: "1" = START, "2" = ABORT
 * ================================================================ */
static ssize_t ct_write(struct file *file, const char __user *ubuf,
                        size_t count, loff_t *offset)
{
    char buf[64];

    // ponowne sprawdzenie czy faktycznie nie zapisuje 0
    if (count == 0 || count >= sizeof(buf))
        return -EINVAL;

    // bezpieczne kopiowanie danych do pamieci kernela
    if (copy_from_user(buf, ubuf, count))
        return -EFAULT;

    buf[count] = '\0';

    // jak wysyla 1 to zapisuje sygnal startu
    if (buf[0] == '1')
        writel(1, baseptr + OFF_CTRL);
    // jak jest 2 to zapisuje sygnal abortu dzialania
    else if (buf[0] == '2')
        writel(2, baseptr + OFF_CTRL);
    else
        return -EINVAL;

    return count;
}

/* ================================================================
 * stgara - odczyt statusu
 * ================================================================ */
static ssize_t st_read(struct file *file, char __user *ubuf,
                       size_t count, loff_t *offset)
{
    char buf[32];
    int len;
    u32 status;

    // to sprawdza czy juz zostaly odczytane dane, jesli tak to zwraca 0; dziala to jak end of file
    if (*offset > 0)
        return 0;

    // pobranie aktualnej wartosci statusu
    status = readl(baseptr + OFF_STATUS);

    // switch case do sprawdzenia aktualnego stanu
    if (status == 0)
        len = snprintf(buf, sizeof(buf), "IDLE\n");
    else if (status == 1)
        len = snprintf(buf, sizeof(buf), "BUSY\n");
    else if (status == 2)
        len = snprintf(buf, sizeof(buf), "DONE\n");
    else if (status == 3)
        len = snprintf(buf, sizeof(buf), "ERROR\n");
    else
        len = snprintf(buf, sizeof(buf), "UNKNOWN\n");

    // sprawdza czy bufor pomiesci nasz tekst, jesli nie to zwraca blad
    if ((size_t)len > count)
        return -EINVAL;

    // bezpiecnzie przekopiowuje dane z kernela do naszego ramu
    if (copy_to_user(ubuf, buf, len))
        return -EFAULT;

    // informacja ile znakow zostalo odczytane faktycznie i o tyle przesuwa sie offset 
    *offset += len;
    return len;
}

/* ================================================================
 * regara - odczyt wyniku
 * ================================================================ */
static ssize_t re_read(struct file *file, char __user *ubuf,
                       size_t count, loff_t *offset)
{
    char buf[32];
    int len;
    u64 result;

    // tak jak wczesniej sprawdza czy dane byly odczytane
    if (*offset > 0)
        return 0;

    // tu odbierane jest i skladane w naszych rejestrach wynik i skladanie go do ludzkiej postaci naukowej
    result = read_result();
    len = format_float(result, buf, sizeof(buf));

    // sprawdzamy czy bufor sie zmiesci
    if ((size_t)len > count)
        return -EINVAL;

    // bezpiecznie przenosimy dane
    if (copy_to_user(ubuf, buf, len))
        return -EFAULT;

    // przesuwamy offset zeby wiedziec ze to odczytane zostalo juz
    *offset += len;
    return len;
}

// tu essentialy jest filesystem. tworzy swoje pliki, dodaje im odpowiednio write do wejscia i sterowania oraz read do wyniku i statusu
static const struct file_operations a1_ops = { .owner = THIS_MODULE, .write = a1_write };
static const struct file_operations a2_ops = { .owner = THIS_MODULE, .write = a2_write };
static const struct file_operations ct_ops = { .owner = THIS_MODULE, .write = ct_write };
static const struct file_operations st_ops = { .owner = THIS_MODULE, .read  = st_read  };
static const struct file_operations re_ops = { .owner = THIS_MODULE, .read  = re_read  };

/* ================================================================
 * init
 * ================================================================ */
int my_init_module(void)
{
    printk(KERN_INFO "Init my module.\n");

    // przypisanie wirtualnej bazy pamieci, jak nie to error i stop
    baseptr = ioremap(SYKT_GPIO_BASE_ADDR, SYKT_GPIO_SIZE);
    if (!baseptr) {
        printk(KERN_ERR "ioremap failed!\n");
        return -ENOMEM;
    }

    // stworzenie glownego folderu dla tego systemu , jak nie to error i stop
    proc_dir = proc_mkdir("sykom", NULL);
    if (!proc_dir) {
        printk(KERN_ERR "proc_mkdir failed!\n");
        iounmap(baseptr);
        return -ENOMEM;
    }

    // kreacja plokow odpowiedzialnych za dzialanie polaczenia z verilogiem 
    ent_a1 = proc_create("a1gara", 0220, proc_dir, &a1_ops);
    ent_a2 = proc_create("a2gara", 0220, proc_dir, &a2_ops);
    ent_ct = proc_create("ctgara", 0220, proc_dir, &ct_ops);
    ent_st = proc_create("stgara", 0444, proc_dir, &st_ops);
    ent_re = proc_create("regara", 0444, proc_dir, &re_ops);

    // jesli jest ajkis problem to jest error message i jest stop wczytywania
    if (!ent_a1 || !ent_a2 || !ent_ct || !ent_st || !ent_re) {
        printk(KERN_ERR "proc_create failed!\n");
        proc_remove(proc_dir);
        iounmap(baseptr);
        return -ENOMEM;
    }

    printk(KERN_INFO "Module loaded, /proc/sykom/ ready.\n");
    return 0;
}

/* ================================================================
 * cleanup
 * ================================================================ */
void my_cleanup_module(void)
{
    printk(KERN_INFO "Cleanup my module.\n");

    // czyszczenie plikow
    proc_remove(ent_re);
    proc_remove(ent_st);
    proc_remove(ent_ct);
    proc_remove(ent_a2);
    proc_remove(ent_a1);
    proc_remove(proc_dir);

    // wylaczenie generalne quemu
    writel(SYKT_EXIT | (SYKT_EXIT_CODE << 16), baseptr);
    iounmap(baseptr);
}

// na start modulu wczytaj modul
module_init(my_init_module);

// przy wylaczeniu modulu go usun xdd
module_exit(my_cleanup_module);
