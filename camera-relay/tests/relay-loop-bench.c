/*
 * relay-loop-bench — regression test for the camera-relay-monitor frame loop.
 *
 * The monitor's hot loop reads YUY2 frames from the pipeline's pipe and writes
 * them to the v4l2loopback device. Two properties matter, and both have bitten
 * us before:
 *
 *   1. NO STUTTER. Commit 9525152 removed poll() from the frame path because
 *      poll() between read_full()/write() caused periodic 30fps stutter. Any
 *      change that reintroduces poll() must be shown not to regress this.
 *
 *   2. NO CLIENT TIMEOUT ON STARTUP. The libcamera pipeline takes ~2-3s to
 *      produce its first frame. Strict V4L2 clients give up long before that
 *      (OBS uses a 166ms select() timeout), so something must keep the device
 *      fed during startup.
 *
 * Neither property depends on the camera: the loop reads a pipe and writes an
 * fd. So this runs anywhere, with no Galaxy Book, no sensor and no
 * v4l2loopback — which is the point. Nobody should have to boot hardware to
 * answer "does this change stutter?" again.
 *
 * Build & run:  cc -O2 -o relay-loop-bench relay-loop-bench.c && ./relay-loop-bench
 *
 * Keep read_full_current() below in sync with camera-relay-monitor.c.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define WIDTH  1920
#define HEIGHT 1080
#define FRAME_SIZE (WIDTH * HEIGHT * 2)	/* YUY2: 2 bytes/pixel */

#define STREAM_FRAMES     150		/* 5 seconds at 30fps */
#define FRAME_PERIOD_NS   33333333L	/* 33.333ms == 30fps */
#define STARTUP_DELAY_MS  2500		/* libcamera pipeline warm-up */
#define OBS_SELECT_MS     166		/* OBS gives up after this much silence */

/* A frame arriving this late is a visible hitch, not jitter. */
#define LATE_FRAME_MS     40.0

static int black_frames;
static double last_write_ms, max_silence_ms;

static double now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static void note_device_write(void)
{
	double t = now_ms();
	if (last_write_ms && t - last_write_ms > max_silence_ms)
		max_silence_ms = t - last_write_ms;
	last_write_ms = t;
}

/*
 * The frame loop as it stands in camera-relay-monitor.c: poll() with a 100ms
 * timeout, pumping a black frame to the device whenever the pipe falls silent
 * between frames (never mid-frame — the total == 0 guard).
 */
static int read_full_current(int fd, char *buf, int n, int out_fd, const char *black_frame)
{
	int total = 0;

	while (total < n) {
		struct pollfd pfd = { .fd = fd, .events = POLLIN, .revents = 0 };
		int ret = poll(&pfd, 1, 100);

		if (ret == 0) {
			if (total == 0 && out_fd >= 0 && black_frame) {
				struct pollfd pout = { .fd = out_fd, .events = POLLOUT, .revents = 0 };
				if (poll(&pout, 1, 0) > 0 && (pout.revents & POLLOUT)) {
					(void)!write(out_fd, black_frame, n);
					black_frames++;
					note_device_write();
				}
			}
			continue;
		}
		if (ret < 0) {
			if (errno == EINTR)
				continue;
			return total;
		}

		int r = read(fd, buf + total, n - total);
		if (r <= 0) {
			if (r == -1 && errno == EINTR)
				continue;
			return total;
		}
		total += r;
	}

	return total;
}

/* The pre-9525152 loop: a tight blocking read, no poll(). Kept as the baseline
 * the stutter test compares against. */
static int read_full_blocking(int fd, char *buf, int n)
{
	int total = 0;

	while (total < n) {
		int r = read(fd, buf + total, n - total);
		if (r <= 0) {
			if (r == -1 && errno == EINTR)
				continue;
			return total;
		}
		total += r;
	}

	return total;
}

/* Feed the pipe one frame every 33.333ms, after an optional startup stall. */
static pid_t spawn_pipeline(int write_fd, int frames, int startup_delay_ms)
{
	pid_t pid = fork();
	if (pid != 0)
		return pid;

	char *frame = malloc(FRAME_SIZE);
	memset(frame, 0x7f, FRAME_SIZE);

	if (startup_delay_ms)
		usleep(startup_delay_ms * 1000);

	struct timespec next;
	clock_gettime(CLOCK_MONOTONIC, &next);

	for (int i = 0; i < frames; i++) {
		if (i) {
			next.tv_nsec += FRAME_PERIOD_NS;
			if (next.tv_nsec >= 1000000000L) {
				next.tv_nsec -= 1000000000L;
				next.tv_sec++;
			}
			clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
		}

		int off = 0;
		while (off < FRAME_SIZE) {
			int w = write(write_fd, frame + off, FRAME_SIZE - off);
			if (w <= 0) {
				if (errno == EINTR)
					continue;
				_exit(1);
			}
			off += w;
		}
	}

	close(write_fd);
	_exit(0);
}

static int cmp_double(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

/*
 * Stream at 30fps and report the spread of inter-frame delivery intervals.
 * A stuttering loop shows up as intervals well past LATE_FRAME_MS.
 */
static int test_stutter(int use_poll_loop)
{
	int pfd[2];
	if (pipe(pfd))
		return -1;

	char *buf = malloc(FRAME_SIZE), *black = malloc(FRAME_SIZE);
	memset(black, 0x10, FRAME_SIZE);
	int out_fd = open("/dev/null", O_WRONLY);

	spawn_pipeline(pfd[1], STREAM_FRAMES, 0);
	close(pfd[1]);

	double *intervals = malloc(sizeof(double) * STREAM_FRAMES);
	int count = 0;
	double prev = 0;

	for (int i = 0; i < STREAM_FRAMES; i++) {
		int n = use_poll_loop
			      ? read_full_current(pfd[0], buf, FRAME_SIZE, out_fd, black)
			      : read_full_blocking(pfd[0], buf, FRAME_SIZE);
		if (n != FRAME_SIZE)
			break;

		(void)!write(out_fd, buf, FRAME_SIZE);
		double t = now_ms();
		if (i)
			intervals[count++] = t - prev;
		prev = t;
	}

	qsort(intervals, count, sizeof(double), cmp_double);

	double sum = 0;
	int late = 0;
	for (int i = 0; i < count; i++) {
		sum += intervals[i];
		if (intervals[i] > LATE_FRAME_MS)
			late++;
	}

	printf("  %-14s frames=%3d  mean=%6.2fms  p99=%6.2fms  max=%6.2fms  late(>%.0fms)=%d\n",
	       use_poll_loop ? "poll loop" : "blocking",
	       count, sum / count, intervals[(int)(count * 0.99)],
	       intervals[count - 1], LATE_FRAME_MS, late);

	close(pfd[0]);
	close(out_fd);
	free(buf); free(black); free(intervals);
	return late;
}

/*
 * Stall the pipeline for STARTUP_DELAY_MS, then measure the longest stretch the
 * device goes unwritten. That silence is what a strict client's select() sees.
 */
static double test_startup_silence(int use_poll_loop)
{
	int pfd[2];
	if (pipe(pfd))
		return -1;

	char *buf = malloc(FRAME_SIZE), *black = malloc(FRAME_SIZE);
	memset(black, 0x10, FRAME_SIZE);
	int out_fd = open("/dev/null", O_WRONLY);

	black_frames = 0;
	last_write_ms = max_silence_ms = 0;

	/* The black frame the monitor writes in IDLE, before the pipeline starts.
	 * The client's silence is measured from here. */
	(void)!write(out_fd, black, FRAME_SIZE);
	note_device_write();

	spawn_pipeline(pfd[1], 1, STARTUP_DELAY_MS);
	close(pfd[1]);

	int n = use_poll_loop
		      ? read_full_current(pfd[0], buf, FRAME_SIZE, out_fd, black)
		      : read_full_blocking(pfd[0], buf, FRAME_SIZE);
	if (n == FRAME_SIZE) {
		(void)!write(out_fd, buf, FRAME_SIZE);
		note_device_write();
	}

	printf("  %-14s black_frames=%-3d  longest_silence=%6.0fms  OBS(%dms) -> %s\n",
	       use_poll_loop ? "poll loop" : "blocking",
	       black_frames, max_silence_ms, OBS_SELECT_MS,
	       max_silence_ms > OBS_SELECT_MS ? "DISCONNECTS" : "stays connected");

	double silence = max_silence_ms;
	close(pfd[0]);
	close(out_fd);
	free(buf); free(black);
	return silence;
}

int main(void)
{
	int fail = 0;

	printf("30fps streaming — the poll loop must not stutter (baseline: blocking read)\n");
	test_stutter(0);
	int late = test_stutter(1);
	if (late > 0) {
		printf("  FAIL: poll loop delivered %d late frame(s)\n", late);
		fail = 1;
	}

	printf("\n%dms pipeline startup — the device must not go silent past OBS's timeout\n",
	       STARTUP_DELAY_MS);
	test_startup_silence(0);
	double silence = test_startup_silence(1);
	if (silence > OBS_SELECT_MS) {
		printf("  FAIL: poll loop left the device silent for %.0fms\n", silence);
		fail = 1;
	}

	printf("\n%s\n", fail ? "FAILED" : "PASS — no stutter, no client timeout.");
	return fail;
}
