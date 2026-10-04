#import "PrivateHID.h"

#import <dlfcn.h>
#import <mach/mach_time.h>

// IOKit's private Objective-C overlay for IOHIDEventRef. Declared as a protocol so nothing links
// against the class symbol; the class itself comes from NSClassFromString.
@protocol MTMHIDEvent <NSObject>
- (instancetype)initWithType:(uint32_t)type timestamp:(uint64_t)timestamp senderID:(uint64_t)senderID;
- (uint32_t)type;
- (uint32_t)options;
- (void)setOptions:(uint32_t)options;
- (NSArray *)children;
- (void)setIntegerValue:(NSInteger)value forField:(uint32_t)field;
- (void)setDoubleValue:(double)value forField:(uint32_t)field;
- (NSInteger)integerValueForField:(uint32_t)field;
- (double)doubleValueForField:(uint32_t)field;
- (void)appendEvent:(id)event;
@end

typedef void (*SetHIDEventFn)(CGEventRef, CFTypeRef);
typedef CFTypeRef (*CopyHIDEventFn)(CGEventRef);

static void *skyLight(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
    });
    return handle;
}

static Class hidEventClass(void) {
    Class c = NSClassFromString(@"HIDEvent");
    return [c instancesRespondToSelector:@selector(setDoubleValue:forField:)] ? c : Nil;
}

static id<MTMHIDEvent> buildHID(Class cls, uint32_t type, uint32_t options, NSDictionary<NSNumber *, NSNumber *> *fields) {
    id<MTMHIDEvent> e = [(id<MTMHIDEvent>)[cls alloc] initWithType:type timestamp:mach_absolute_time() senderID:0];
    [e setOptions:options];
    [fields enumerateKeysAndObjectsUsingBlock:^(NSNumber *field, NSNumber *value, BOOL *stop) {
        const char *t = value.objCType;
        if (strcmp(t, @encode(double)) == 0 || strcmp(t, @encode(float)) == 0) {
            [e setDoubleValue:value.doubleValue forField:field.unsignedIntValue];
        } else {
            [e setIntegerValue:value.integerValue forField:field.unsignedIntValue];
        }
    }];
    return e;
}

CGEventRef MTMCreateHIDEvent(uint32_t cgType, uint32_t hidType, uint32_t options,
                             NSDictionary<NSNumber *, NSNumber *> *fields, NSArray<NSDictionary *> *children) {
    static SetHIDEventFn setHID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *sl = skyLight();
        if (sl) setHID = (SetHIDEventFn)dlsym(sl, "SLEventSetIOHIDEvent");
    });
    Class cls = hidEventClass();
    if (!setHID || !cls) return NULL;

    id<MTMHIDEvent> e = buildHID(cls, hidType, options, fields);
    for (NSDictionary *c in children ?: @[]) {
        [e appendEvent:buildHID(cls, [c[@"type"] unsignedIntValue], [c[@"options"] unsignedIntValue], c[@"fields"] ?: @{})];
    }
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return NULL;
    CGEventSetType(event, (CGEventType)cgType);
    setHID(event, (__bridge CFTypeRef)e);
    return event;
}

static NSDictionary *describe(id<MTMHIDEvent> e) {
    uint32_t type = [e type];
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    for (uint32_t i = 0; i < 48; i++) {
        uint32_t f = (type << 16) | i;
        double d = [e doubleValueForField:f];
        NSInteger n = [e integerValueForField:f];
        NSString *key = [NSString stringWithFormat:@"%u", f];   // string keys keep the result JSON-serializable
        if (d != 0 && d != (double)n) fields[key] = @(d);
        else if (n != 0) fields[key] = @(n);
    }
    NSMutableArray *children = [NSMutableArray array];
    for (id c in [e children] ?: @[]) [children addObject:describe(c)];
    return @{@"type": @(type), @"options": @([e options]), @"fields": fields, @"children": children,
             @"text": [e description] ?: @""};
}

NSDictionary *MTMDescribeHIDEvent(CGEventRef event) {
    static CopyHIDEventFn copyHID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        copyHID = (CopyHIDEventFn)dlsym(RTLD_DEFAULT, "CGEventCopyIOHIDEvent");
        if (!copyHID && skyLight()) copyHID = (CopyHIDEventFn)dlsym(skyLight(), "SLEventCopyIOHIDEvent");
    });
    if (!copyHID || !hidEventClass()) return nil;
    CFTypeRef ref = copyHID(event);
    if (!ref) return nil;
    id e = CFBridgingRelease(ref);
    return [e respondsToSelector:@selector(doubleValueForField:)] ? describe(e) : nil;
}

// MARK: - Symbolic hotkeys

typedef CGError (*GetSHKFn)(int, unichar *, unichar *, uint32_t *);
typedef CGError (*SetSHKFn)(int, unichar, CGKeyCode, uint32_t);
typedef bool (*IsSHKEnabledFn)(int);
typedef CGError (*SetSHKEnabledFn)(int, bool);

BOOL MTMPostSymbolicHotKey(int hotkey) {
    static GetSHKFn get;
    static SetSHKFn set;
    static IsSHKEnabledFn isEnabled;
    static SetSHKEnabledFn setEnabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *sl = skyLight();
        if (!sl) return;
        get = (GetSHKFn)dlsym(sl, "CGSGetSymbolicHotKeyValue");
        set = (SetSHKFn)dlsym(sl, "CGSSetSymbolicHotKeyValue");
        isEnabled = (IsSHKEnabledFn)dlsym(sl, "CGSIsSymbolicHotKeyEnabled");
        setEnabled = (SetSHKEnabledFn)dlsym(sl, "CGSSetSymbolicHotKeyEnabled");
    });
    if (!get || !set || !isEnabled || !setEnabled) return NO;

    unichar keyEquivalent = 0xFFFF, keyCode = 0xFFFF;
    uint32_t mods = 0;
    get(hotkey, &keyEquivalent, &keyCode, &mods);
    // ponytail: trusts the stored key code for letter shortcuts (e.g. ⌃⌘D); layouts that move
    // that letter to another key would need a UCKeyTranslate search like Mac Mouse Fix does.
    if (!isEnabled(hotkey) || keyCode == 0xFFFF) {
        keyCode = (CGKeyCode)(hotkey + 400);                    // no real keyboard produces this code
        mods = kCGEventFlagMaskNumericPad | kCGEventFlagMaskSecondaryFn;
        setEnabled(hotkey, true);
        set(hotkey, 0xFFFF, keyCode, mods);
    }
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, keyCode, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, keyCode, false);
    CGEventSetFlags(down, (CGEventFlags)mods);
    CGEventSetFlags(up, (CGEventFlags)mods);
    CGEventPost(kCGSessionEventTap, down);
    CGEventPost(kCGSessionEventTap, up);
    CFRelease(down);
    CFRelease(up);
    return YES;
}

// MARK: - MultitouchSupport

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;
typedef struct {
    int frame;
    double timestamp;
    int identifier, state, fingerID, handID;
    MTVector normalized;
    float total, pressure, angle, majorAxis, minorAxis;
    MTVector absolute;
    int field14, field15;
    float density;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, MTTouch *, int, double, int);

static MTDeviceRef mtDevice;   // all state below is guarded by @synchronized (handlers())
static int lastToken;
static void (*mtStop)(MTDeviceRef);
static void (*mtUnregister)(MTDeviceRef, MTContactCallback);

static NSMutableDictionary<NSNumber *, MTMContactHandler> *handlers(void) {
    static NSMutableDictionary *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

static int onContacts(MTDeviceRef device, MTTouch *touches, int count, double timestamp, int frame) {
    NSArray<MTMContactHandler> *hs;
    @synchronized (handlers()) { hs = handlers().allValues; }
    NSMutableArray *contacts = [NSMutableArray arrayWithCapacity:count];
    for (int i = 0; i < count; i++) {
        MTTouch t = touches[i];
        [contacts addObject:@[@(t.identifier), @(t.state), @(t.normalized.pos.x), @(t.normalized.pos.y), @(t.total)]];
    }
    for (MTMContactHandler h in hs) h(timestamp, contacts);
    return 0;
}

int MTMStartMultitouch(MTMContactHandler handler, double *width, double *height) {
    void *mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    if (!mt) return 0;
    MTDeviceRef (*create)(void) = dlsym(mt, "MTDeviceCreateDefault");
    void (*reg)(MTDeviceRef, MTContactCallback) = dlsym(mt, "MTRegisterContactFrameCallback");
    void (*start)(MTDeviceRef, int) = dlsym(mt, "MTDeviceStart");
    int (*dims)(MTDeviceRef, int *, int *) = dlsym(mt, "MTDeviceGetSensorSurfaceDimensions");
    @synchronized (handlers()) {
        mtStop = dlsym(mt, "MTDeviceStop");
        mtUnregister = dlsym(mt, "MTUnregisterContactFrameCallback");
        if (!create || !reg || !start || !mtStop) return 0;
        if (!mtDevice) {
            mtDevice = create();
            if (!mtDevice) return 0;
            reg(mtDevice, onContacts);
            start(mtDevice, 0);
        }
        int w = 0, h = 0;
        if (dims) dims(mtDevice, &w, &h);
        *width = w / 100.0;
        *height = h / 100.0;
        handlers()[@(++lastToken)] = [handler copy];
        return lastToken;
    }
}

void MTMStopMultitouch(int token) {
    @synchronized (handlers()) {
        [handlers() removeObjectForKey:@(token)];
        if (handlers().count || !mtDevice) return;
        if (mtUnregister) mtUnregister(mtDevice, onContacts);
        mtStop(mtDevice);
        mtDevice = NULL;
    }
}
