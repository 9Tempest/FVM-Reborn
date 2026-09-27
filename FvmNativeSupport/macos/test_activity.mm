// A separate real process observes Foundation's activity lifecycle around the
// public logger ABI. Interposition is local to this disposable test executable.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>

using Begin = id (*)(id, SEL, NSActivityOptions, NSString *);
using End = void (*)(id, SEL, id);
static Begin original_begin;
static End original_end;
static int begins = 0, ends = 0;
static NSActivityOptions observed_options = 0;
static __strong id observed_token = nil;

static id observe_begin(id self, SEL selector, NSActivityOptions options, NSString *reason) {
  id token = original_begin(self, selector, options, reason);
  if ([reason isEqualToString:@"FVM Reborn cooperative game hosting and networking"]) {
    ++begins;
    observed_options = options;
    observed_token = token;
  }
  return token;
}
static void observe_end(id self, SEL selector, id token) {
  if (token == observed_token) ++ends;
  original_end(self, selector, token);
}
static void check_shutdown() {
  bool valid = begins == 1 && ends == 1 && observed_token != nil &&
    observed_options == NSActivityUserInitiatedAllowingIdleSystemSleep &&
    !(observed_options & NSActivityIdleSystemSleepDisabled) &&
    !(observed_options & NSActivityIdleDisplaySleepDisabled);
  std::printf("activity_begin=%d activity_end=%d normal_idle_sleep_allowed=%s\n", begins, ends, valid ? "yes" : "no");
  std::fflush(stdout);
  if (!valid) _Exit(1);
}

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  @autoreleasepool {
    Class process_class = object_getClass([NSProcessInfo processInfo]);
    Method begin = class_getInstanceMethod(process_class, @selector(beginActivityWithOptions:reason:));
    Method end = class_getInstanceMethod(process_class, @selector(endActivity:));
    original_begin = reinterpret_cast<Begin>(method_setImplementation(begin, reinterpret_cast<IMP>(observe_begin)));
    original_end = reinterpret_cast<End>(method_setImplementation(end, reinterpret_cast<IMP>(observe_end)));
    // Registered before the dylib's local static, so the library destructor runs first.
    std::atexit(check_shutdown);
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { std::fprintf(stderr, "%s\n", dlerror()); return 3; }
    auto set_log = reinterpret_cast<double (*)(const char *)>(dlsym(library, "SetNativeLogFilePath"));
    if (!set_log || set_log(argv[2]) != 0 || set_log(argv[2]) != 0 || begins != 1) return 4;
    // Intentionally retain the handle until exit: this is the actual game's lifecycle.
  }
  return 0;
}
