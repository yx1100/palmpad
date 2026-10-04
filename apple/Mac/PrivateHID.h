// Private macOS APIs used for gesture injection, resolved at runtime so a missing symbol degrades
// to a fallback instead of crashing. Formats verified per major macOS version (see PROTOCOL.md, M1).

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A CGEvent of `cgType` carrying an IOHIDEvent, the gesture format WindowServer reads on macOS 27.
/// `fields` maps IOHIDEvent field ids ((hidType << 16) | index) to numbers; floating-point numbers are
/// written as doubles, others as integers. `children` entries are {"type", "options", "fields"} dictionaries.
/// Returns NULL when HIDEvent or SLEventSetIOHIDEvent is unavailable.
CGEventRef _Nullable MTMCreateHIDEvent(uint32_t cgType, uint32_t hidType, uint32_t options,
                                       NSDictionary<NSNumber *, NSNumber *> *fields,
                                       NSArray<NSDictionary *> *_Nullable children) CF_RETURNS_RETAINED;

/// {"type", "options", "fields": {"id": value}, "children": [...], "text"} for the IOHIDEvent attached to `event`.
NSDictionary *_Nullable MTMDescribeHIDEvent(CGEventRef event);

/// Triggers a system feature through its symbolic hotkey (Mission Control = 32, Look Up = 70, ...).
/// Unbound hotkeys are bound to an unreachable key code first, as Mac Mouse Fix does.
BOOL MTMPostSymbolicHotKey(int hotkey);

/// Raw contact frames from the built-in trackpad via MultitouchSupport, for diagnostics and tip taps.
/// Each contact: @[identifier, state, normalizedX, normalizedY, size]; `width`/`height` are the sensor size in mm.
/// Returns a token for MTMStopMultitouch, or 0; the device runs while any handler is registered.
typedef void (^MTMContactHandler)(double timestamp, NSArray<NSArray<NSNumber *> *> *contacts);
int MTMStartMultitouch(MTMContactHandler handler, double *width, double *height);
void MTMStopMultitouch(int token);

NS_ASSUME_NONNULL_END
