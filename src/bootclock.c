/* bootclock: how long the Brick took to start Linux after it was switched on.
 *
 * The ARM counter starts at power-on; Linux's CLOCK_MONOTONIC_RAW starts when
 * the kernel does. Neither is adjusted by NTP, and both pause while the Brick
 * sleeps, so their difference is the time before Linux at any later moment.
 * Prints it in milliseconds. Exits 1 when the counter cannot be read, or the
 * sample was interrupted.
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

int main(void)
{
	uint64_t freq, before, after, now_ms, raw_ms;
	struct timespec raw;

	if (signal(SIGILL, unavailable) == SIG_ERR)
		return 1;
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(freq));
	if (freq < 1000)
		return 1;
	before = counter();
	if (clock_gettime(CLOCK_MONOTONIC_RAW, &raw))
		return 1;
	after = counter();
	if (after < before || after - before > freq / 1000)
		return 1;
	now_ms = (before + (after - before) / 2) / (freq / 1000);
	raw_ms = (uint64_t)raw.tv_sec * 1000 + (uint64_t)raw.tv_nsec / 1000000;
	if (now_ms < raw_ms)
		return 1;
	printf("%" PRIu64 "\n", now_ms - raw_ms);
	return fflush(stdout) ? 1 : 0;
}
