/* bootclock: how long ago the Brick was switched on.
 *
 * The ARM counter starts at power-on, so it includes the time the bootloader
 * took before Linux started its own clocks. Prints three numbers in
 * milliseconds: counter time, CLOCK_MONOTONIC_RAW and CLOCK_BOOTTIME. While
 * the device has not slept since it started, counter minus MONOTONIC_RAW is
 * the time before Linux. BOOTTIME minus MONOTONIC_RAW shows whether it slept.
 * Exits 1 when the counter cannot be read, or the sample was interrupted.
 */
#define _POSIX_C_SOURCE 200809L
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static void unavailable(int sig)
{
	(void)sig;
	_exit(1);
}

static uint64_t counter(void)
{
	uint64_t v;
	__asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(v) : : "memory");
	return v;
}

static uint64_t ms(struct timespec t)
{
	return (uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000;
}

int main(void)
{
	uint64_t freq, before, after;
	struct timespec raw, boot;

	if (signal(SIGILL, unavailable) == SIG_ERR)
		return 1;
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(freq));
	if (freq == 0)
		return 1;
	before = counter();
	if (clock_gettime(CLOCK_MONOTONIC_RAW, &raw))
		return 1;
	after = counter();
	if (clock_gettime(CLOCK_BOOTTIME, &boot) || after < before || after - before > freq / 1000)
		return 1;
	printf("%" PRIu64 " %" PRIu64 " %" PRIu64 "\n", (before + (after - before) / 2) / (freq / 1000), ms(raw), ms(boot));
	return fflush(stdout) ? 1 : 0;
}
