#include "csensors.h"
#include <CoreFoundation/CoreFoundation.h>
#include <string.h>

// Private IOKit HID event-system API (stable for years, used by most stats apps).
typedef struct __HIDClient *HIDClientRef;
typedef struct __HIDService *HIDServiceRef;
typedef struct __HIDEvent *HIDEventRef;
extern HIDClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(HIDClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(HIDClientRef client);
extern CFTypeRef IOHIDServiceClientCopyProperty(HIDServiceRef service, CFStringRef key);
extern HIDEventRef IOHIDServiceClientCopyEvent(HIDServiceRef service, int64_t type, int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(HIDEventRef event, int32_t field);

#define kHIDEventTypeTemperature 15
#define kMaxServices 256

static HIDClientRef client = NULL;
static CFArrayRef services = NULL;
static int service_count = 0;
static char names[kMaxServices][64];

int hid_open(void) {
    if (client) return 0;
    client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return -1;

    int page = 0xff00, usage = 5; // Apple vendor page, temperature sensor
    CFNumberRef page_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usage_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *values[] = { page_num, usage_num };
    CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                               &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);
    CFRelease(match);
    CFRelease(page_num);
    CFRelease(usage_num);

    services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return -1;
    service_count = (int)CFArrayGetCount(services);
    if (service_count > kMaxServices) service_count = kMaxServices;

    for (int i = 0; i < service_count; i++) {
        HIDServiceRef svc = (HIDServiceRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef product = IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
        names[i][0] = 0;
        if (product) {
            if (CFGetTypeID(product) == CFStringGetTypeID())
                CFStringGetCString((CFStringRef)product, names[i], sizeof names[i], kCFStringEncodingUTF8);
            CFRelease(product);
        }
    }
    return 0;
}

int hid_service_count(void) { return service_count; }

const char *hid_service_name(int index) {
    return (index >= 0 && index < service_count) ? names[index] : "";
}

int hid_read_temperature(int index, double *out) {
    if (index < 0 || index >= service_count) return -1;
    HIDServiceRef svc = (HIDServiceRef)CFArrayGetValueAtIndex(services, index);
    HIDEventRef event = IOHIDServiceClientCopyEvent(svc, kHIDEventTypeTemperature, 0, 0);
    if (!event) return -1;
    *out = IOHIDEventGetFloatValue(event, kHIDEventTypeTemperature << 16);
    CFRelease(event);
    return 0;
}
