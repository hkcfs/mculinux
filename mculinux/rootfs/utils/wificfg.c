/* wificfg: stage WiFi credentials into the esp32-wifi-shmem driver.
 *
 * Usage: wificfg [ifname] <ssid> [passphrase]
 *        wificfg scan [ifname]
 *
 * With 2 args the first is the SSID unless it names a real interface
 * (then it's an open network on that interface). An SSID that matches
 * an interface name needs the 3-arg form.
 *
 * "scan" asks Core 0 for visible networks (Part B firmware). Without
 * it, the driver times out after ~8s and reports so.
 *
 * Sends SSID/passphrase via SIOCDEVPRIVATE (staged in the driver,
 * SSID logged, passphrase never logged) then asks firmware to join
 * via SIOCDEVPRIVATE+2. Open networks join with stock firmware;
 * secured join needs the mculinux firmware passphrase extension.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <net/if.h>

#ifndef SIOCDEVPRIVATE
#define SIOCDEVPRIVATE 0x89F0
#endif
#define SIOCDEVSCAN (SIOCDEVPRIVATE + 1)

#define SCAN_MAX 32

struct esp32_wifi_net {
	unsigned char ssid[32];
	unsigned char ssid_len;
	signed char rssi;
	unsigned char channel;
	unsigned char auth;	/* 0 open, 1 WEP, 2 WPA, 3 WPA2, 4 WPA3 */
	unsigned char bssid[6];
	unsigned char pad[2];
};

struct esp32_wifi_scan {
	unsigned int max;
	unsigned int count;
	struct esp32_wifi_net nets[SCAN_MAX];
};

struct esp32_wifi_cfg {
	unsigned char ssid[32];
	unsigned char ssid_len;
	unsigned char pass[64];
	unsigned char pass_len;
};

/* if_nametoindex needs /sys (absent: no SYSFS) — probe via SIOCGIFINDEX. */
static int if_exists(const char *name)
{
	struct ifreq ifr;
	int fd, ok;

	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0)
		return 0;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
	ok = ioctl(fd, SIOCGIFINDEX, &ifr) == 0;
	close(fd);
	return ok;
}

static void usage(const char *prog)
{
	fprintf(stderr, "usage: %s [ifname] <ssid> [passphrase]\n", prog);
	fprintf(stderr, "       %s scan [ifname]\n", prog);
	fprintf(stderr, "       %s mac [ifname]\n", prog);
	fprintf(stderr, "  2 args: ssid + passphrase (ifname defaults to eth0)\n");
	fprintf(stderr, "  2 args, first names an interface: open network on it\n");
	fprintf(stderr, "  3 args: ifname + ssid + passphrase\n");
	fprintf(stderr, "  (SSID matching an interface name needs the 3-arg form)\n");
}

static const char *auth_name(unsigned char a)
{
	switch (a) {
	case 0: return "open";
	case 1: return "WEP";
	case 2: return "WPA";
	case 3: return "WPA2";
	case 4: return "WPA3";
	default: return "unknown";
	}
}

static int wifi_scan(const char *ifname)
{
	struct esp32_wifi_scan *s;
	struct ifreq ifr;
	int fd, ret, i;

	s = calloc(1, sizeof(*s));
	if (!s) {
		fprintf(stderr, "out of memory\n");
		return 1;
	}
	s->max = SCAN_MAX;
	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		perror("socket");
		free(s);
		return 1;
	}
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	ifr.ifr_data = (void *)s;

	ret = ioctl(fd, SIOCDEVSCAN, &ifr);
	close(fd);
	if (ret < 0) {
		if (errno == ETIMEDOUT)
			fprintf(stderr, "scan: firmware did not answer (Part B scan command needed)\n");
		else
			perror("ioctl(SIOCDEVPRIVATE+1)");
		free(s);
		return 1;
	}
	printf("%-32s %4s %3s %-17s %s\n", "SSID", "RSSI", "CH", "BSSID", "AUTH");
	for (i = 0; i < (int)s->count; i++) {
		unsigned char *b = s->nets[i].bssid;
		if (s->nets[i].ssid_len)
			printf("%-32.*s %4d %3u %02x:%02x:%02x:%02x:%02x:%02x %s\n",
			       s->nets[i].ssid_len, s->nets[i].ssid,
			       (int)s->nets[i].rssi, s->nets[i].channel,
			       b[0], b[1], b[2], b[3], b[4], b[5],
			       auth_name(s->nets[i].auth));
		else
			printf("%-32s %4d %3u %02x:%02x:%02x:%02x:%02x:%02x %s\n",
			       "<hidden>", (int)s->nets[i].rssi,
			       s->nets[i].channel,
			       b[0], b[1], b[2], b[3], b[4], b[5],
			       auth_name(s->nets[i].auth));
	}
	free(s);
	return 0;
}

int main(int argc, char **argv)
{
	struct esp32_wifi_cfg cfg;
	struct ifreq ifr;
	const char *ifname = "eth0";
	const char *ssid, *pass = "";
	int fd, ret;

	if (argc >= 2 && strcmp(argv[1], "scan") == 0) {
		if (argc > 3) {
			usage(argv[0]);
			return 2;
		}
		if (argc == 3)
			ifname = argv[2];
		return wifi_scan(ifname);
	}
	if (argc >= 2 && strcmp(argv[1], "mac") == 0) {
		unsigned char mac[6];
		struct ifreq mifr;
		int mfd, mret;

		if (argc > 3) {
			usage(argv[0]);
			return 2;
		}
		if (argc == 3)
			ifname = argv[2];
		mfd = socket(AF_INET, SOCK_DGRAM, 0);
		if (mfd < 0) {
			perror("socket");
			return 1;
		}
		memset(&mifr, 0, sizeof(mifr));
		strncpy(mifr.ifr_name, ifname, IFNAMSIZ - 1);
		mifr.ifr_data = (void *)mac;
		mret = ioctl(mfd, SIOCDEVPRIVATE + 3, &mifr);
		close(mfd);
		if (mret < 0) {
			if (errno == ETIMEDOUT)
				fprintf(stderr, "mac: firmware did not answer\n");
			else
				perror("ioctl(SIOCDEVPRIVATE+3)");
			return 1;
		}
		printf("%s firmware MAC: %02x:%02x:%02x:%02x:%02x:%02x\n", ifname,
		       mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
		return 0;
	}
	if (argc == 3) {
		/* "ssid pass" vs "if ssid" (open network): if argv[1]
		 * names a real interface, it's the latter. */
		if (if_exists(argv[1])) {
			ifname = argv[1];
			ssid = argv[2];
			pass = "";
		} else {
			ssid = argv[1];
			pass = argv[2];
		}
	} else if (argc == 4) {
		ifname = argv[1];
		ssid = argv[2];
		pass = argv[3];
	} else {
		usage(argv[0]);
		return 2;
	}
	if (strlen(ssid) < 1 || strlen(ssid) > 32 || strlen(pass) > 64) {
		fprintf(stderr, "wificfg: ssid 1-32 chars, passphrase 0-64 chars\n");
		return 2;
	}

	memset(&cfg, 0, sizeof(cfg));
	memcpy(cfg.ssid, ssid, strlen(ssid));
	cfg.ssid_len = strlen(ssid);
	memcpy(cfg.pass, pass, strlen(pass));
	cfg.pass_len = strlen(pass);

	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		perror("socket");
		return 1;
	}
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	ifr.ifr_data = (void *)&cfg;

	ret = ioctl(fd, SIOCDEVPRIVATE, &ifr);
	if (ret < 0) {
		perror("ioctl(SIOCDEVPRIVATE)");
		close(fd);
		return 1;
	}
	printf("credentials staged for '%s' on %s (dmesg to confirm)\n", ssid, ifname);

	/* Join the network via firmware (open works stock; secured
	 * needs the mculinux firmware passphrase extension). */
	ret = ioctl(fd, SIOCDEVPRIVATE + 2, &ifr);
	if (ret < 0) {
		if (errno == ETIMEDOUT)
			fprintf(stderr, "connect: firmware did not answer\n");
		else
			perror("ioctl(connect)");
		fprintf(stderr, "connect failed, credentials stay staged\n");
		close(fd);
		return 1;
	}
	printf("connect request accepted for '%s' on %s (watch dmesg)\n", ssid, ifname);
	close(fd);
	return 0;
}
