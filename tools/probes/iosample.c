// iosample: log eMMC I/O counters and what e2fsck, block and mount_root wait
// on, every 5 ms while preinit runs, to the kernel log.
//
// Build: docker run --rm --platform linux/arm64 -v "$PWD":/w -w /w alpine:3.20 sh -c 'apk add -q gcc musl-dev linux-headers && gcc -static -Os -s -o NAME tools/probes/NAME.c'
// usage: iosample [seconds]   (default 2)
//
// It writes to /tmp/iosample.log, because the kernel log drops lines in a
// burst like this. Each line starts with CLOCK_MONOTONIC seconds, the clock
// dmesg uses.
//
// It writes a line only when something changed. That is either the mmcblk0
// counters from /proc/diskstats (reads, sectors read, writes, sectors
// written, ms busy) or the top kernel stack frame of a watched process.
#include <ctype.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int kfd = -1;

static void klog(const char *s)
{
	struct timespec now;
	char stamp[32];
	clock_gettime(CLOCK_MONOTONIC, &now);
	int n = snprintf(stamp, sizeof stamp, "[%5ld.%06ld] ", (long)now.tv_sec, now.tv_nsec / 1000);
	if (kfd >= 0) {
		(void)!write(kfd, stamp, n);
		(void)!write(kfd, s, strlen(s));
	}
}

static void readfile(const char *path, char *buf, size_t len)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	ssize_t n = fd >= 0 ? read(fd, buf, len - 1) : -1;
	buf[n > 0 ? n : 0] = 0;
	if (fd >= 0)
		close(fd);
}

int main(int argc, char **argv)
{
	int seconds = argc > 1 ? atoi(argv[1]) : 2;
	static const char *watch[] = {"e2fsck", "block", "mount_root", "mount", NULL};
	struct timespec tick = {0, 5 * 1000 * 1000};
	char last_io[160] = "", last_st[512] = "", buf[4096], line[768];

	kfd = open("/tmp/iosample.log", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
	for (long n = 0; n < seconds * 200L; n++) {
		char io[160] = "", st[512] = "";
		readfile("/proc/diskstats", buf, sizeof buf);
		for (char *l = strtok(buf, "\n"); l; l = strtok(NULL, "\n")) {
			unsigned maj, min;
			char name[32];
			unsigned long long f[11];
			if (sscanf(l, "%u %u %31s %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu", &maj, &min, name,
				   &f[0], &f[1], &f[2], &f[3], &f[4], &f[5], &f[6], &f[7], &f[8], &f[9], &f[10]) == 14 &&
			    !strcmp(name, "mmcblk0")) {
				snprintf(io, sizeof io, "r%llu rs%llu w%llu ws%llu q%llu busy%llu", f[0], f[2], f[4], f[6], f[8], f[9]);
				break;
			}
		}
		DIR *d = opendir("/proc");
		struct dirent *e;
		while (d && (e = readdir(d))) {
			if (!isdigit((unsigned char)e->d_name[0]))
				continue;
			char path[300], comm[32];
			snprintf(path, sizeof path, "/proc/%s/comm", e->d_name);
			readfile(path, comm, sizeof comm);
			comm[strcspn(comm, "\n")] = 0;
			for (int w = 0; watch[w]; w++) {
				if (strcmp(comm, watch[w]))
					continue;
				snprintf(path, sizeof path, "/proc/%s/stack", e->d_name);
				char stack[1024];
				readfile(path, stack, sizeof stack);
				// frames look like "[<addr>] name+0x../0x..": keep the second frame's name
				char *fr = strchr(stack, '\n');
				fr = fr ? strchr(fr, ']') : NULL;
				char top[64] = "?";
				if (fr)
					sscanf(fr + 1, " %63[^+\n]", top);
				size_t used = strlen(st);
				snprintf(st + used, sizeof st - used, " %s:%s", comm, top);
			}
		}
		if (d)
			closedir(d);
		if (strcmp(io, last_io) || strcmp(st, last_st)) {
			snprintf(line, sizeof line, "iosample: %s |%s\n", io, st);
			klog(line);
			strcpy(last_io, io);
			strcpy(last_st, st);
		}
		nanosleep(&tick, NULL);
	}
	return 0;
}
