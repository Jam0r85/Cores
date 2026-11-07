#include "csensors.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

#define FOURCC(a, b, c, d) ((uint32_t)(a) << 24 | (uint32_t)(b) << 16 | (uint32_t)(c) << 8 | (uint32_t)(d))

typedef struct { char major, minor, build, reserved; uint16_t release; } smc_vers_t;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, mem; } smc_plimit_t;
typedef struct { uint32_t size, type; char attributes; } smc_info_t;
typedef struct {
    uint32_t key;
    smc_vers_t vers;
    smc_plimit_t plimit;
    smc_info_t info;
    char result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} smc_param_t;

enum { kSMCHandleYPCEvent = 2, kSMCReadBytes = 5, kSMCReadIndex = 8, kSMCReadKeyInfo = 9 };

static io_connect_t conn = 0;

static int smc_call(smc_param_t *in, smc_param_t *out) {
    size_t out_size = sizeof(smc_param_t);
    kern_return_t kr = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, in, sizeof(smc_param_t), out, &out_size);
    return (kr == KERN_SUCCESS && out->result == 0) ? 0 : -1;
}

static int read_info(uint32_t key, smc_key_t *out) {
    smc_param_t in = {0}, res = {0};
    in.key = key;
    in.data8 = kSMCReadKeyInfo;
    if (smc_call(&in, &res)) return -1;
    out->key = key;
    out->size = res.info.size;
    out->type = res.info.type;
    return 0;
}

int smc_open(void) {
    if (conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) {
        conn = 0;
        return -1;
    }
    return 0;
}

void smc_close(void) {
    if (conn) {
        IOServiceClose(conn);
        conn = 0;
    }
}

int smc_key_lookup(const char *name, smc_key_t *out) {
    if (!conn || strlen(name) != 4) return -1;
    return read_info(FOURCC(name[0], name[1], name[2], name[3]), out);
}

int smc_key_at_index(uint32_t index, smc_key_t *out) {
    if (!conn) return -1;
    smc_param_t in = {0}, res = {0};
    in.data8 = kSMCReadIndex;
    in.data32 = index;
    if (smc_call(&in, &res)) return -1;
    return read_info(res.key, out);
}

int smc_read_value(const smc_key_t *key, double *out) {
    if (!conn) return -1;
    smc_param_t in = {0}, res = {0};
    in.key = key->key;
    in.info.size = key->size;
    in.data8 = kSMCReadBytes;
    if (smc_call(&in, &res)) return -1;

    const uint8_t *b = res.bytes;
    switch (key->type) {
        case FOURCC('f', 'l', 't', ' '): { float f; memcpy(&f, b, sizeof f); *out = f; return 0; }
        case FOURCC('s', 'p', '7', '8'): *out = (int16_t)(b[0] << 8 | b[1]) / 256.0; return 0;
        case FOURCC('f', 'p', 'e', '2'): *out = (uint16_t)(b[0] << 8 | b[1]) / 4.0; return 0;
        case FOURCC('u', 'i', '8', ' '): *out = b[0]; return 0;
        case FOURCC('u', 'i', '1', '6'): *out = (uint16_t)(b[0] << 8 | b[1]); return 0;
        case FOURCC('u', 'i', '3', '2'): *out = (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3]; return 0;
        default: return -1;
    }
}

uint32_t smc_key_count(void) {
    smc_key_t key;
    double value;
    if (smc_key_lookup("#KEY", &key) || smc_read_value(&key, &value)) return 0;
    return (uint32_t)value;
}
