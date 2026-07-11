// Temperature sensors, two sources:
//  1. Private IOHIDEventSystemClient interface (AppleVendor usage page) —
//     covers CPU die temps on Apple Silicon ("PMU tdie*", "pACC/eACC MTR").
//  2. AppleSMC key enumeration — GPU die temps ("Tg*" keys on Apple Silicon)
//     aren't exposed via HID on all chips. Keys are discovered once and
//     cached, then re-read on every sample.
// Same approach as Stats / asitop / smctemp. Not App Store safe.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <string.h>
#include "SensorReader.h"

// MARK: - HID sensors

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timeout);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kHIDPage_AppleVendor 0xff00
#define kHIDUsage_AppleVendor_TemperatureSensor 5
#define kIOHIDEventTypeTemperature 15
#define kIOHIDEventFieldTemperatureLevel (kIOHIDEventTypeTemperature << 16)

static Boolean contains(CFStringRef haystack, const char *needle) {
    CFStringRef n = CFStringCreateWithCString(NULL, needle, kCFStringEncodingUTF8);
    Boolean found = CFStringFind(haystack, n, kCFCompareCaseInsensitive).location != kCFNotFound;
    CFRelease(n);
    return found;
}

static void hid_read_temps(double *cpu, double *gpu) {
    *cpu = -1;
    *gpu = -1;

    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return;

    int page = kHIDPage_AppleVendor;
    int usage = kHIDUsage_AppleVendor_TemperatureSensor;
    CFNumberRef pageNum = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef usageNum = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[2] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[2] = { pageNum, usageNum };
    CFDictionaryRef matching = CFDictionaryCreate(NULL, keys, vals, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, matching);

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (services) {
        double cpuMax = -1, gpuMax = -1, socMax = -1;
        for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
            IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
            CFTypeRef nameRef = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
            if (!nameRef || CFGetTypeID(nameRef) != CFStringGetTypeID()) {
                if (nameRef) CFRelease(nameRef);
                continue;
            }
            CFStringRef name = (CFStringRef)nameRef;

            IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
            if (event) {
                double temp = IOHIDEventGetFloatValue(event, kIOHIDEventFieldTemperatureLevel);
                if (temp > 0 && temp < 130) {
                    if (contains(name, "GPU")) {
                        if (temp > gpuMax) gpuMax = temp;
                    } else if (contains(name, "pACC") || contains(name, "eACC") ||
                               contains(name, "tdie") || contains(name, "CPU")) {
                        if (temp > cpuMax) cpuMax = temp;
                    } else if (contains(name, "SOC")) {
                        if (temp > socMax) socMax = temp;
                    }
                }
                CFRelease(event);
            }
            CFRelease(name);
        }
        CFRelease(services);
        *cpu = cpuMax > 0 ? cpuMax : socMax;
        *gpu = gpuMax;
    }

    CFRelease(matching);
    CFRelease(pageNum);
    CFRelease(usageNum);
    CFRelease(client);
}

// MARK: - SMC

typedef struct {
    char major, minor, build, reserved[1];
    UInt16 release;
} SMCKeyData_vers_t;

typedef struct {
    UInt16 version, length;
    UInt32 cpuPLimit, gpuPLimit, memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    UInt32 dataSize;
    UInt32 dataType;
    char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
    UInt32 key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result, status, data8;
    UInt32 data32;
    unsigned char bytes[32];
} SMCKeyData_t;

#define kSMCHandleYPCEvent 2
#define kSMCReadKey 5
#define kSMCGetKeyFromIndex 8
#define kSMCGetKeyInfo 9

#define kTypeFlt 0x666c7420 // 'flt '
#define kTypeSp78 0x73703738 // 'sp78'

static io_connect_t smc_connection(void) {
    static io_connect_t conn = 0;
    static Boolean tried = false;
    if (tried) return conn;
    tried = true;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    if (IOServiceOpen(service, mach_task_self(), 0, &conn) != KERN_SUCCESS) conn = 0;
    IOObjectRelease(service);
    return conn;
}

static Boolean smc_call(SMCKeyData_t *in, SMCKeyData_t *out) {
    io_connect_t conn = smc_connection();
    if (!conn) return false;
    size_t outSize = sizeof(*out);
    return IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, in, sizeof(*in), out, &outSize) == KERN_SUCCESS
        && out->result == 0;
}

// Returns °C, or -1 if the key is missing/unreadable.
static double smc_read_temp(UInt32 key) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key;
    in.data8 = kSMCGetKeyInfo;
    if (!smc_call(&in, &out)) return -1;

    UInt32 dataType = out.keyInfo.dataType;
    UInt32 dataSize = out.keyInfo.dataSize;
    in.keyInfo.dataSize = dataSize;
    in.data8 = kSMCReadKey;
    if (!smc_call(&in, &out)) return -1;

    if (dataType == kTypeFlt && dataSize == 4) {
        float value;
        memcpy(&value, out.bytes, 4);
        return value;
    }
    if (dataType == kTypeSp78 && dataSize == 2) {
        return (double)((SInt16)((out.bytes[0] << 8) | out.bytes[1])) / 256.0;
    }
    return -1;
}

// Discovered temperature keys, cached after the first enumeration.
#define kMaxKeys 128
static UInt32 gCPUKeys[kMaxKeys], gGPUKeys[kMaxKeys];
static int gCPUKeyCount = 0, gGPUKeyCount = 0;
static Boolean gEnumerated = false;

// Classify a 4CC temperature key. Apple Silicon uses 'flt ' keys: Tp*/Te*
// (P-/E-core die), Tf* (die on some M3 variants), Tg* (GPU die). Intel uses
// 'sp78' keys: TC0P etc. (CPU proximity/die), TG0P (GPU).
static void classify_key(UInt32 key) {
    char c1 = (key >> 16) & 0xff;
    double value = -1;
    if (c1 == 'g' || c1 == 'G') {
        value = smc_read_temp(key);
        if (value > 10 && value < 130 && gGPUKeyCount < kMaxKeys) gGPUKeys[gGPUKeyCount++] = key;
    } else if (c1 == 'p' || c1 == 'e' || c1 == 'f' || c1 == 'C') {
        value = smc_read_temp(key);
        if (value > 10 && value < 130 && gCPUKeyCount < kMaxKeys) gCPUKeys[gCPUKeyCount++] = key;
    }
}

static void smc_enumerate_keys(void) {
    gEnumerated = true;

    SMCKeyData_t in = {0}, out = {0};
    in.key = ('#' << 24) | ('K' << 16) | ('E' << 8) | 'Y';
    in.data8 = kSMCGetKeyInfo;
    if (!smc_call(&in, &out)) return;
    in.keyInfo.dataSize = out.keyInfo.dataSize;
    in.data8 = kSMCReadKey;
    if (!smc_call(&in, &out)) return;
    UInt32 total = ((UInt32)out.bytes[0] << 24) | ((UInt32)out.bytes[1] << 16)
                 | ((UInt32)out.bytes[2] << 8) | (UInt32)out.bytes[3];

    for (UInt32 i = 0; i < total; i++) {
        SMCKeyData_t idxIn = {0}, idxOut = {0};
        idxIn.data8 = kSMCGetKeyFromIndex;
        idxIn.data32 = i;
        if (!smc_call(&idxIn, &idxOut)) continue;
        if (((idxOut.key >> 24) & 0xff) == 'T') classify_key(idxOut.key);
    }
}

static double smc_max_temp(const UInt32 *keys, int count) {
    double best = -1;
    for (int i = 0; i < count; i++) {
        double t = smc_read_temp(keys[i]);
        if (t > 10 && t < 130 && t > best) best = t;
    }
    return best;
}

// MARK: - Public entry point

MGTemps mg_read_temps(void) {
    MGTemps out;
    hid_read_temps(&out.cpu, &out.gpu);
    if (out.cpu < 0 || out.gpu < 0) {
        if (!gEnumerated) smc_enumerate_keys();
        if (out.cpu < 0) out.cpu = smc_max_temp(gCPUKeys, gCPUKeyCount);
        if (out.gpu < 0) out.gpu = smc_max_temp(gGPUKeys, gGPUKeyCount);
    }
    return out;
}
